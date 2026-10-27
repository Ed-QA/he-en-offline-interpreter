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
    /// The language this speaker talks in. Switching language drops the cached voice, so the new
    /// language's voice is resolved on the next sentence and the previous one is not held on to.
    var language: TargetLanguage = .en { didSet { if language != oldValue { cachedVoice = nil } } }
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
        if cachedVoice == nil { cachedVoice = Self.voice(for: voiceIdentifier) ?? Self.defaultVoice(for: language) }
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

    /// Installed voices for one language, in a stable order. A Ukrainian voice only exists if the
    /// device has one installed; when it does not, iOS falls back by itself.
    static func voices(for language: TargetLanguage) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language.code) }
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
    }

    /// The best installed voice for the language: premium, then enhanced, then whatever exists.
    static func defaultVoice(for language: TargetLanguage) -> AVSpeechSynthesisVoice? {
        let voices = voices(for: language)
        let primary = voices.filter { $0.language.hasPrefix("\(language.code)-") }
        return primary.first { $0.quality == .premium }
            ?? primary.first { $0.quality == .enhanced }
            ?? primary.first
            ?? voices.first
    }

    /// English shortcuts for the callers that only deal with English.
    static func englishVoices() -> [AVSpeechSynthesisVoice] { voices(for: .en) }

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
