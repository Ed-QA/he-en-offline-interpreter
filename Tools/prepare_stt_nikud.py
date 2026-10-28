"""Prepare the Hebrew ASR model that puts nikud in the text straight from the voice.

Model: MayBog/whisper-hebrew-nikud-v1 ("Nikudon") - Whisper large-v3-turbo fine-tuned by
ivrit-ai so that the recogniser itself emits pointed Hebrew. There is no post-hoc diacritizer in
this app any more: the points come from the acoustic model, in the same pass as the words.

The runtime is sherpa-onnx (already linked in the app), so the PyTorch checkpoint is converted to
sherpa-onnx's Whisper ONNX layout and quantized to int8:

    Model/WhisperNikud/encoder_model.onnx   int8
    Model/WhisperNikud/decoder_model.onnx   int8
    Model/WhisperNikud/tokens.txt
    Model/WhisperNikud/model_info.json

Output folder: ./Model/WhisperNikud
"""

import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request

MODEL = "MayBog/whisper-hebrew-nikud-v1"
OUT = "Model/WhisperNikud"
RAW = "whisper_nikud_raw"
CONVERTER = "https://raw.githubusercontent.com/openai/whisper/main/whisper/assets/multilingual.tiktoken"

WANTED = ["encoder_model.onnx", "decoder_model.onnx", "tokens.txt"]

# Every Hebrew recogniser on Hugging Face that emits nikud itself, best fit first. The first one
# that downloads wins; a gated entry is skipped unless HF_TOKEN is present, so a rejection of the
# top choice is not a dead end. Ratings: fit for this app (general Hebrew, speed, footprint).
CANDIDATES = [
    {
        "repo": "MayBog/whisper-hebrew-nikud-v1",
        "gated": True,
        "fit": 10,
        "why": "whisper-large-v3-turbo, built for general Hebrew with nikud - best quality fit, "
               "needs the model terms accepted and HF_TOKEN",
    },
    {
        "repo": "cantillation/Teamim-IvritAI-large-v3-turbo-new_WeightDecay-0.005_"
                "Augmented_WithSRT_date-23-04-2025",
        "gated": False,
        "fit": 8,
        "why": "same base as the top choice (ivrit-ai/whisper-large-v3-turbo), he-cantillation, "
               "turbo speed, ungated - pointed output without any token",
    },
    {
        "repo": "cantillation/Teamim-large-v3-turbo_WeightDecay-0.005_Augmented_date-07-05-2025",
        "gated": False,
        "fit": 7,
        "why": "openai/whisper-large-v3-turbo base, he-cantillation, turbo speed, ungated",
    },
    {
        "repo": "cantillation/whisper-medium-he-teamim-silsuless-ori-TrainAndVal-Nikud",
        "gated": False,
        "fit": 6,
        "why": "whisper-medium, nikud in its own name, ungated - slower than turbo, smaller RAM",
    },
    {
        "repo": "cantillation/whisper-small-he-teamim5",
        "gated": False,
        "fit": 4,
        "why": "whisper-small, ungated - smallest footprint that still points (approx 231 MB int8)",
    },
    {
        "repo": "cantillation/Teamim-tiny_Random-True_DropOut-0.1_WeightDecay-1e-06_"
                "Augmented_date-27-06-2024_09-48-25",
        "gated": False,
        "fit": 2,
        "why": "whisper-tiny, ungated - last resort, approx 36 MB int8, accuracy is poor",
    },
]

CHOSEN = None


def log(msg):
    try:
        print(f"[prepare_stt_nikud] {msg}", flush=True)
    except UnicodeEncodeError:  # Windows consoles default to cp1252
        print(f"[prepare_stt_nikud] {str(msg).encode('ascii', 'replace').decode()}", flush=True)


