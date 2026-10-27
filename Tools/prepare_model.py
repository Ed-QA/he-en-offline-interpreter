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

# Two language pairs ship: Hebrew → English (the original) and Hebrew → Ukrainian. Each pair is
# exported, quantized and self-tested the same way, into its own folder, so the app only reads the
# Ukrainian model when Ukrainian is the language selected in Settings.
PAIRS = [
    {
        "model": "Helsinki-NLP/opus-mt-tc-big-he-en",
        "out": "Model",
        "raw": "onnx_raw",
        "samples": [
            "אני לומד עברית כל יום עם חברים שלי.",
            "היא אמרה לי שהיא תחזור הביתה מאוחר היום.",
        ],
    },
    {
        "model": "Helsinki-NLP/opus-mt-he-uk",
        "out": "Model-uk",
        "raw": "onnx_raw_uk",
        "samples": [
            "אני לומד עברית כל יום עם חברים שלי.",
            "היא אמרה לי שהיא תחזור הביתה מאוחר היום.",
        ],
    },
]

# The pair currently being prepared — run_pair() sets these, the helpers below read them.
MODEL = PAIRS[0]["model"]
OUT = PAIRS[0]["out"]
RAW = PAIRS[0]["raw"]
SAMPLES = PAIRS[0]["samples"]

# Files the app bundle needs (name -> source in RAW)
WANTED = ["encoder_model.onnx", "decoder_model.onnx"]
# Extra files copied next to the tokenizer for completeness / debugging
EXTRA = ["tokenizer_config.json", "special_tokens_map.json", "vocab.json",
         "source.spm", "target.spm", "config.json", "generation_config.json"]


def log(msg):
    try:
        print(f"[prepare_model] {msg}", flush=True)
    except UnicodeEncodeError:  # Windows consoles default to cp1252
        print(f"[prepare_model] {str(msg).encode('ascii', 'replace').decode()}", flush=True)


def export_onnx():
    marker = os.path.join(RAW, "decoder_model.onnx")
    if os.path.exists(marker):
        log(f"re-using existing export in {RAW}")
        return
    log(f"exporting {MODEL} to ONNX (task=text2text-generation-with-past)…")
    t0 = time.time()
    try:
        from optimum.exporters.onnx import main_export
        main_export(model_name_or_path=MODEL, output=RAW,
                    task="text2text-generation-with-past", opset=17)
    except ModuleNotFoundError as exc:
        import subprocess
        import importlib.metadata as md
        log(f"python export API unavailable ({exc}); optimum={md.version('optimum')} — using optimum-cli")
        subprocess.run(["optimum-cli", "export", "onnx",
                        "--model", MODEL,
                        "--task", "text2text-generation-with-past",
                        "--opset", "17", RAW], check=True)
    log(f"export finished in {time.time() - t0:.0f}s")


def quantize():
    from onnxruntime.quantization import quantize_dynamic, QuantType
    try:
        from onnxruntime.quantization.shape_inference import quant_pre_process
    except ImportError:  # older ORT layouts
        from onnxruntime.quantization import quant_pre_process
    for name in WANTED:
        src = os.path.join(RAW, name)
        dst = os.path.join(OUT, name)
        if os.path.exists(dst) and 1_000_000 < os.path.getsize(dst) < 120_000_000:
            log(f"{name} already quantized — skipping")
            continue
        if not os.path.exists(src):
            raise SystemExit(f"missing export: {src} (files: {sorted(os.listdir(RAW))})")
        t0 = time.time()
        pre = src.replace(".onnx", ".pre.onnx")
        try:
            import collections
            import onnx
            types = collections.Counter(n.op_type for n in onnx.load(src, load_external_data=False).graph.node)
            log(f"{name} node types: {dict(types.most_common(8))}")
        except Exception as exc:  # noqa: BLE001
            log(f"node-type inspection failed: {exc}")
        log(f"pre-processing {name} (symbolic shape inference + ONNX simplify)…")
        quant_pre_process(src, pre)
        try:
            quantize_dynamic(pre, dst, weight_type=QuantType.QInt8,
                             op_types_to_quantize=["MatMul", "Gemm", "Attention", "Gather", "LSTM"])
        except Exception as exc:  # noqa: BLE001
            log(f"extended op list rejected ({exc}) — retrying with ORT defaults")
            quantize_dynamic(pre, dst, weight_type=QuantType.QInt8)
        mb = os.path.getsize(dst) / 1e6
        src_mb = os.path.getsize(src) / 1e6
        log(f"quantized {name}: {src_mb:.1f} MB fp32 → {mb:.1f} MB int8 in {time.time() - t0:.0f}s")


