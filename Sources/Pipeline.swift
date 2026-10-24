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

    /// Used by the SwiftUI anchor view (iOS 18+).
    @available(iOS 18.0, *)
    var translationConfiguration: TranslationSession.Configuration?

    // MARK: - Setup

    func prepare() async {
        sttStatus = "he-IL available: \(recognizer.isAvailable), on-device: \(recognizer.supportsOnDevice)"
        if #available(iOS 18.0, *) {
            let report = await AppleTranslationAvailability.check()
            engineStatus = "Apple on-device translation — \(report.statusText)"
            if report.canUseInstalledPack {
                engine = AppleTranslationEngine()
                engineReady = true
                translationConfiguration = AppleTranslationAvailability.configuration()
            } else {
                engine = nil
                engineReady = false
            }
        } else {
            engineStatus = "iOS < 18: Apple translation API unavailable"
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