def download():
    """Fetch the checkpoint, tokenizer and configs into RAW.

    The checkpoint is **gated** (`MayBog/whisper-hebrew-nikud-v1`, `gated: manual`): Hugging Face
    answers 401 until a token whose owner has accepted the model's terms is presented. The token is
    read from HF_TOKEN / HUGGING_FACE_HUB_TOKEN and is never written to disk. Downloads go through
    huggingface_hub so shards, LFS and retries are its problem, not ours.
    """
    from huggingface_hub import snapshot_download

    os.makedirs(RAW, exist_ok=True)
    token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGING_FACE_HUB_TOKEN")
    if token:
        log("using HF_TOKEN from the environment")
    else:
        log("no HF_TOKEN: the gated checkpoint is skipped, ungated checkpoints are used")
        print("::warning::HF_TOKEN is not set, so the gated MayBog/whisper-hebrew-nikud-v1 "
              "checkpoint cannot be used. This build falls back to the ungated cantillation "
              "checkpoints listed in CANDIDATES (Tools/prepare_stt_nikud.py).", flush=True)

    global CHOSEN
    for rank, cand in enumerate(CANDIDATES, start=1):
        repo = cand["repo"]
        if cand.get("gated") and not token:
            log(f"[{rank}/{len(CANDIDATES)}] {repo} - skipped (gated, no HF_TOKEN)")
            continue
        log(f"[{rank}/{len(CANDIDATES)}] {repo} - fit {cand['fit']}/10 - {cand['why']}")
        try:
            snapshot_download(repo_id=repo, local_dir=RAW, token=token,
                              allow_patterns=["*.json", "*.txt", "model.safetensors"])
        except Exception as exc:
            log(f"    rejected: {type(exc).__name__}: {str(exc)[:180]}")
            shutil.rmtree(RAW, ignore_errors=True)
            continue
        weights = os.path.join(RAW, "model.safetensors")
        if not os.path.exists(weights):
            log("    rejected: no model.safetensors in that repository")
            shutil.rmtree(RAW, ignore_errors=True)
            continue
        CHOSEN = repo
        log(f"    USING {repo}: {os.path.getsize(weights) / 1e6:.1f} MB fp32 checkpoint")
        return
    raise SystemExit("[prepare_stt_nikud] every candidate checkpoint was rejected")


def convert():
    """The checkpoint -> the ONNX layout the sherpa-onnx runtime reads, plus tokens.txt.

    The export itself is Tools/sherpa_whisper_export.py. It has to be that layout: the runtime reads
    the cross-attention K/V of every decoder layer out of the encoder and drives the decoder with six
    positional tensors, while an optimum export (encoder -> last_hidden_state, decoder -> input_ids +
    encoder_hidden_states + past_key_values) has neither, which is why the app died the moment it
    built the recogniser. tokens.txt is written from Whisper's own multilingual tiktoken vocabulary:
    lines of `<token> <id>`, the exact file and format the runtime expects beside the two ONNX files.
    """
    os.makedirs(OUT, exist_ok=True)
    if os.path.exists(os.path.join(OUT, "encoder_model.onnx")) and \
       os.path.exists(os.path.join(OUT, "decoder_model.onnx")):
        log("ONNX models already exported")
    else:
        exporter = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "sherpa_whisper_export.py")
        cmd = [sys.executable, exporter, "--model-dir", RAW, "--out", OUT]
        log("running: " + " ".join(cmd))
        subprocess.run(cmd, check=True)

    tokens_path = os.path.join(OUT, "tokens.txt")
    if not os.path.exists(tokens_path) or os.path.getsize(tokens_path) == 0:
        tiktoken_path = os.path.join(RAW, "multilingual.tiktoken")
        if not os.path.exists(tiktoken_path):
            log("fetching whisper multilingual.tiktoken")
            urllib.request.urlretrieve(CONVERTER, tiktoken_path)
        with open(tiktoken_path, "r", encoding="utf-8") as fh:
            lines = [line for line in fh.read().splitlines() if line.strip()]
        with open(tokens_path, "w", encoding="utf-8") as fh:
            for line in lines:
                fh.write(line.strip() + "\n")
        log(f"tokens.txt: {len(lines)} tokens")

    for name in WANTED:
        path = os.path.join(OUT, name)
        if not os.path.exists(path):
            raise SystemExit(f"converter did not produce {path}")


