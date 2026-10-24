# HE-EN Offline Interpreter (iPhone 14)

Fully offline, on-device Hebrew -> English live interpreter.
Final app: ZERO network. No APIs. Everything on the phone.

Pipeline: iPhone mic -> native iOS Hebrew STT (on-device) -> Hebrew
"complete by sense" gate -> English translation -> native iOS TTS to earbuds.

## Build (no Mac needed)
Built in the cloud by GitHub Actions (`macos-26` runner, unsigned IPA).

1. Create repo + push (one-time):
   ```
   cd C:\Users\SHEdw\.cline\data\workspaces\chat\offline-he-en-interpreter
   git init -b main
   git add -A
   git commit -m "v0.1 probe + pipeline"
   gh repo create he-en-offline-interpreter --public --source . --push
   ```
2. Watch the build: `gh run watch` (or Actions page). The workflow attaches
   `HEENInterpreter.ipa` to a Release.
3. Download the IPA:
   `gh release download --pattern "*.ipa" -D .`

## Install on iPhone (Sideloadly, free Apple ID)
1. PC needs web iTunes 64-bit + iCloud for Windows (web) + Sideloadly
   (installed by the assistant into C:\Users\SHEdw\Downloads\heen-tools).
2. USB-connect iPhone -> Trust This Computer.
3. Sideloadly -> drag IPA -> Apple ID email + app-specific password -> Start.
4. Enable auto-refresh (re-signs before 7-day expiry).

## v0.1 scope
- Capability probe (on-device STT Hebrew? Apple on-device translation he->en?)
- Live Hebrew STT + Hebrew completeness gate (Hebrew-specific rules)
- English TTS to earbuds, voice picker, 20-second samples of ALL English voices
- UI: small Hebrew field, big English field, full log + native share
- "ENG->HEB" button reserved (disabled until its phase)
