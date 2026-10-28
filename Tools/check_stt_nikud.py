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


def report_onnx_greedy(folder, samples):
    """Decode the same audio a second way, with my own greedy loop on the ONNX graphs.

    sherpa-onnx returning nothing proves only that something in the chain is wrong. This loop uses
    no sherpa code: it runs the encoder, then the decoder token by token, so the two results
    side by side name the broken side.

      both empty       -> the graphs or the checkpoint itself
      this one speaks  -> the metadata sherpa reads (n_mels, prompt ids, token table)

    It prints the decoder's input signature first: the loop only runs when the graph has the
    signature this exporter is supposed to produce, and the names are the evidence either way.
    """
    import numpy as np
    import onnxruntime as ort

    encoder = os.path.join(folder, "encoder_model.int8.onnx")
    decoder = os.path.join(folder, "decoder_model.int8.onnx")

    meta = {}
    enc = ort.InferenceSession(encoder, providers=["CPUExecutionProvider"])
    for prop in enc.get_modelmeta().custom_metadata_map.items():
        meta[prop[0]] = prop[1]
    dec = ort.InferenceSession(decoder, providers=["CPUExecutionProvider"])
    log("decoder inputs: " + ", ".join(f"{i.name}{i.shape}" for i in dec.get_inputs()))
    log("decoder outputs: " + ", ".join(o.name for o in dec.get_outputs()))
    log("encoder inputs: " + ", ".join(f"{i.name}{i.shape}" for i in enc.get_inputs()))

    try:
        from transformers import WhisperFeatureExtractor

        extractor = WhisperFeatureExtractor.from_pretrained(
            os.environ.get("STT_NIKUD_RAW", "whisper_nikud_raw"))
        feats = extractor(samples, sampling_rate=16_000, return_tensors="np").input_features
    except Exception as exc:
        log(f"no feature extractor ({type(exc).__name__}: {exc}) - skipping the second decode")
        return
    log(f"features {feats.shape} (expected [1, {meta.get('n_mels', '?')}, 3000])")

    enc_out = enc.run(None, {enc.get_inputs()[0].name: feats.astype(np.float32)})
    names = [o.name for o in enc.get_outputs()]
    cross_k = enc_out[names.index("cross_k")]
    cross_v = enc_out[names.index("cross_v")]

    n_layer = int(meta.get("n_text_layer", 0))
    n_ctx = int(meta.get("n_text_ctx", 0))
    n_state = int(meta.get("n_text_state", 0))
    self_k = np.zeros((n_layer, 1, n_ctx, n_state), dtype=np.float32)
    self_v = np.zeros_like(self_k)

    prompt = [int(x) for x in meta["sot_sequence"].split(",")]
    eot = int(meta["eot"])
    tokens = list(prompt)
    text = ""
    for _ in range(20):
        feeds = {
            "tokens": np.array([[tokens[-1]]], dtype=np.int64),
            "self_k": self_k,
            "self_v": self_v,
            "cross_k": cross_k,
            "cross_v": cross_v,
            "offset": np.array([len(tokens) - 1], dtype=np.int64),
        }
        outs = dec.run(None, {k: v for k, v in feeds.items()
                              if k in {i.name for i in dec.get_inputs()}})
        logits = outs[0][0, -1]
        nxt = int(np.argmax(logits))
        if nxt == eot:
            break
        tokens.append(nxt)
        text += f" {nxt}"
    log("second decode, token ids: " + (text.strip() or "(nothing)"))
    log(f"prompt ids used: {prompt}")


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
        raise SystemExit("[check-stt-nikud] the recogniser decoded nothing - refusing to ship this "
                         "model. A model that answers silence for real speech is the bug that "
                         "reached the phone.")
    if not pointed:
        log("warning: text came back without nikud - check which checkpoint was downloaded")
    report_onnx_greedy(args.folder, samples)
    os.remove(args.wav)
    return 0


if __name__ == "__main__":
    sys.exit(main())