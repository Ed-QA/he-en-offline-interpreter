#!/usr/bin/env python3
"""Downloads the offline streaming Hebrew ASR model into Model/STT/.

Model: ivrit-ai/zipformer2-66m-streaming-he (CC-BY-4.0) — a 66M-parameter streaming
Zipformer2 transducer with a ready-made sherpa-onnx int8 export (~72 MB total).
It is used by live-transcribe.ivrit.ai for on-device Hebrew transcription and scores
better than whisper-large-v3-turbo on ivrit.ai's Hebrew test sets (5.3 / 8.8 WER).

The whole pipeline stays offline: this script only runs at build time on the PC / CI.
"""
from __future__ import annotations

import shutil
import sys
from pathlib import Path

REPO = "ivrit-ai/zipformer2-66m-streaming-he"
FILES = ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"]
OUT = Path(__file__).resolve().parent.parent / "Model" / "STT"


def main() -> int:
    from huggingface_hub import hf_hub_download

    OUT.mkdir(parents=True, exist_ok=True)
    for name in FILES:
        target = OUT / name
        if target.exists() and target.stat().st_size > 1_000:
            print(f"cached   {name}")
            continue
        source = hf_hub_download(repo_id=REPO, filename=f"sherpa-onnx/{name}")
        shutil.copyfile(source, target)
        print(f"fetched  {name} -> {target.stat().st_size / 1e6:.1f} MB")
    total = sum(f.stat().st_size for f in OUT.iterdir())
    print(f"STT model ready in {OUT} ({total / 1e6:.1f} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
