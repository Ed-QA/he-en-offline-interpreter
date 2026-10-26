import Foundation
import AVFoundation

/// Native iOS English TTS with voice selection.
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    /// Resolving a voice scans the installed voice list (77 ms per utterance on the simulator,
    /// more on device), so it is resolved once per selection instead of once per sentence.
    private var cachedVoice: AVSpeechSynthesisVoice?
    var voiceIdentifier: String? { didSet { if voiceIdentifier != oldValue { cachedVoice = nil } } }
    var rate: Float = 0.5
    private(set) var isSpeaking = false
    var onFinish: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Re-assert a speaker-friendly session right before talking. The recognizer
        // keeps .playAndRecord alive, and without this the synthesizer can end up
        // routed to the receiver (earpiece) or heavily ducked — i.e. inaudible.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default,
                                 options: [.defaultToSpeaker, .allowBluetoothA2DP, .duckOthers])
        try? session.overrideOutputAudioPort(.speaker)
        try? session.setActive(true)
        if cachedVoice == nil { cachedVoice = Self.voice(for: voiceIdentifier) ?? Self.defaultEnglishVoice() }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = cachedVoice
        utterance.rate = rate
        utterance.volume = 1.0
        utterance.postUtteranceDelay = 0.05
        synth.speak(utterance)
    }

    func stop() { synth.stopSpeaking(at: .immediate) }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) { isSpeaking = true }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { isSpeaking = false; onFinish?() }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { isSpeaking = false; onFinish?() }

    // MARK: - Voice catalog

    static func englishVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
    }

    static func voice(for identifier: String?) -> AVSpeechSynthesisVoice? {
        guard let identifier else { return nil }
        return AVSpeechSynthesisVoice.speechVoices().first { $0.identifier == identifier }
    }

    static func defaultEnglishVoice() -> AVSpeechSynthesisVoice? {
        let voices = englishVoices()
        let us = voices.filter { $0.language == "en-US" }
        return us.first { $0.quality == .premium }
            ?? us.first { $0.quality == .enhanced }
            ?? us.first
            ?? voices.first
    }

    static func qualityLabel(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium: return "premium"
        case .enhanced: return "enhanced"
        default: return "default"
        }
    }
}
