import Foundation
import SwiftUI

extension Pipeline {

    // MARK: - Recognition wiring

    func wireRecognizer() {
        recognizer.onPartial = { [weak self] text in
            Task { @MainActor in self?.handlePartial(text) }
        }
        recognizer.onFinal = { [weak self] text in
            Task { @MainActor in self?.handleFinal(text) }
        }
        recognizer.onError = { [weak self] message in
            Task { @MainActor in self?.lastError = message }
        }
    }

    func handlePartial(_ text: String) {
        let merged = TextUtil.mergeOverlap(accumulated, text)
        hebrewLive = merged
        tracePartial(merged)
        evaluate(merged, isFinal: false)
    }

    func handleFinal(_ text: String) {
        let stripped = Self.removePrefix(text, prefix: lastEmitted)
        accumulated = TextUtil.mergeOverlap(accumulated, stripped)
        hebrewLive = accumulated
        Self.trace("STT final: \(text)")
        evaluate(accumulated, isFinal: true)
    }

    func evaluate(_ text: String, isFinal: Bool) {
        let silence = recognizer.silenceDuration
        let age = pendingSince.map { Date().timeIntervalSince($0) } ?? 0
        let outcome = gate.evaluate(text, trailingSilence: silence, isSTTFinal: isFinal, pendingAge: age)
        lastGateReason = outcome.reason
        if outcome.emit {
            emit(text, forced: outcome.forced)
        } else if pendingSince == nil, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            pendingSince = Date()
        }
    }

    func emit(_ text: String, forced: Bool) {
        let sentence = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty else { return }
        lastEmitted = sentence
        accumulated = ""
        pendingSince = nil
        hebrewLive = ""
        log.append(LogEntry(date: Date(), hebrew: sentence, english: "", forced: forced))
        Self.trace("gate EMIT\(forced ? " (incomplete, forced)" : ""): \(sentence)")
        queue.append(sentence)
        processQueue()
    }

    static func removePrefix(_ text: String, prefix: String) -> String {
        guard !prefix.isEmpty else { return text }
        let p = TextUtil.tokenize(prefix)
        let t = TextUtil.tokenize(text)
        guard t.count >= p.count else { return text }
        if Array(t.prefix(p.count)) == p {
            return t.dropFirst(p.count).joined(separator: " ")
        }
        return text
    }

    // MARK: - Translation queue

    func processQueue() {
        guard !translating, !queue.isEmpty else { return }
        translating = true
        let sentence = queue.removeFirst()
        status = .translating
        Self.trace("translate IN: \(sentence)")
        Task { @MainActor in
            var translated = ""
            if let engine {
                do {
                    translated = try await engine.translate(sentence)
                    Self.trace("translate OUT: \(translated)")
                } catch {
                    self.lastError = error.localizedDescription
                    Self.trace("translate ERROR: \(error.localizedDescription)")
                }
            } else {
                self.lastError = "No offline translation engine available"
            }
            if !translated.isEmpty {
                if !self.englishText.isEmpty { self.englishText += "\n" }
                self.englishText += translated
                if let idx = self.log.lastIndex(where: { $0.hebrew == sentence && $0.english.isEmpty }) {
                    self.log[idx].english = translated
                }
                self.pendingSpeech = translated
            }
            self.translating = false
            if self.queue.isEmpty { self.status = self.running ? .listening : .idle }
            self.processQueue()
        }
    }

    // MARK: - Timer: restarts, silence-based emit, speak-on-pause

    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func tick() {
        guard running else { return }
        recognizer.restartIfNeeded()
        if !hebrewLive.isEmpty && recognizer.silenceDuration >= gate.mode.silenceToEmit {
            evaluate(hebrewLive, isFinal: false)
        }
        if let speech = pendingSpeech, !recognizer.isSpeechActive, !speaker.isSpeaking, queue.isEmpty {
            pendingSpeech = nil
            status = .speaking
            Self.trace("TTS speaks: \(speech)")
            speaker.speak(speech)
        }
        if !speaker.isSpeaking && status == .speaking { status = running ? .listening : .idle }
    }
}
