# TODO — status board

Updated with every push. `done` = merged to `main` **and** green in CI.

## Sense loss (words/sense the interpreter dropped)
- [x] `pendingSpeech` slot overwrote queued sentences — a sentence was shown but never spoken → `speechQueue: [String]`
- [x] `hasModelArtifacts` rejected a whole sentence on one SentencePiece U+2581 → the sanitizer strips it
- [x] Gate swallowed one-word answers (threshold + <2-token rule) → an endpoint with score ≥ 1 emits; penalties only while it is not an STT final
- [x] `Nikud.chunks()` split mid-word → splits on word boundaries
- [x] Dedupe memory persisted across utterances and silently dropped intentional repeats → keyed on the HE/EN pair, reset at the utterance boundary
- [x] Test bug: the speech-queue assertion compared English speech against the translator's Hebrew input
- [x] Tests: `SenseLossTests`, `InvariantTests` (property tests), `ModelQualityTests` (golden set)

## Send logs (native share → Mail / Messages / AirDrop / Files)
- [x] Full report: device + app, engine, gate, models, speech, nikud, conversation, trace tail
- [x] `ShareLink` in the Log sheet (`shareLogs`) and in Settings → Diagnostics (`shareLogsSettings`)
- [x] Row is always present and ≥ 44 pt (it was 36 pt → failed the hit-target rule; it could also disappear while the report was being written)
- [x] Old reports are pruned (Documents is user-visible and grew without bound)
- [x] Tests: `LogExportTests`, `ShareLogsUITests`, `SettingsUITests`

## Settings
- [x] Voice, rate and chunking mode persist (`Prefs` → `UserDefaults`) and are re-applied at launch
- [x] "Hear this voice", rate readout, "Reset settings", "Send logs", plain-language footers
- [x] Developer tools (voice samples) moved out of the user-facing list
- [x] Tests: `SettingsPersistenceTests`, `SettingsUITests`

## Bugs found in review — fixed
- [x] `[(stamp)]` printed literally in the trace session marker (double-escaped string)
- [x] `stop()` blanked Hebrew but left English on screen
- [x] Diacritizer loaded on the first sentence → READY lied; now warmed in `prepare()`
- [x] Unit-test host auto-started: microphone permission alert + 293 MB load during unit tests
- [x] TTS re-resolved the voice on every utterance (77 ms) → cached per selection

## UI / accessibility
- [x] Empty panels showed a bare "…" → short hint (icon + one line)
- [x] Panels asymmetric (Hebrew fixed 110 pt vs flexible English) → both flexible
- [x] No auto-scroll → `.defaultScrollAnchor(.bottom)` on both panels
- [x] LED fixed 46/26 pt → `@ScaledMetric`
- [x] Nothing moved during "STARTING…" → `ProgressView`; mic pulses while listening; `sensoryFeedback` on start/stop
- [x] Status green/orange ≈ 2:1 in light mode → scheme-aware colours (≥ 4.5:1)
- [x] Light-mode icon chips invisible → card fill + hairline separator
- [x] Mic denied was a dead end → "Open Settings" button; error text no longer truncated
- [x] Duplicate error surface (banner **and** next to the LED) → single banner
- [x] Log sheet gets `.presentationDetents`; dead `color(for:)` removed
- [ ] Log vs Settings dismiss styles still differ (Log = ✗ on the left, Settings = "Close" on the right) — cosmetic, deferred to avoid breaking the share-sheet test
- [ ] iOS 26 Liquid Glass (`.glassEffect`) — needs a visual check on a device/simulator, not applied blind

## Latency (applied only where the output cannot change)
- [x] Warm the diacritizer in `prepare()` — removes ~1.4 s from the user path
- [x] Cache the TTS voice — removes ~77 ms per utterance
- [ ] `diacritize()` still runs on the main actor (~94–214 ms per sentence) — a concurrency change in the hot path, deliberately deferred
- [ ] Cap the MT input at 20–25 words (40 words = 2.76 s) — **rejected**: splitting a sentence is exactly the sense loss this app exists to prevent
- [ ] Intra-op threads 4 → 2–3 — needs device A/B, no simulator evidence
- [ ] `maxChunkLength` 2046 → 256 — no measured problem left after the word-boundary fix
- [ ] Default `.balanced` → `.fast` — a quality trade-off for the user to make; the choice is now remembered instead

## Open
- [ ] Retire the pinned contrast expectation (`XCTExpectFailure`) after a light-mode visual check
