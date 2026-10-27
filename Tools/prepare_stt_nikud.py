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
CONVERTER = "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/master/scripts/whisper/convert.py"

WANTED = ["encoder_model.onnx", "decoder_model.onnx", "tokens.txt"]


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
    if not token:
        log("no HF_TOKEN in the environment")
        print("::warning::HF_TOKEN is not set, so Model/WhisperNikud cannot be fetched from the "
              "gated checkpoint MayBog/whisper-hebrew-nikud-v1. This build has no Hebrew "
              "recogniser model: accept the model terms at "
              "https://huggingface.co/MayBog/whisper-hebrew-nikud-v1, create a read token and set "
              "the repository secret HF_TOKEN. The app compiles and runs either way.", flush=True)
        sys.exit(0)
    log("using HF_TOKEN from the environment")
    snapshot_download(
        repo_id=MODEL,
        local_dir=RAW,
        token=token,
        allow_patterns=["*.json", "*.txt", "model.safetensors"],
    )
    weights = os.path.join(RAW, "model.safetensors")
    if not os.path.exists(weights):
        raise SystemExit(f"[prepare_stt_nikud] {MODEL} gave no model.safetensors (gated model, token missing?)")
    log(f"model.safetensors: {os.path.getsize(weights) / 1e6:.1f} MB")


def convert():
    """PyTorch -> ONNX with sherpa-onnx's own converter (the layout the runtime expects)."""
    if os.path.exists(os.path.join(OUT, "encoder_model.onnx")) and \
       os.path.exists(os.path.join(OUT, "decoder_model.onnx")):
        log("ONNX models already exported")
        return
    if not os.path.exists("convert_whisper.py"):
        log("fetching sherpa-onnx whisper converter")
        urllib.request.urlretrieve(CONVERTER, "convert_whisper.py")
    os.makedirs(OUT, exist_ok=True)
    cmd = [sys.executable, "convert_whisper.py",
           "--model", RAW,
           "--output-dir", OUT,
           "--model-type", "whisper",
           "--add-model-metadata", "0"]
    log("running: " + " ".join(cmd))
    subprocess.run(cmd, check=True)
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


def write_meta():
    """What the Swift recognizer needs: file names and the special token ids."""
    with open(os.path.join(RAW, "generation_config.json")) as fh:
        gen = json.load(fh)
    meta = {
        "model": MODEL,
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
    convert()
    quantize()
    write_meta()
    total = sum(os.path.getsize(os.path.join(OUT, f)) for f in os.listdir(OUT))
    log(f"{OUT}: {total / 1e6:.1f} MB - {sorted(os.listdir(OUT))}")
    # The raw fp32 checkpoint is not needed after the conversion.
    if os.path.exists(RAW):
        shutil.rmtree(RAW, ignore_errors=True)
        log("raw checkpoint removed")


if __name__ == "__main__":
    main()
