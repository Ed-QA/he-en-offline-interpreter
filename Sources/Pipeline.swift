import Foundation
import SwiftUI
import Translation
import AVFoundation

/// Live pipeline: mic → Hebrew STT → sense-completeness gate → translation → TTS.
@MainActor
final class Pipeline: ObservableObject {

    enum Status: String {
        case idle = "Idle"
        case listening = "Listening"
        case translating = "Translating"
        case speaking = "Speaking"
        case error = "Error"
    }

    /// Model readiness shown as a green/red signal in the header.
    enum ModelsState {
        case loading
        case active(String)
        case failed(String)

        var isActive: Bool {
            if case .active = self { return true }
            return false
        }
    }

    @Published var modelsState: ModelsState = .loading

    @Published var status: Status = .idle
    @Published var running = false
    @Published var hebrewLive = ""
    /// The committed Hebrew transcript — the *pointed* sentences, appended as they are produced
    /// (items 3 and 4): the panel fills and scrolls instead of being blanked on every emit.
    @Published var hebrewText = ""
    @Published var englishText = ""
    @Published var log: [LogEntry] = []
    @Published var gateMode: GateMode = Prefs.gateMode {
        didSet { gate.mode = gateMode; Prefs.gateMode = gateMode }
    }
    /// Item 10: which physical input/output to use, and whether each is currently available.
    /// Availability is re-checked continuously so a choice that is no longer possible (earplugs
    /// unplugged) greys out instead of silently doing nothing.
    @Published var micChoice: AudioEndpoint = Prefs.micChoice {
        didSet { Prefs.micChoice = micChoice; applyAudioRoute() }
    }
    @Published var outputChoice: AudioEndpoint = Prefs.outputChoice {
        didSet { Prefs.outputChoice = outputChoice; applyAudioRoute() }
    }
    @Published var micAvailable = true
    @Published var outputAvailable = true
    @Published var voiceIdentifier: String? = Prefs.voiceIdentifier ?? Speaker.defaultEnglishVoice()?.identifier {
        didSet { speaker.voiceIdentifier = voiceIdentifier; Prefs.voiceIdentifier = voiceIdentifier }
    }
    @Published var rate: Float = Prefs.rate {
        didSet { speaker.rate = rate; Prefs.rate = rate }
    }
    @Published var sttStatus = "checking…"
    @Published var engineStatus = "checking…"
    @Published var engineReady = false
    @Published var lastError: String?
    @Published var lastGateReason = ""
    @Published var voiceSampleProgress: String?
    @Published var voiceSampleReport: VoiceSampler.Report?
    /// True while the sampler is rendering, so the UI can offer a way out.
    @Published var voiceSamplerRunning = false

    /// Last partial text written to the on-device trace (de-duplication).
    static var lastTracedPartial = ""

    /// Streaming Hebrew ASR (sherpa-onnx zipformer2-66m, offline). Injectable so the simulator
    /// tests can drive the entire pipeline with a scripted recogniser instead of a microphone.
    var stt: any StreamingSTT
    let speaker = Speaker()
    /// Shared with the voice-sampler render loop so "Cancel" can actually stop it.
    let voiceSampleCancelled = VoiceSampler.CancelFlag()
    var gate = HebrewCompletenessGate()
    var accumulated = ""
    var lastEmitted = ""
    /// When the previous sentence was emitted — used as an anti-spam cooldown so the
    /// same growing sentence is not re-translated and re-spoken on every partial.
    var lastEmitAt = Date.distantPast
    /// When the last TTS request was made — the mic un-mute safety net waits on this so a
    /// slow voice load can never un-mute us into our own English.
    var lastSpeakRequestAt = Date.distantPast
    var pendingSince: Date?
    var timer: Timer?
    var engine: TranslationEngine?
    /// On-device diacritizer (phonikud int8, `Sources/Nikud.swift`). Loaded lazily on the
    /// first sentence; if it is unavailable the pipeline keeps translating the unpointed text
    /// instead of failing.
    var nikud: NikudRestorer?
    var nikudUnavailable = false
    var queue: [String] = []
    var translating = false
    var speechQueue: [String] = []
    /// Hebrew words already queued or spoken for the current utterance — the anti-repeat guard
    /// (item 5: TTS must never re-speak words it has already said).
    var spokenHebrew = ""
    /// Last English sentence queued for the TTS and the pointed Hebrew it came from. Only an
    /// identical *pair* is skipped: two different sentences that happen to translate the same,
    /// and the same words said again in a new utterance, must both be spoken.
    var lastSpokenEnglish = ""
    var lastSpokenHebrew = ""
    /// When the head of the speech queue was queued - used to log emit→speak latency.
    var pendingSpeechAt: Date?

