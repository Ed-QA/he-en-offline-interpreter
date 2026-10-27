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
    """PyTorch -> ONNX in the layout sherpa-onnx's offline Whisper runtime reads.

    Exported with optimum (the same exporter the translation models already go through in this
    project), then tokens.txt is written from Whisper's own multilingual tiktoken vocabulary:
    lines of `<token> <id>`, the exact file and format the runtime expects beside
    encoder_model.onnx and decoder_model.onnx.
    """
    if os.path.exists(os.path.join(OUT, "encoder_model.onnx")) and \
       os.path.exists(os.path.join(OUT, "decoder_model.onnx")):
        log("ONNX models already exported")
    else:
        os.makedirs(OUT, exist_ok=True)
        cmd = [sys.executable, "-m", "optimum.exporters.onnx",
               "--model", RAW,
               "--task", "automatic-speech-recognition",
               "--opset", "17",
               "--no-post-process",
               OUT]
        log("running: " + " ".join(cmd))
        subprocess.run(cmd, check=True)
        # The cached-decoder variant is not used by sherpa-onnx and doubles the bundle.
        past = os.path.join(OUT, "decoder_with_past_model.onnx")
        if os.path.exists(past):
            os.remove(past)
            log("removed decoder_with_past_model.onnx (not used by the runtime)")

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

    # The fp32 exports exist only as input to quantization. Leaving them in Model/ put ~3 GB of
    # dead weight into the app bundle and into every IPA — they are deleted the moment int8 exists.
    for name in sorted(os.listdir(OUT)):
        if name.endswith(".onnx") and not name.endswith(".int8.onnx"):
            path = os.path.join(OUT, name)
            size = os.path.getsize(path) / 1e6
            os.remove(path)
            log(f"removed fp32 {name} ({size:.1f} MB) - only int8 ships")


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
    write_meta()
    total = sum(os.path.getsize(os.path.join(OUT, f)) for f in os.listdir(OUT))
    log(f"{OUT}: {total / 1e6:.1f} MB - {sorted(os.listdir(OUT))}")
    # The raw fp32 checkpoint is not needed after the conversion.
    if os.path.exists(RAW):
        shutil.rmtree(RAW, ignore_errors=True)
        log("raw checkpoint removed")


if __name__ == "__main__":
    main()
