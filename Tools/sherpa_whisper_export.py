#!/usr/bin/env python3
"""Export a Hugging Face Whisper checkpoint into the ONNX layout the sherpa-onnx runtime reads.

sherpa-onnx is not a generic Whisper runner. Its `InitEncoder` reads a fixed set of metadata keys
and expects the encoder to *return the cross-attention K/V of every decoder layer*; its
`ForwardDecoder` feeds the decoder six tensors in a fixed order — tokens, the self-attention K/V
cache, the cross-attention K/V and the position the window starts at — and reads three back (logits
plus the updated self cache). That is the layout of sherpa-onnx's own
`scripts/whisper/export-onnx.py`, and the only one the runtime can load.

An optimum export has a different layout (encoder -> last_hidden_state, decoder -> input_ids +
encoder_hidden_states + past_key_values), so such a model can never load: the runtime reads two
encoder outputs and passes six positional decoder inputs, and the session dies at the first
recogniser build — on the phone that took the whole app down with it.

The math here is the upstream script's, written against the Hugging Face modules so the fine-tuned
weights are used exactly as trained, with no state-dict renaming in between. `self_check()` runs the
wrappers against the checkpoint's own forward pass before anything is written, so a wrong layout or
a wrong cache update fails the build instead of the phone.
"""

import argparse
import os
import sys
import time

import torch
import torch.nn.functional as F
from torch import Tensor, nn
from transformers import WhisperForConditionalGeneration


def log(msg):
    print(f"[whisper-export] {msg}", flush=True)


class EncoderCrossKV(nn.Module):
    """The encoder as sherpa-onnx wants it: audio in, cross-attention K/V of every decoder layer out.

    The encoder itself is the checkpoint's own, called unchanged; only the tail differs — instead of
    handing the decoder hidden states and letting it project them, the projections are done here,
    once, and the results are what the runtime caches and feeds back on every decode step.
    """

    def __init__(self, model):
        super().__init__()
        self.encoder = model.model.encoder
        self.cross = nn.ModuleList([layer.encoder_attn for layer in model.model.decoder.layers])

    def forward(self, mel: Tensor):
        hidden = self.encoder(mel).last_hidden_state  # [n_audio, T', n_state]
        keys = [attn.k_proj(hidden) for attn in self.cross]
        values = [attn.v_proj(hidden) for attn in self.cross]
        return torch.stack(keys), torch.stack(values)


