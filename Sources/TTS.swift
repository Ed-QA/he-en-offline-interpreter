import Foundation
import AVFoundation

/// Native iOS English TTS with voice selection.
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    var voiceIdentifier: String?
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
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = Self.voice(for: voiceIdentifier) ?? Self.defaultEnglishVoice()
        utterance.rate = rate
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
