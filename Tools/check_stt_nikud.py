#!/usr/bin/env python3
"""Prove the model that is about to ship really loads and decodes in sherpa-onnx.

The phone died the moment the recogniser was built and nothing here could see it coming: the tests
looked at file names and sizes, and the runtime itself was only ever exercised on the phone. This
runs that same runtime — the Python wheel is the same C++ library the app links — over a Hebrew
sentence, and fails the build if the recogniser cannot be built or cannot decode. It is the check
that turns "the app closes on Start" into a red build.

The sentence is spoken by the macOS Hebrew voice (Carmit); if that voice is not installed the check
falls back to two seconds of silence, which still proves the model loads.
"""

import argparse
import array
import os
import subprocess
import sys
import wave

HEBREW = "שלום, מה שלומך? אני מדבר עברית"


def log(msg):
    print(f"[check-stt-nikud] {msg}", flush=True)


def make_hebrew_wav(path):
    aiff = path + ".aiff"
    try:
        subprocess.run(["say", "-v", "Carmit", "-o", aiff, HEBREW], check=True)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, path],
                       check=True)
        os.remove(aiff)
        log("Hebrew test sentence spoken by the macOS voice Carmit")
    except Exception as exc:  # no voice on this runner: silence still proves the model loads
        log(f"no Hebrew voice available ({type(exc).__name__}) - using silence instead")
        with wave.open(path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(16_000)
            w.writeframes(b"\x00\x00" * 32_000)


def read_wav(path):
    with wave.open(path, "rb") as w:
        if w.getframerate() != 16_000 or w.getnchannels() != 1:
            raise SystemExit("[check-stt-nikud] the fixture is not 16 kHz mono")
        frames = w.readframes(w.getnframes())
    return [s / 32768.0 for s in array.array("h", frames)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--folder", default="Model/WhisperNikud")
    parser.add_argument("--wav", default="hebrew_check.wav")
    args = parser.parse_args()

    import sherpa_onnx

    encoder = os.path.join(args.folder, "encoder_model.int8.onnx")
    decoder = os.path.join(args.folder, "decoder_model.int8.onnx")
    tokens = os.path.join(args.folder, "tokens.txt")
    for path in (encoder, decoder, tokens):
        if not os.path.exists(path):
            raise SystemExit(f"[check-stt-nikud] {path} is missing")

    log(f"sherpa-onnx {getattr(sherpa_onnx, '__version__', '?')}: building the recogniser")
    recognizer = sherpa_onnx.OfflineRecognizer.from_whisper(
        encoder=encoder,
        decoder=decoder,
        tokens=tokens,
        language="he",
        task="transcribe",
        num_threads=2,
        debug=False,
    )
    log("the recogniser is built - this is the step that killed the app before")

    make_hebrew_wav(args.wav)
    samples = read_wav(args.wav)
    stream = recognizer.create_stream()
    stream.accept_waveform(16_000, samples)
    recognizer.decode_stream(stream)
    text = stream.result.text.strip()

    pointed = [c for c in text if 0x05B0 <= ord(c) <= 0x05C7]
    log(f"decoded: {text!r}")
    log(f"nikud in the output: {len(pointed)} marks")
    if not text:
        log("warning: no text came back - the model loaded, but check the checkpoint")
    elif not pointed:
        log("warning: text came back without nikud - check which checkpoint was downloaded")
    os.remove(args.wav)
    return 0


if __name__ == "__main__":
    sys.exit(main())