    /// Used by the SwiftUI anchor view (iOS 18+). Stored type-erased because Swift
    /// forbids `@available` on stored properties; the typed accessor below is gated.
    private var rawTranslationConfiguration: Any?

    @available(iOS 18.0, *)
    var translationConfiguration: TranslationSession.Configuration? {
        get { rawTranslationConfiguration as? TranslationSession.Configuration }
        set { rawTranslationConfiguration = newValue }
    }

    // MARK: - Setup

    init(stt: (any StreamingSTT)? = nil) {
        self.stt = stt ?? SherpaStreamingSTT()
        // `didSet` does not run during initialisation, so the stored preferences have to be
        // pushed into the speaker and the gate explicitly. Without this a remembered voice or
        // rate only took effect after the user touched the picker again.
        applySettings()
    }

    /// True when this process is a test host: XCTest injects this environment variable, and in
    /// that case the app must not grab the microphone, raise the permission alert or spend a
    /// minute loading models.
    nonisolated static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// True when the app was launched by a UI test (`-HEENUITest`). The tests do not measure
    /// model warm-up, and warming the diacritizer on the main actor froze the UI right after
    /// launch — enough to push UI tests past the 120 s per-test allowance in CI.
    nonisolated static var isUITest: Bool {
        ProcessInfo.processInfo.arguments.contains("-HEENUITest")
    }

    /// Pushes the current settings into the objects that consume them.
    func applySettings() {
        gate.mode = gateMode
        speaker.voiceIdentifier = voiceIdentifier
        speaker.rate = rate
        refreshAudioRoutes()
        applyAudioRoute()
    }

    /// Item 10: re-reads what the system currently offers, so an impossible choice can grey out.
    func refreshAudioRoutes() {
        micAvailable = AudioRoute.isAvailable(micChoice, input: true)
        outputAvailable = AudioRoute.isAvailable(outputChoice, input: false)
    }

    /// Item 10: hands the chosen input/output to the audio session and to the running microphone.
    func applyAudioRoute() {
        AudioRoute.applyInput(micChoice)
        AudioRoute.applyOutput(outputChoice)
        stt.applyInputChoice(micChoice, output: outputChoice)
    }

    /// Back to the shipped defaults, and forget them so the next launch is a fresh install.
    func resetSettings() {
        gateMode = .balanced
        voiceIdentifier = Speaker.defaultEnglishVoice()?.identifier
        rate = Prefs.defaultRate
        Prefs.reset()
    }

    /// Settings helper: hear the chosen voice without waiting for a translation. The microphone
    /// is muted for the duration so the interpreter cannot transcribe itself.
    func speakSample() {
        let wasMuted = stt.muted
        stt.muted = true
        speaker.onFinish = { [weak self] in
            Task { @MainActor in self?.stt.muted = wasMuted }
        }
        speaker.speak("This is how the interpreter will sound.")
    }

