# PLAN — offline Hebrew → English interpreter

## Main meta rule

**Answers short.** The reply is the answer itself — a link, a file name, a number, a one-line
status. No essays, no tables unless asked, no repeating the question, no recaps of work.

## Files / links (exact names, exact sizes — measured)

### Gated — dropped, no token is used
- `https://huggingface.co/MayBog/whisper-hebrew-nikud-v1` — needs an account and an accepted licence, so it is out of the pipeline entirely (see CANDIDATES in `Tools/prepare_stt_nikud.py`).

### Diacritizer (nikud) + VAD — fetched by `Tools/prepare_nikud.py`
- `phonikud-1.0.int8.onnx` — 307,844,158 B — `https://huggingface.co/Phonikud/phonikud-onnx/resolve/main/phonikud-1.0.int8.onnx`
- `tokenizer.json` — 18,016 B — `https://huggingface.co/Phonikud/phonikud/resolve/main/tokenizer.json`
- `silero_vad.onnx` — 643,854 B — `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx`

### STT (current engine) — fetched by `Tools/prepare_stt.py`
- `encoder.int8.onnx` — 70,478,964 B — `https://huggingface.co/ivrit-ai/zipformer2-66m-streaming-he/resolve/main/sherpa-onnx/encoder.int8.onnx`
- `decoder.int8.onnx` — 1,049,105 B — `.../sherpa-onnx/decoder.int8.onnx`
- `joiner.int8.onnx` — 771,805 B — `.../sherpa-onnx/joiner.int8.onnx`
- `tokens.txt` — 17,100 B — `.../sherpa-onnx/tokens.txt`

### Translation — `Helsinki-NLP/opus-mt-tc-big-he-en`
- `https://huggingface.co/Helsinki-NLP/opus-mt-tc-big-he-en`
- built by `Tools/prepare_model.py`: encoder 553.5 MB fp32 → 138.7 MB int8, decoder 901.5 MB fp32 → 226.2 MB int8, tokenizer.json 3.59 MB

### TTS
- none — native `AVSpeechSynthesizer` (`Sources/TTS.swift`)

## Status (2026-10-25) — sim gate GREEN

`Simulator tests (no device)` = **success**, `Build unsigned IPA` = **success** (runs 40239537767 / 40239537842).
26 unit tests, 0 failures, 0 skipped; UI tests 2/2; the real diacritizer ran in CI: `POINTED: שְׁלוֹם עוֹלָם`.

Fixes on the way from red to green (all on `main`):
- `44c1904` `LogEntry.hebrew` must be `var`
- `3fbe22d` match the log entry by the *pointed* sentence
- `d65c8f0` call `NikudModel.folder()`
- `Models.swift` — the SentencePiece underline artifact is `U+2581`
- `GateAndTextTests.swift` — the Hebrew strings had been destroyed by an encoding round-trip (the file held mojibake), so the gate saw garbage
- `Nikud.swift` — look up `Model/Nikud` (the bundle keeps a `Model/` folder reference) — before this the diacritizer was never found and nikud was silently off
- `PipelineFlowTests.swift` — warm the diacritizer up front, wait for the first translation instead of a fixed 1.2 s
- `sim-test.yml` — keep 400 log lines, print the xcresult failure summary

## Screenshots & design review (2026-10-25)

Every sim run now publishes **`sim-screenshots`** (light pass + dark/accessibility-extra-large pass),
exported with `xcresulttool export attachments` and renamed by `Tools/export_shots.py`.
`SmokeUITests.testScreenshotTour` waits for READY and captures main / settings (3 scroll positions) / log.

CI plumbing fixed on the way: `simctl ui` needs a *booted* device (it failed with "Shutdown"),
and the system mic alert (owned by springboard) sat in front of every shot until the workflow
pre-granted the permission with `simctl privacy … grant microphone com.shedw.he2en`.

## Test program (2026-10-25, `ed988d0`)

Four layers, each answering a question the others cannot:

1. **Examples** (`GateAndTextTests`, `NikudTests`, `StreamingSTTTests`, `TranslationModelTests`) — pinned bugs.
2. **Invariants** (`Tests/InvariantTests.swift`) — property-based, seeded (SplitMix64, no dependency):
   `mergeOverlap` never loses/reorders tokens and is idempotent; `removePrefix` only drops a leading
   run and reaches a fixpoint; `sanitizeTranslation` is idempotent and leaves no control tokens;
   the gate is deterministic, never emits an empty/stub sentence, is monotone in evidence (pause /
   endpoint / full stop may not cancel an emit) and ignores sloppy whitespace. 2 000–4 000 cases each.
3. **Real models** (`Tests/ModelQualityTests.swift`) — the diacritizer adds nikud and survives junk
   (emoji, Latin, 60-word repeats) without crashing or returning empty; four golden sentences keep
   their meaning ("bread", "hebrew", "station", "hello"); warm latency budgets (nikud < 2 s,
   translate < 2.5 s) are printed as evidence.
4. **Platform audits** (`UITests/AccessibilityAuditTests.swift`) — Apple's `performAccessibilityAudit`
   as a hard gate for everything except the known status-contrast finding (tracked separately with
   `XCTExpectFailure(strict: false)`), plus hit-target (≥ 44 pt) and panel-alignment rules.

Known gap pinned, not hidden: `hasModelArtifacts` flags the SentencePiece underline (U+2581) while
`sanitizeTranslation` passes it through — see `testSentencePieceUnderlineIsNotSanitizedYet`.

**Result (`297e30f`): 38 unit + 6 UI tests, 0 failures, both passes.** Apple's audit independently
confirms the review: it flags `contrast` on `statusTitle` ("READY") and `hitRegion` on the two panel
texts (selectable text whose empty-state element is a single "…"). Evidence printed by the tests:
`GOLDEN [שלום, מה שלומך?] -> [Hello, how are you?]`, `[אני רוצה לקנות לחם מחר בבוקר.] ->
[I want to buy bread tomorrow morning.]`, `[אני לומד עברית כל יום עם חברים שלי.] ->
[I learn Hebrew every day with my friends.]`, `[תגיד לי איפה התחנה המרכזית.] ->
[Tell me where the main station is.]`; `LATENCY nikud 94 ms, translate 273 ms`.




## Research: Hebrew-with-nikud models on HF (2026-10-25)

Nothing open is smaller/better than what we have:
- ASR with nikud: `MayBog/whisper-hebrew-nikud-v1` (gated, 3.24 GB fp16), `cantillation/*-Nikud` (Torah domain, WER 37.5 %, whisper-small 967 MB fp32)
- ASR with IPA (not nikud): `notmax123/whisper-heb-ipa` 1.62 GB
- Diacritizers: `dicta-il/dictabert-large-char-menaked` 1.22 GB, `NadavShaked/D_Nikud` 894 MB — both bigger than phonikud (293.6 MB int8)
- Catalog: https://github.com/danielrosehill/Hebrew-AI-Models

## Pipeline contract
STT text → diacritize (phonikud, `Sources/Nikud.swift`) → **only pointed Hebrew is translated** → TTS.