class DecoderWithTensorCache(nn.Module):
    """The decoder in the shape the runtime drives it, with the self-attention cache passed in and out.

    One window of tokens at a time, starting at `offset`: the prompt goes in as one window at offset
    0, single tokens follow. The cache holds the self-attention K/V of every layer; the new window's
    K/V is written at `offset` (in place, like the upstream script) and the attention sees the whole
    prefix. Cross-attention always runs over the encoder's cached K/V.
    """

    def __init__(self, model):
        super().__init__()
        self.decoder = model.model.decoder
        self.n_head = model.config.decoder_attention_heads
        self.n_state = model.config.d_model

    def _heads(self, x: Tensor) -> Tensor:
        """[n_audio, T, n_state] -> [n_audio, n_head, T, head_dim]."""
        n_audio, n_ctx, _ = x.shape
        return x.view(n_audio, n_ctx, self.n_head, self.n_state // self.n_head).permute(0, 2, 1, 3)

    def _merge(self, x: Tensor) -> Tensor:
        """[n_audio, n_head, T, head_dim] -> [n_audio, T, n_state]."""
        n_audio, _, n_ctx, _ = x.shape
        return x.permute(0, 2, 1, 3).reshape(n_audio, n_ctx, self.n_state)

    def _attend(self, q: Tensor, k: Tensor, v: Tensor, blocked) -> Tensor:
        # Whisper scales query and key each by head_dim ** -0.25, which multiplies out to the usual
        # 1/sqrt(head_dim): the same numbers the checkpoint's own attention produces.
        scale = (self.n_state // self.n_head) ** -0.25
        qk = torch.matmul(self._heads(q) * scale, (self._heads(k) * scale).transpose(-1, -2))
        if blocked is not None:
            # Named check instead of a cryptic broadcast error: the mask has to describe exactly the
            # scores it is masking.
            if tuple(blocked.shape[-2:]) != tuple(qk.shape[-2:]):
                raise SystemExit(f"[whisper-export] the attention mask {tuple(blocked.shape)} does "
                                 f"not fit the scores {tuple(qk.shape)}")
            qk = qk.masked_fill(blocked, float("-inf"))
        weights = F.softmax(qk.float(), dim=-1).to(q.dtype)
        return self._merge(torch.matmul(weights, self._heads(v)))

    def forward(self, tokens: Tensor, self_k: Tensor, self_v: Tensor,
                cross_k: Tensor, cross_v: Tensor, offset: Tensor):
        start = offset.reshape(-1)[0]
        n_tokens = tokens.shape[1]
        window = start + n_tokens

        x = self.decoder.embed_tokens(tokens) + self.decoder.embed_positions.weight[start:window]

        # A key may be attended to when it is not in front of the query asking. Building the mask
        # from `offset` keeps this right both for a multi-token window at the start and for the
        # single tokens that follow it. The two leading axes are 1 so it lines up with the attention
        # scores, which are [n_audio, n_head, n_tokens, window].
        keys = torch.arange(0, window, device=x.device)
        queries = torch.arange(0, n_tokens, device=x.device) + start
        blocked = (keys.unsqueeze(0) > queries.unsqueeze(1)).unsqueeze(0).unsqueeze(0)

        for i, layer in enumerate(self.decoder.layers):
            attn = layer.self_attn
            normed = layer.self_attn_layer_norm(x)
            self_k[i][:, start:window, :] = attn.k_proj(normed)
            self_v[i][:, start:window, :] = attn.v_proj(normed)
            x = x + attn.out_proj(self._attend(attn.q_proj(normed),
                                               self_k[i][:, :window, :],
                                               self_v[i][:, :window, :],
                                               blocked))

            cross = layer.encoder_attn
            normed = layer.encoder_attn_layer_norm(x)
            x = x + cross.out_proj(self._attend(cross.q_proj(normed), cross_k[i], cross_v[i], None))

            x = x + layer.fc2(F.gelu(layer.fc1(layer.final_layer_norm(x))))

        x = self.decoder.layer_norm(x)
        logits = torch.matmul(self.decoder.embed_tokens.weight.to(x.dtype),
                              x.permute(0, 2, 1)).permute(0, 2, 1).float()
        return logits, self_k, self_v


def empty_caches(model, n_audio):
    shape = (model.config.decoder_layers, n_audio,
             model.config.max_target_positions, model.config.d_model)
    return torch.zeros(shape), torch.zeros(shape)


def self_check(model, encoder, decoder, mel, prompt):
    """Prove the wrappers give the checkpoint's own answers before any file is written.

    Two runs: the prompt as one window (offset 0), then the same prompt token by token through the
    cache. Both must match the checkpoint's forward pass — the first catches a wrong cross-attention
    projection, the second a wrong cache update or mask.
    """
    with torch.no_grad():
        reference = model(input_features=mel, decoder_input_ids=prompt).logits

        cross_k, cross_v = encoder(mel)
        self_k, self_v = empty_caches(model, mel.shape[0])
        whole, _, _ = decoder(prompt, self_k, self_v, cross_k, cross_v,
                              torch.zeros(1, dtype=torch.int64))
        diff_window = (whole - reference).abs().max().item()

        self_k, self_v = empty_caches(model, mel.shape[0])
        step = None
        for i in range(prompt.shape[1]):
            step, self_k, self_v = decoder(prompt[:, i:i + 1], self_k, self_v, cross_k, cross_v,
                                           torch.tensor([i], dtype=torch.int64))
        diff_cached = (step - reference[:, -1:, :]).abs().max().item()

    log(f"self-check: one window {diff_window:.2e}, token by token {diff_cached:.2e} "
        f"(max |logit difference| against the checkpoint)")
    if diff_window > 0.05 or diff_cached > 0.05:
        raise SystemExit("[whisper-export] the wrappers do not match the checkpoint - refusing to "
                         "write a model that would transcribe nonsense")
    return cross_k, cross_v


def export(model_dir, out_dir):
    from transformers import WhisperTokenizer

    os.makedirs(out_dir, exist_ok=True)
    log(f"loading the checkpoint from {model_dir}")
    model = WhisperForConditionalGeneration.from_pretrained(model_dir).eval()
    tokenizer = WhisperTokenizer.from_pretrained(model_dir)
    config = model.config
    log(f"n_mels={config.num_mel_bins} n_audio_layer={config.encoder_layers} "
        f"n_text_layer={config.decoder_layers} n_vocab={config.vocab_size}")

    def token_id(token):
        """Special-token ids by name. The tokenizer's convenience attributes differ between
        transformers versions (`.sot` does not exist on 4.46); the vocabulary never does."""
        value = tokenizer.convert_tokens_to_ids(token)
        if value is None or value == tokenizer.unk_token_id:
            raise SystemExit(f"[whisper-export] {token} is not in this tokenizer")
        return value

    encoder = EncoderCrossKV(model).eval()
    decoder = DecoderWithTensorCache(model).eval()

    # A full 30 s window of silence drives the shapes; the dynamic axes let the runtime send anything.
    mel = torch.zeros(1, config.num_mel_bins, 30 * 100)
    prompt = torch.tensor([[token_id("<|startoftranscript|>"), token_id("<|he|>"),
                            token_id("<|transcribe|>"), token_id("<|notimestamps|>")]],
                          dtype=torch.int64)
    cross_k, cross_v = self_check(model, encoder, decoder, mel, prompt)
    log(f"cross K/V shape: {tuple(cross_k.shape)}")

    encoder_path = os.path.join(out_dir, "encoder_model.onnx")
    log("exporting the encoder")
    t0 = time.time()
    with torch.no_grad():
        torch.onnx.export(
            encoder, mel, encoder_path, opset_version=17,
            input_names=["mel"],
            output_names=["n_layer_cross_k", "n_layer_cross_v"],
            dynamic_axes={"mel": {0: "n_audio", 2: "T"},
                          "n_layer_cross_k": {1: "n_audio", 2: "T"},
                          "n_layer_cross_v": {1: "n_audio", 2: "T"}})
    log(f"encoder exported in {time.time() - t0:.0f}s "
        f"({os.path.getsize(encoder_path) / 1e6:.1f} MB)")

    self_k, self_v = empty_caches(model, mel.shape[0])
    decoder_path = os.path.join(out_dir, "decoder_model.onnx")
    log("exporting the decoder")
    t0 = time.time()
    with torch.no_grad():
        torch.onnx.export(
            decoder, (prompt, self_k, self_v, cross_k, cross_v, torch.zeros(1, dtype=torch.int64)),
            decoder_path, opset_version=17,
            input_names=["tokens", "in_n_layer_self_k_cache", "in_n_layer_self_v_cache",
                         "n_layer_cross_k", "n_layer_cross_v", "offset"],
            output_names=["logits", "out_n_layer_self_k_cache", "out_n_layer_self_v_cache"],
            dynamic_axes={"tokens": {0: "n_audio", 1: "n_tokens"},
                          "in_n_layer_self_k_cache": {1: "n_audio"},
                          "in_n_layer_self_v_cache": {1: "n_audio"},
                          "n_layer_cross_k": {1: "n_audio", 2: "T"},
                          "n_layer_cross_v": {1: "n_audio", 2: "T"}})
    log(f"decoder exported in {time.time() - t0:.0f}s "
        f"({os.path.getsize(decoder_path) / 1e6:.1f} MB)")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", required=True, help="the Hugging Face checkpoint directory")
    parser.add_argument("--out", required=True, help="where encoder_model.onnx/decoder_model.onnx go")
    args = parser.parse_args()
    torch.set_num_threads(1)
    export(args.model_dir, args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