    func prepare() async {
        Self.resetTrace()
        Self.trace("=== launch build \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") on \(UIDevice.current.name), iOS \(UIDevice.current.systemVersion)")
        modelsState = .loading
        sttStatus = stt.statusText
        var appleStatus: String?
        if #available(iOS 18.0, *) {
            let report = await AppleTranslationAvailability.check()
            appleStatus = report.statusText
            if report.canUseInstalledPack {
                engine = AppleTranslationEngine()
                engineReady = true
                translationConfiguration = AppleTranslationAvailability.configuration()
            }
        }
        // The bundled int8 ONNX model is the fallback — and on iOS < 18 the only path.
        if engine == nil {
            let missing = ONNXTranslationEngine.missingFiles()
            if missing.isEmpty {
                if let bundled = await ONNXTranslationEngine.shared() {
                    engine = bundled
                    engineReady = true
                    engineStatus = "Bundled offline model (OPUS-MT he→en, int8)"
                        + (appleStatus.map { " — Apple: \($0)" } ?? "")
                    modelsState = await Self.selfTest(bundled)
                } else {
                    let why = ONNXTranslationEngine.lastLoadError() ?? "unknown"
                    engineStatus = "Bundled model failed to load: \(why)"
                    modelsState = .failed("load: \(why)")
                }
            } else {
                engineStatus = "No engine — Apple: \(appleStatus ?? "unavailable on iOS < 18")"
                    + "; bundled model missing: \(missing.joined(separator: ", "))"
                modelsState = .failed("missing \(missing.joined(separator: ", "))")
            }
        } else {
            engineStatus = "Apple on-device translation — \(appleStatus ?? "ready")"
            modelsState = .active("Apple on-device translation")
        }
        // Warm the translation graph so the first real sentence does not pay for session
        // allocation. Logged with a millisecond figure so latency is visible in live.log.
        if let engine {
            let t0 = Date()
            let warm = (try? await engine.translate("שלום, מה שלומך?")) ?? ""
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            Self.trace("warmup translate \(ms) ms → \(TextUtil.sanitizeTranslation(warm))")
        }
        // Warm the Hebrew diacritizer in the same pass as the translator: it used to load lazily
        // on the first sentence, so the light said READY while the first sentence still paid
        // ~1.4 s for the 293 MB session. Skipped in a test host (tests warm it themselves) and in
        // a UI-test launch, where it would only freeze the UI the tests are driving.
        if !Self.isRunningTests && !Self.isUITest {
            let tNikud = Date()
            _ = diacritize("שלום, מה שלומך?")
            Self.trace("warmup nikud \(Int(Date().timeIntervalSince(tNikud) * 1000)) ms")
        }
        // v0.3: launch == live. The interpreter starts listening by itself so the
        // device never needs a button tap to begin working.
        // UI-test hook: the simulator has no usable microphone and a permission alert would
        // block automated screenshots, so `-HEENUITest` keeps the app prepared but idle.
        // The unit-test host runs the same binary without that flag, so it is detected too: a
        // test run must never start the microphone or raise the system permission alert.
        if Self.isUITest || Self.isRunningTests {
            Self.trace("auto-start skipped (\(Self.isRunningTests ? "test host" : "-HEENUITest"))")
            return
        }
        Self.trace("auto-start after prepare")
        start()
    }

    /// Runs one real Hebrew→English translation on the loaded model so the header can
    /// show a green/red "models active" signal instead of a hopeful claim.
    private static func selfTest(_ engine: ONNXTranslationEngine) async -> ModelsState {
        do {
            let out = try await engine.translate("אני לומד עברית כל יום עם חברים שלי.")
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            Self.trace("self-test translation: \(trimmed)")
            return trimmed.isEmpty ? .failed("self-test returned empty text") : .active(trimmed)
        } catch {
            return .failed("self-test: \(error)")
        }
    }

    @available(iOS 18.0, *)
    func attachTranslationSession(_ session: TranslationSession) {
        if let apple = engine as? AppleTranslationEngine {
            apple.session = session
            engineReady = true
        }
    }

    // MARK: - Start / stop

    func start() {
        guard !running else { return }
        AVAudioApplication.requestRecordPermission { [weak self] micOK in
            guard let self else { return }
            guard micOK else {
                self.lastError = "Microphone permission denied"
                self.status = .error
                return
            }
            Task { @MainActor in
                do {
                    try self.stt.start()
                    self.wireSTT()
                    self.running = true
                    self.status = .listening
                    UIApplication.shared.isIdleTimerDisabled = true  // keep the screen on while live
                    self.startTimer()
                    Self.trace("START listening — \(self.stt.statusText)")
                } catch {
                    self.lastError = error.localizedDescription
                    self.status = .error
                    Self.trace("START failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        stt.stop()
        stt.muted = false
        speaker.stop()
        running = false
        UIApplication.shared.isIdleTimerDisabled = false
        status = .idle
        hebrewLive = ""
        hebrewText = ""
        englishText = ""   // both panels blank together, not just the Hebrew one
        accumulated = ""
        pendingSince = nil
        spokenHebrew = ""
        speechQueue = []
        pendingSpeechAt = nil
        // A restart must not remember the previous session's sentence, or the first words of
        // the next one would be stripped as an echo.
        lastEmitted = ""
        lastSpokenEnglish = ""
        lastSpokenHebrew = ""
        Self.trace("STOP listening")
    }

    func repeatLast() {
        guard let last = log.last(where: { !$0.english.isEmpty })?.english else { return }
        speaker.speak(last)
    }
}