def write_tokenizer_and_configs():
    from transformers import AutoTokenizer, MarianConfig
    # Copy the tokenizer side files (source.spm/target.spm/vocab.json/…) first —
    # building tokenizer.json needs the SentencePiece models.
    for name in EXTRA:
        src = os.path.join(RAW, name)
        if os.path.exists(src):
            shutil.copy(src, os.path.join(OUT, name))
    tokenizer_json = os.path.join(OUT, "tokenizer.json")
    if os.path.exists(tokenizer_json) and os.path.getsize(tokenizer_json) > 1000:
        log("tokenizer.json already present")
    else:
        try:
            fast = AutoTokenizer.from_pretrained(MODEL, use_fast=True)
            fast.save_pretrained(OUT)
        except Exception as exc:  # noqa: BLE001
            log(f"use_fast=True path failed: {exc}")
        if not os.path.exists(tokenizer_json):
            log("building tokenizer.json directly from the SentencePiece models")
            build_tokenizer_json()
        if os.path.exists(tokenizer_json):
            log(f"tokenizer.json: {os.path.getsize(tokenizer_json) / 1e6:.2f} MB")
        else:
            log("WARNING: tokenizer.json could not be created — the app cannot tokenize")
    # swift-transformers chooses its tokenizer *model* from tokenizer_class: the
    # generic "PreTrainedTokenizer" entry maps to its BPE implementation (which
    # crashes on a Unigram file), while "XLMRobertaTokenizer" maps to Unigram —
    # the model type our tokenizer.json actually uses.
    config_path = os.path.join(OUT, "tokenizer_config.json")
    config = {}
    if os.path.exists(config_path):
        with open(config_path, encoding="utf-8") as handle:
            config = json.load(handle)
    config["tokenizer_class"] = "XLMRobertaTokenizer"
    config.setdefault("model_max_length", 512)
    with open(config_path, "w", encoding="utf-8") as handle:
        json.dump(config, handle, indent=1, ensure_ascii=False)
    log("tokenizer_config.json: tokenizer_class=XLMRobertaTokenizer (→ swift Unigram)")
    cfg = MarianConfig.from_pretrained(MODEL)
    cfg.to_json_file(os.path.join(OUT, "config.json"))


def _metaspace(module):
    """Metaspace with either the new (prepend_scheme) or old (add_prefix_space) API."""
    try:
        return module.Metaspace(replacement="▁", prepend_scheme="always")
    except TypeError:
        return module.Metaspace(replacement="▁", add_prefix_space=True)


def build_tokenizer_json():
    """Assemble tokenizer.json for a Marian model.

    The ids the network expects come from vocab.json (a shuffled 60k mapping, e.g.
    </s> = 25568), while the SentencePiece models only provide segmentation and
    scores. So the Unigram vocabulary is built in vocab.json id order with scores
    taken from source.spm — that makes the produced ids identical to HF's.
    """
    import sentencepiece as spm
    from tokenizers import Tokenizer, models, pre_tokenizers, decoders, processors

    source_spm = os.path.join(OUT, "source.spm")
    target_spm = os.path.join(OUT, "target.spm")
    vocab_file = os.path.join(OUT, "vocab.json")
    for path in (source_spm, target_spm, vocab_file):
        if not os.path.exists(path):
            raise SystemExit(f"missing tokenizer file: {path}")

    with open(vocab_file, encoding="utf-8") as handle:
        token_to_id = json.load(handle)

    source = spm.SentencePieceProcessor(model_file=source_spm)
    spm.SentencePieceProcessor(model_file=target_spm)
    scores = {source.id_to_piece(i): source.get_score(i) for i in range(source.get_piece_size())}

    size = max(token_to_id.values()) + 1
    ordered = [None] * size
    for piece, index in token_to_id.items():
        ordered[index] = piece
    gaps = [i for i, piece in enumerate(ordered) if piece is None]
    if gaps:
        raise SystemExit(f"vocab.json has gaps at ids {gaps[:5]}")

    vocab = [(piece, float(scores.get(piece, 0.0))) for piece in ordered]
    eos = int(token_to_id["</s>"])

    tokenizer = Tokenizer(models.Unigram(vocab, unk_id=int(token_to_id.get("<unk>", 0))))
    tokenizer.pre_tokenizer = _metaspace(pre_tokenizers)
    tokenizer.decoder = _metaspace(decoders)
    tokenizer.post_processor = processors.TemplateProcessing(
        single="$A </s>", special_tokens=[("</s>", eos)])

    tokenizer_json = os.path.join(OUT, "tokenizer.json")
    tokenizer.save(tokenizer_json)

    sample = "אני לומד עברית כל יום עם חברים שלי."
    ids = tokenizer.encode(sample).ids
    log(f"tokenizer self-test — ids: {ids[:12]} … (len {len(ids)}, eos {eos})")
    log(f"tokenizer self-test — roundtrip: {tokenizer.decode(ids)}")
    if ids[-1] != eos:
        log(f"WARNING: tokenizer did not append eos (last id {ids[-1]} != {eos})")

    try:
        from transformers import AutoTokenizer
        reference = AutoTokenizer.from_pretrained(MODEL)
        ref_ids = reference(sample)["input_ids"]
        log(f"HF reference ids: {ref_ids}")
        log(f"parity with HF tokenizer: {ref_ids == ids}")
        if ref_ids != ids:
            log("WARNING: built tokenizer ids differ from the HF tokenizer")
    except Exception as exc:  # noqa: BLE001
        log(f"HF parity check skipped: {exc}")


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


def run_pair(pair):
    """Export, quantize and self-test one language pair into its own folder."""
    global MODEL, OUT, RAW, SAMPLES
    MODEL, OUT, RAW, SAMPLES = pair["model"], pair["out"], pair["raw"], pair["samples"]
    log(f"=== {MODEL} -> {OUT} ===")
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


def main():
    for pair in PAIRS:
        run_pair(pair)


if __name__ == "__main__":
    main()