def quantize():
    """int8 for the phone: 3.1 GB fp32 is not something to carry in an app bundle."""
    from onnxruntime.quantization import quantize_dynamic, QuantType
    for name in ["encoder_model.onnx", "decoder_model.onnx"]:
        src = os.path.join(OUT, name)
        dst = os.path.join(OUT, name.replace(".onnx", ".int8.onnx"))
        if os.path.exists(dst) and os.path.getsize(dst) > 0:
            log(f"{name} already quantized")
            continue
        log(f"quantizing {name}")
        t0 = time.time()
        quantize_dynamic(src, dst, weight_type=QuantType.QInt8)
        log(f"  {os.path.getsize(src) / 1e6:.1f} MB fp32 -> "
            f"{os.path.getsize(dst) / 1e6:.1f} MB int8 in {time.time() - t0:.0f}s")

    # Only three files may leave this step: the two int8 models and tokens.txt. Everything else in
    # Model/WhisperNikud is an input to quantization (the ~3 GB fp32 exports and the sidecar ONNX
    # writes for anything over 2 GB, whatever it is called this time) and would ship as dead weight
    # in the app bundle and in every IPA. The sweep is by pattern, not by remembered file name: a
    # sidecar that slipped through would be 2.5 GB nobody asked for.
    keep = {"encoder_model.int8.onnx", "decoder_model.int8.onnx", "tokens.txt"}
    # The int8 files must stand alone before the sweep removes what they could be pointing at: an
    # int8 model that still referenced the fp32 sidecar would be dead the moment the sidecar goes.
    for name in ("encoder_model.int8.onnx", "decoder_model.int8.onnx"):
        if uses_external_data(os.path.join(OUT, name)):
            raise SystemExit(f"[prepare_stt_nikud] {name} still references external data - "
                             "the sidecar it needs would be removed, so nothing is deleted")
    for name in sorted(os.listdir(OUT)):
        if name in keep:
            continue
        path = os.path.join(OUT, name)
        size = os.path.getsize(path) / 1e6
        os.remove(path)
        log(f"removed {name} ({size:.1f} MB) - only int8 ships")


def uses_external_data(path):
    """True when an ONNX file still points at a `<name>.onnx_data` sidecar beside it."""
    import onnx
    model = onnx.load(path, load_external_data=False)
    return any(i.data_location == onnx.TensorProto.EXTERNAL for i in model.graph.initializer)


