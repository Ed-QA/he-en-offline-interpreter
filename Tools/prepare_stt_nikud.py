"""Prepare the Hebrew ASR model that puts nikud in the text straight from the voice.

Model: the ungated cantillation/Teamim checkpoint (first entry of CANDIDATES below) - Whisper
large-v3-turbo fine-tuned so that the recogniser itself emits pointed Hebrew. There is no post-hoc
diacritizer in this app any more: the points come from the acoustic model, in the same pass as the
words. Nothing gated is used, so a build needs no account and no token.

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

MODEL = ("cantillation/Teamim-IvritAI-large-v3-turbo-new_WeightDecay-0.005_"
         "Augmented_WithSRT_date-23-04-2025")
OUT = "Model/WhisperNikud"
RAW = "whisper_nikud_raw"
CONVERTER = "https://raw.githubusercontent.com/openai/whisper/main/whisper/assets/multilingual.tiktoken"

WANTED = ["encoder_model.onnx", "decoder_model.onnx", "tokens.txt"]

# Every Hebrew recogniser on Hugging Face that emits nikud itself, best fit first. The first one
# that downloads wins. Ratings: fit for this app (general Hebrew, speed, footprint). Ungated only —
# nothing here may need an account, a token or an accepted licence.
CANDIDATES = [
    {
        "repo": "cantillation/Teamim-IvritAI-large-v3-turbo-new_WeightDecay-0.005_"
                "Augmented_WithSRT_date-23-04-2025",
        "fit": 8,
        "why": "same base as ivrit-ai/whisper-large-v3-turbo, he-cantillation, turbo speed, ungated",
    },
    {
        "repo": "cantillation/Teamim-large-v3-turbo_WeightDecay-0.005_Augmented_date-07-05-2025",
        "fit": 7,
        "why": "openai/whisper-large-v3-turbo base, he-cantillation, turbo speed, ungated",
    },
    {
        "repo": "cantillation/whisper-medium-he-teamim-silsuless-ori-TrainAndVal-Nikud",
        "fit": 6,
        "why": "whisper-medium, nikud in its own name, ungated - slower than turbo, smaller RAM",
    },
    {
        "repo": "cantillation/whisper-small-he-teamim5",
        "fit": 4,
        "why": "whisper-small, ungated - smallest footprint that still points (approx 231 MB int8)",
    },
    {
        "repo": "cantillation/Teamim-tiny_Random-True_DropOut-0.1_WeightDecay-1e-06_"
                "Augmented_date-27-06-2024_09-48-25",
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

    Ungated checkpoints only: every entry in CANDIDATES downloads anonymously, so a build needs no
    account, no token and no accepted licence. Downloads go through huggingface_hub so shards, LFS
    and retries are its problem, not ours.
    """
    from huggingface_hub import snapshot_download

    os.makedirs(RAW, exist_ok=True)

    global CHOSEN
    for rank, cand in enumerate(CANDIDATES, start=1):
        repo = cand["repo"]
        log(f"[{rank}/{len(CANDIDATES)}] {repo} - fit {cand['fit']}/10 - {cand['why']}")
        try:
            snapshot_download(repo_id=repo, local_dir=RAW,
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

        # sherpa-onnx indexes its token table by the id the model emits, so the table has to reach as
        # far as the vocabulary does. The tiktoken file holds only the BPE vocabulary (50257 entries);
        # everything above it — the language tokens, <|transcribe|>, <|notimestamps|> and Whisper's
        # other control tokens — is an added token, and an id with no line is an id the runtime cannot
        # look up. Those lines are written here, base64 like every other field in the file.
        import base64 as _b64
        from transformers import WhisperConfig, WhisperTokenizer
        n_vocab = WhisperConfig.from_pretrained(RAW).vocab_size
        added = {tid: tok for tok, tid in WhisperTokenizer.from_pretrained(RAW).get_vocab().items()
                 if tid >= 50257}
        have = set()
        with open(tokens_path, "r", encoding="utf-8") as fh:
            for line in fh:
                parts = line.split()
                if len(parts) == 2 and parts[1].isdigit():
                    have.add(int(parts[1]))
        missing = [i for i in range(n_vocab) if i not in have]
        if missing:
            with open(tokens_path, "a", encoding="utf-8") as fh:
                for i in missing:
                    token = _b64.b64encode(added.get(i, f"<unused_{i}>").encode()).decode()
                    fh.write(f"{token} {i}\n")
            log(f"tokens.txt padded with {len(missing)} ids the checkpoint has beyond the BPE vocabulary")

    for name in WANTED:
        path = os.path.join(OUT, name)
        if not os.path.exists(path):
            raise SystemExit(f"converter did not produce {path}")


def report_fp32_weight(dst):
    """Name the biggest fp32 initializer left in a quantized file.

    What matters for the app bundle is not the total size but what stayed in fp32: int8 weights are
    already as small as they go, and a large fp32 initializer means a node the quantizer skipped.
    Reading it out of the log beats inferring it from the file size, which is how a 265 MB token
    embedding sat unnoticed inside a "quantized" decoder.
    """
    import onnx

    def nbytes(init):
        count = 1
        for dim in init.dims:
            count *= dim
        return count * 4

    model = onnx.load(dst, load_external_data=False)
    floats = [(nbytes(init), init.name) for init in model.graph.initializer
              if init.data_type == onnx.TensorProto.FLOAT]
    floats.sort(reverse=True)
    total = sum(size for size, _ in floats)
    log(f"  {len(floats)} fp32 initializers, {total / 1e6:.1f} MB in total")
    for size, name in floats[:3]:
        log(f"    largest fp32: {name} ({size / 1e6:.1f} MB)")


def probe_fp32():
    """Decode Hebrew with the *unquantized* export, before quantization touches anything.

    The empty decode could be the export, the metadata, the checkpoint or the int8 conversion, and I
    have been guessing between them. This runs first, on the fp32 files, with the same runtime the
    app links: if fp32 speaks and int8 is empty, quantization is what broke it; if fp32 is also
    empty, the export or the checkpoint is, and the int8 step is innocent.
    """
    try:
        import sherpa_onnx
    except Exception as exc:
        log(f"fp32 probe skipped: {exc}")
        return

    encoder = os.path.join(OUT, "encoder_model.onnx")
    decoder = os.path.join(OUT, "decoder_model.onnx")
    tokens = os.path.join(OUT, "tokens.txt")
    if not all(os.path.exists(p) for p in (encoder, decoder, tokens)):
        log("fp32 probe skipped: an fp32 file is missing")
        return

    try:
        recognizer = sherpa_onnx.OfflineRecognizer.from_whisper(
            encoder=encoder, decoder=decoder, tokens=tokens,
            language="he", task="transcribe", num_threads=2, debug=False)
    except Exception as exc:
        log(f"fp32 probe could not build the recogniser: {type(exc).__name__}: {exc}")
        return

    wav = "hebrew_fp32_probe.wav"
    make_probe_wav(wav)
    try:
        import array
        import wave
        with wave.open(wav, "rb") as w:
            frames = w.readframes(w.getnframes())
        samples = [s / 32768.0 for s in array.array("h", frames)]
        stream = recognizer.create_stream()
        stream.accept_waveform(16_000, samples)
        recognizer.decode_stream(stream)
        text = stream.result.text.strip()
        marks = sum(1 for c in text if 0x05B0 <= ord(c) <= 0x05C7)
        log(f"fp32 decode: {text!r} ({marks} nikud marks)")
        if not text:
            raise SystemExit(
                "[prepare_stt_nikud] the unquantized export decoded nothing - the export is broken, "
                "nothing is shipped")
    except SystemExit:
        raise
    except Exception as exc:
        raise SystemExit(f"[prepare_stt_nikud] the unquantized export failed to decode: "
                         f"{type(exc).__name__}: {exc}") from exc
    finally:
        if os.path.exists(wav):
            os.remove(wav)


def make_probe_wav(path):
    """A fixed Hebrew sentence at 16 kHz mono, spoken by the macOS voice; silence if it is absent."""
    import subprocess
    import wave

    aiff = path + ".aiff"
    try:
        subprocess.run(["say", "-v", "Carmit", "-o", aiff,
                        "שלום, מה שלומך? אני מדבר עברית"], check=True)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, path],
                       check=True)
        os.remove(aiff)
    except Exception:
        with wave.open(path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(16_000)
            w.writeframes(b"\x00\x00" * 32_000)


def quantize():
    """int8 for the phone: 3.1 GB fp32 is not something to carry in an app bundle.

    Dynamic quantization is MatMul-shaped by design. `quantize_dynamic` hard-codes uint8 activations
    (onnxruntime/python/tools/quantization/quantize.py: "dynamic activation only supports uint8"),
    and under uint8 activations its Gather quantizer skips the node outright — so the decoder's
    51897x1280 token embedding stays fp32. That is 265 MB of the file, and the reason the decoder
    comes out at 426.8 MB where ~230 MB looks reachable. It is not reachable through this API; the
    fp32 report below names it in the log so the size is never a mystery again.
    """
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
        report_fp32_weight(dst)

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


def stamp_encoder_metadata(name="encoder_model.int8.onnx"):
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
    import base64
    import onnx
    import re
    from transformers import WhisperConfig, WhisperTokenizer

    path = os.path.join(OUT, name)
    config = WhisperConfig.from_pretrained(RAW)
    # The *slow* tokenizer on purpose: half the Hebrew checkpoints on Hugging Face ship vocab.json
    # and merges.txt but no tokenizer.json, and the fast one needs tokenizer.json.
    tokenizer = WhisperTokenizer.from_pretrained(RAW)

    def token_id(token):
        """Special-token ids by name. The tokenizer's convenience attributes differ between
        transformers versions (`.sot` does not exist on 4.46); the vocabulary never does.

        No unknown-token comparison here on purpose: Whisper's unknown token *is* `<|endoftext|>`, so
        comparing against `unk_token_id` rejects the end-of-text id itself.
        """
        if token not in tokenizer.get_vocab():
            raise SystemExit(f"[prepare_stt_nikud] {token} is not in this tokenizer")
        return tokenizer.convert_tokens_to_ids(token)

    # blank_id is the id of the space token. tokens.txt is Whisper's tiktoken file, whose first field
    # is the token's bytes in base64 (that is the form the runtime expects), so the space is found by
    # decoding rather than by looking for a spelling.
    space_id = None
    with open(os.path.join(OUT, "tokens.txt"), "r", encoding="utf-8") as fh:
        for line in fh:
            parts = line.split()
            if len(parts) == 2:
                try:
                    if base64.b64decode(parts[0]) == b" ":
                        space_id = int(parts[1])
                        break
                except Exception:
                    continue
    if space_id is None:
        raise SystemExit("[prepare_stt_nikud] tokens.txt has no space token - cannot set blank_id")

    # The language tokens and their codes, taken from the vocabulary itself: every `<|xx|>` entry is a
    # language, sorted by id so the two lists stay aligned. sherpa-onnx builds its language map from
    # exactly these, and refuses to work with the checkpoint's language without them.
    pairs = sorted(
        ((tok, tid) for tok, tid in tokenizer.get_vocab().items()
         if re.fullmatch(r"<\|[a-z]{2,3}\|>", tok)),
        key=lambda pair: pair[1],
    )
    sot = token_id("<|startoftranscript|>")
    transcribe = token_id("<|transcribe|>")
    no_timestamps = token_id("<|notimestamps|>")
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
        "sot": sot,
        "eot": token_id("<|endoftext|>"),
        "blank_id": space_id,
        "translate": token_id("<|translate|>"),
        "transcribe": transcribe,
        "no_timestamps": no_timestamps,
        "no_speech": token_id("<|nospeech|>"),
        "sot_prev": token_id("<|startofprev|>"),
        "sot_lm": token_id("<|startoflm|>"),
        "is_multilingual": int(len(pairs) > 0),
        "sot_index": 0,
        # The prompt the decoder starts from. It must name the language the audio is in: sherpa-onnx
        # takes this vector verbatim as the initial tokens, and the only other place it looks at
        # `language` is language *candidates*. Stamped with `<|en|>` the model is told it is hearing
        # English while it is handed Hebrew, and it answers with nothing — `decoded: ''`.
        "sot_sequence": ",".join(str(t) for t in (sot, token_id("<|he|>"), transcribe, no_timestamps)),
        "all_language_tokens": ",".join(str(tid) for _, tid in pairs),
        "all_language_codes": ",".join(tok[2:-2] for tok, _ in pairs),
    }
    codes = meta["all_language_codes"].split(",")

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
    # Stamp the fp32 encoder first so the probe can load it: sherpa-onnx refuses to build a
    # recogniser without the metadata, so without this the fp32 decode below could never run and the
    # question "export, metadata, checkpoint or quantization?" would stay unanswered.
    stamp_encoder_metadata("encoder_model.onnx")
    probe_fp32()
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
