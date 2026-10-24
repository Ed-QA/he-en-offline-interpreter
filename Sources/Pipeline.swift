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
    }

    @Published var modelsState: ModelsState = .loading

    @Published var status: Status = .idle
    @Published var running = false
    @Published var hebrewLive = ""
    @Published var englishText = ""
    @Published var log: [LogEntry] = []
    @Published var gateMode: GateMode = .balanced { didSet { gate.mode = gateMode } }
    @Published var voiceIdentifier: String? = Speaker.defaultEnglishVoice()?.identifier {
        didSet { speaker.voiceIdentifier = voiceIdentifier }
    }
    @Published var rate: Float = 0.5 { didSet { speaker.rate = rate } }
    @Published var sttStatus = "checking…"
    @Published var engineStatus = "checking…"
    @Published var engineReady = false
    @Published var lastError: String?
    @Published var lastGateReason = ""
    @Published var voiceSampleProgress: String?
    @Published var voiceSampleReport: VoiceSampler.Report?

    let recognizer = HebrewRecognizer()
    let speaker = Speaker()
    var gate = HebrewCompletenessGate()
    var accumulated = ""
    var lastEmitted = ""
    var pendingSince: Date?
    var timer: Timer?
    var engine: TranslationEngine?
    var queue: [String] = []
    var translating = false
    var pendingSpeech: String?

    /// Used by the SwiftUI anchor view (iOS 18+). Stored type-erased because Swift
    /// forbids `@available` on stored properties; the typed accessor below is gated.
    private var rawTranslationConfiguration: Any?

    @available(iOS 18.0, *)
    var translationConfiguration: TranslationSession.Configuration? {
        get { rawTranslationConfiguration as? TranslationSession.Configuration }
        set { rawTranslationConfiguration = newValue }
    }

    // MARK: - Setup

    func prepare() async {
        modelsState = .loading
        sttStatus = "he-IL available: \(recognizer.isAvailable), on-device: \(recognizer.supportsOnDevice)"
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
    }

    /// Runs one real Hebrew→English translation on the loaded model so the header can
    /// show a green/red "models active" signal instead of a hopeful claim.
    private static func selfTest(_ engine: ONNXTranslationEngine) async -> ModelsState {
        do {
            let out = try await engine.translate("אני לומד עברית כל יום עם חברים שלי.")
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
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
        HebrewRecognizer.requestPermission { [weak self] speechOK in
            guard let self else { return }
            guard speechOK else {
                self.lastError = "Speech recognition permission denied"
                self.status = .error
                return
            }
            AVAudioApplication.requestRecordPermission { micOK in
                guard micOK else {
                    self.lastError = "Microphone permission denied"
                    self.status = .error
                    return
                }
                Task { @MainActor in
                    do {
                        try self.recognizer.start()
                        self.wireRecognizer()
                        self.running = true
                        self.status = .listening
                        self.startTimer()
                    } catch {
                        self.lastError = error.localizedDescription
                        self.status = .error
                    }
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        recognizer.stop()
        speaker.stop()
        running = false
        status = .idle
        hebrewLive = ""
    }

    func repeatLast() {
        guard let last = log.last(where: { !$0.english.isEmpty })?.english else { return }
        speaker.speak(last)
    }
}