def stamp_encoder_metadata():
    """Write the metadata sherpa-onnx reads out of the encoder. Without it the app dies on Start.

    sherpa-onnx infers nothing from the graph: `InitEncoder` reads n_mels, n_text_layer, n_text_ctx,
    n_text_state, n_vocab, sot, eot, blank_id, translate, transcribe, is_multilingual, no_timestamps,
    no_speech, sot_sequence, all_language_tokens and all_language_codes out of the encoder's metadata
    and **aborts the process** when one is missing — "'n_mels' does not exist in the metadata" is
    the message, and it takes the whole app down with it the moment the recogniser is built.
    optimum's export writes none of these keys, which is why the phone closed on Start. The values
    come from the checkpoint's own config and tokenizer — the same ones sherpa-onnx's
    scripts/whisper/export-onnx.py writes.
    """
    import onnx
    from transformers import WhisperConfig, WhisperTokenizer

    path = os.path.join(OUT, "encoder_model.int8.onnx")
    config = WhisperConfig.from_pretrained(RAW)
    # The *slow* tokenizer on purpose: half the Hebrew checkpoints on Hugging Face ship vocab.json
    # and merges.txt but no tokenizer.json, and the fast one needs tokenizer.json. The slow one is
    # a port of Whisper's own tokenizer and exposes the same ids.
    tokenizer = WhisperTokenizer.from_pretrained(RAW)

    # blank_id is the id of the space token ("Ġ" in GPT-2 byte-level BPE). Read it from the file we
    # just wrote instead of asking the tokenizer, whose encode() adds the special tokens by default.
    space_id = None
    with open(os.path.join(OUT, "tokens.txt"), "r", encoding="utf-8") as fh:
        for line in fh:
            parts = line.split()
            if len(parts) == 2 and parts[0] == "Ġ":
                space_id = int(parts[1])
                break
    if space_id is None:
        raise SystemExit("[prepare_stt_nikud] tokens.txt has no space token - cannot set blank_id")

    codes = list(tokenizer.all_language_codes)
    meta = {
        "model_type": "whisper",
        "version": "1",
        "n_mels": config.num_mel_bins,
        "n_audio_ctx": config.max_source_positions,
        "n_audio_state": config.d_model,
        "n_audio_head": config.encoder_attention_heads,
        "n_audio_layer": config.encoder_layers,
        "n_vocab": config.vocab_size,
        "n_text_ctx": config.max_target_positions,
        "n_text_state": config.d_model,
        "n_text_head": config.decoder_attention_heads,
        "n_text_layer": config.decoder_layers,
        "sot": tokenizer.sot,
        "eot": tokenizer.eot,
        "blank_id": space_id,
        "translate": tokenizer.translate,
        "transcribe": tokenizer.transcribe,
        "no_timestamps": tokenizer.no_timestamps,
        "no_speech": tokenizer.no_speech,
        "sot_prev": tokenizer.sot_prev,
        "sot_lm": tokenizer.sot_lm,
        "is_multilingual": int(len(codes) > 0),
        "sot_index": list(tokenizer.sot_sequence).index(tokenizer.sot),
        "sot_sequence": ",".join(str(t) for t in tokenizer.sot_sequence),
        "all_language_tokens": ",".join(str(t) for t in tokenizer.all_language_tokens),
        "all_language_codes": ",".join(codes),
        "non_speech_tokens": ",".join(str(t) for t in tokenizer.non_speech_tokens),
    }

    model = onnx.load(path)
    while len(model.metadata_props):
        model.metadata_props.pop()
    for key, value in meta.items():
        entry = model.metadata_props.add()
        entry.key = key
        entry.value = str(value)
    onnx.save(model, path)

    # Quantization rewrites the graph; the keys are verified on the file that actually ships.
    have = {p.key for p in onnx.load(path, load_external_data=False).metadata_props}
    needed = ["n_mels", "n_text_layer", "n_text_ctx", "n_text_state", "n_vocab", "sot", "eot",
              "blank_id", "translate", "transcribe", "is_multilingual", "no_timestamps",
              "no_speech", "sot_sequence"]
    if meta["is_multilingual"]:
        needed += ["all_language_tokens", "all_language_codes"]
    missing = [k for k in needed if k not in have]
    if missing:
        raise SystemExit(f"[prepare_stt_nikud] encoder metadata did not stick: {missing}")
    log(f"encoder metadata written: {len(meta)} keys, n_mels={meta['n_mels']}, "
        f"n_vocab={meta['n_vocab']}, {len(codes)} languages, blank_id={space_id}")


def write_meta():
    """What the Swift recognizer needs: file names and the special token ids."""
    gen_path = os.path.join(RAW, "generation_config.json")
    gen = {}
    if os.path.exists(gen_path):
        with open(gen_path) as fh:
            gen = json.load(fh)
    meta = {
        "model": CHOSEN or MODEL,
        "runtime": "sherpa-onnx offline whisper",
        "encoder": "encoder_model.int8.onnx",
        "decoder": "decoder_model.int8.onnx",
        "tokens": "tokens.txt",
        "language": "he",
        "task": "transcribe",
        "decoder_start_token_id": gen.get("decoder_start_token_id"),
        "eos_token_id": gen.get("eos_token_id"),
        "pad_token_id": gen.get("pad_token_id"),
        "note": "The model emits pointed Hebrew (nikud) directly from the audio.",
    }
    with open(os.path.join(OUT, "model_info.json"), "w") as fh:
        json.dump(meta, fh, indent=2)
    log("model_info.json written")


def main():
    os.makedirs(OUT, exist_ok=True)
    download()
    log(f"checkpoint in use: {CHOSEN}")
    convert()
    quantize()
    stamp_encoder_metadata()
    write_meta()
    total = sum(os.path.getsize(os.path.join(OUT, f)) for f in os.listdir(OUT))
    log(f"{OUT}: {total / 1e6:.1f} MB - {sorted(os.listdir(OUT))}")
    # The raw fp32 checkpoint is not needed after the conversion.
    if os.path.exists(RAW):
        shutil.rmtree(RAW, ignore_errors=True)
        log("raw checkpoint removed")


if __name__ == "__main__":
    main()
