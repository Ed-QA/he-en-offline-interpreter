#!/usr/bin/env python3
"""
Prepares the fully-offline Hebrew -> English translation model that ships inside the app.

Steps:
  1. Download Helsinki-NLP/opus-mt-tc-big-he-en (MarianMT).
  2. Export encoder + decoder (no KV cache) to ONNX with optimum.
  3. Dynamically quantize both to int8 with onnxruntime.
  4. Write tokenizer.json (fast tokenizer) + config files the app needs.
  5. Write Model/model_info.json with the exact ONNX input/output names and special ids.
  6. Sanity-check the greedy decode loop (fp32 vs int8) and print sample translations.

Output folder: ./Model   (the app bundle copies this folder verbatim)
"""
import json
import os
import shutil
import time

MODEL = "Helsinki-NLP/opus-mt-tc-big-he-en"
OUT = "Model"
RAW = "onnx_raw"

SAMPLES = [
    "אני לומד עברית כל יום עם חברים שלי.",
    "היא אמרה לי שהיא תחזור הביתה מאוחר היום.",
]

# Files the app bundle needs (name -> source in RAW)
WANTED = ["encoder_model.onnx", "decoder_model.onnx"]
# Extra files copied next to the tokenizer for completeness / debugging
EXTRA = ["tokenizer_config.json", "special_tokens_map.json", "vocab.json",
         "source.spm", "target.spm", "config.json", "generation_config.json"]


def log(msg):
    print(f"[prepare_model] {msg}", flush=True)


def export_onnx():
    marker = os.path.join(RAW, "decoder_model.onnx")
    if os.path.exists(marker):
        log(f"re-using existing export in {RAW}")
        return
    from optimum.exporters.onnx import main_export
    log(f"exporting {MODEL} to ONNX (task=text2text-generation-with-past)…")
    t0 = time.time()
    main_export(model_name_or_path=MODEL, output=RAW,
                task="text2text-generation-with-past", opset=17)
    log(f"export finished in {time.time() - t0:.0f}s")


def quantize():
    from onnxruntime.quantization import quantize_dynamic, QuantType
    for name in WANTED:
        src = os.path.join(RAW, name)
        dst = os.path.join(OUT, name)
        if os.path.exists(dst) and os.path.getsize(dst) > 1_000_000:
            log(f"{name} already quantized — skipping")
            continue
        if not os.path.exists(src):
            raise SystemExit(f"missing export: {src} (files: {sorted(os.listdir(RAW))})")
        t0 = time.time()
        quantize_dynamic(src, dst, weight_type=QuantType.QInt8)
        mb = os.path.getsize(dst) / 1e6
        log(f"quantized {name}: {mb:.1f} MB in {time.time() - t0:.0f}s")


def write_tokenizer_and_configs():
    from transformers import AutoTokenizer, MarianConfig
    fast = AutoTokenizer.from_pretrained(MODEL, use_fast=True)
    fast.save_pretrained(OUT)          # writes tokenizer.json + tokenizer_config.json
    log("wrote fast tokenizer (tokenizer.json)")
    cfg = MarianConfig.from_pretrained(MODEL)
    cfg.to_json_file(os.path.join(OUT, "config.json"))
    for name in EXTRA:
        src = os.path.join(RAW, name)
        if os.path.exists(src):
def load_sessions(folder):
    import onnxruntime as ort
    opts = ort.SessionOptions()
    opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    enc = ort.InferenceSession(os.path.join(folder, "encoder_model.onnx"), opts,
                               providers=["CPUExecutionProvider"])
    dec = ort.InferenceSession(os.path.join(folder, "decoder_model.onnx"), opts,
                               providers=["CPUExecutionProvider"])
    return enc, dec


def pick(inputs, *keys):
    """Return the first input/output name that contains one of the given keys."""
    for i in inputs:
        low = i.name.lower()
        for k in keys:
            if k in low:
                return i.name
    raise SystemExit(f"no name matching {keys}; have {[i.name for i in inputs]}")


def greedy(enc, dec, tok, text, decoder_start, eos, max_new=96):
    """Plain greedy decode over the non-cached decoder — same recipe the Swift app uses."""
    import numpy as np
    ids = tok(text)["input_ids"]
    input_ids = np.array([ids], dtype=np.int64)
    attn = np.ones_like(input_ids)
    hidden = enc.run(None, {
        pick(enc.get_inputs(), "input_ids"): input_ids,
        pick(enc.get_inputs(), "attention_mask"): attn,
    })[0]

    dec_inputs = dec.get_inputs()
    id_name = pick(dec_inputs, "input_ids")
    mask_name = pick(dec_inputs, "encoder_attention_mask", "attention_mask")
    hid_name = pick(dec_inputs, "encoder_hidden_states")
    logits_name = pick(dec.get_outputs(), "logits")

    gen = [int(decoder_start)]
    t0 = time.time()
    for _ in range(max_new):
        logits = dec.run([logits_name], {
            id_name: np.array([gen], dtype=np.int64),
            mask_name: attn,
            hid_name: hidden,
        })[0]
        nxt = int(np.argmax(logits[0, -1]))
        if nxt == eos:
            break
        gen.append(nxt)
    return tok.decode(gen, skip_special_tokens=True), time.time() - t0


def write_meta(enc, dec, decoder_start, eos, max_new):
    meta = {
        "model": MODEL,
        "quantized": "int8-dynamic",
        "decoder_start_token_id": int(decoder_start),
        "eos_token_id": int(eos),
        "max_new_tokens": int(max_new),
        "encoder_inputs": [i.name for i in enc.get_inputs()],
        "encoder_outputs": [o.name for o in enc.get_outputs()],
        "decoder_inputs": [i.name for i in dec.get_inputs()],
        "decoder_outputs": [o.name for o in dec.get_outputs()],
    }
    with open(os.path.join(OUT, "model_info.json"), "w") as fh:
        json.dump(meta, fh, indent=1)
    log("model_info.json: " + json.dumps(meta, indent=1))


def main():
    os.makedirs(OUT, exist_ok=True)
    export_onnx()
    quantize()
    write_tokenizer_and_configs()

    from transformers import AutoTokenizer, MarianConfig
    tok = AutoTokenizer.from_pretrained(MODEL)
    cfg = MarianConfig.from_pretrained(MODEL)
    decoder_start = cfg.decoder_start_token_id if cfg.decoder_start_token_id is not None else cfg.pad_token_id
    eos = cfg.eos_token_id
    max_new = min(96, int(getattr(cfg, "max_length", 96) or 96))

    enc_q, dec_q = load_sessions(OUT)          # int8 — what actually ships
    write_meta(enc_q, dec_q, decoder_start, eos, max_new)

    enc_f, dec_f = load_sessions(RAW)          # fp32 reference for quality comparison
    for sample in SAMPLES:
        ref, t_ref = greedy(enc_f, dec_f, tok, sample, decoder_start, eos, max_new)
        got, t_q = greedy(enc_q, dec_q, tok, sample, decoder_start, eos, max_new)
        log(f"HE: {sample}")
        log(f"  fp32 ({t_ref:4.1f}s): {ref}")
        log(f"  int8 ({t_q:4.1f}s): {got}")

    total = sum(os.path.getsize(os.path.join(OUT, f)) for f in os.listdir(OUT))
    log(f"{OUT}: {total / 1e6:.1f} MB — {sorted(os.listdir(OUT))}")


if __name__ == "__main__":
    main()

            shutil.copy(src, os.path.join(OUT, name))
