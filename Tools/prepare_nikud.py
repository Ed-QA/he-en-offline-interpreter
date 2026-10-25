#!/usr/bin/env python3
"""Downloads the on-device Hebrew diacritizer (nikud) and the Silero VAD into Model/.

Why: unpointed Hebrew is ambiguous — a bare word can be read several ways, so neither a
human nor the MT model can be sure which reading is meant. The pipeline therefore
diacritizes the recognised sentence and translates the *pointed* text only.

  Model/Nikud/phonikud-1.0.int8.onnx   307,844,158 bytes  Phonikud/phonikud-onnx
  Model/Nikud/tokenizer.json                18,016 bytes  Phonikud/phonikud
  Model/VAD/silero_vad.onnx                643,854 bytes  k2-fsa/sherpa-onnx release

Phonikud is a character-level DictaBERT diacritizer (INTERSPEECH 2026,
arXiv:2506.12311) exported to int8 ONNX. It runs on the same ONNX Runtime the app already
links through sherpa-onnx (onnxruntime-libs 1.28.2). Reported diacritization accuracy of
this checkpoint: 85.44 % (wer_info.txt in the model repo).

The whole pipeline stays offline: this script only runs at build time on the PC / CI.
"""
from __future__ import annotations

import sys
import urllib.request
from pathlib import Path

NIKUD_REPO = "Phonikud/phonikud-onnx"
TOKENIZER_REPO = "Phonikud/phonikud"
VAD_URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"

ROOT = Path(__file__).resolve().parent.parent

# (destination, huggingface repo, file in the repo, minimum plausible size in bytes)
HF_FILES = [
    (ROOT / "Model" / "Nikud" / "phonikud-1.0.int8.onnx", NIKUD_REPO, "phonikud-1.0.int8.onnx", 100_000_000),
    (ROOT / "Model" / "Nikud" / "tokenizer.json", TOKENIZER_REPO, "tokenizer.json", 10_000),
]

VAD_TARGET = ROOT / "Model" / "VAD" / "silero_vad.onnx"
VAD_MIN_BYTES = 500_000


def fetch_hf(repo: str, name: str) -> Path:
    from huggingface_hub import hf_hub_download

    return Path(hf_hub_download(repo_id=repo, filename=name))


def fetch_url(url: str, target: Path) -> None:
    with urllib.request.urlopen(url) as response, open(target, "wb") as out:
        while chunk := response.read(1 << 20):
            out.write(chunk)


def main() -> int:
    for target, repo, name, minimum in HF_FILES:
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() and target.stat().st_size >= minimum:
            print(f"cached   {target.name}")
            continue
        source = fetch_hf(repo, name)
        target.write_bytes(source.read_bytes())
        print(f"fetched  {target.name} -> {target.stat().st_size:,} bytes")

    VAD_TARGET.parent.mkdir(parents=True, exist_ok=True)
    if VAD_TARGET.exists() and VAD_TARGET.stat().st_size >= VAD_MIN_BYTES:
        print(f"cached   {VAD_TARGET.name}")
    else:
        fetch_url(VAD_URL, VAD_TARGET)
        print(f"fetched  {VAD_TARGET.name} -> {VAD_TARGET.stat().st_size:,} bytes")

    total = sum(f.stat().st_size for f in (ROOT / "Model").rglob("*") if f.is_file())
    print(f"nikud + VAD ready in {ROOT / 'Model'} (Model/ is now {total / 1e6:.1f} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
