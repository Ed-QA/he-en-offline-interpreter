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
        // The recognizer re-sends the whole utterance on every partial. Once a sentence
        // has been emitted, its words must not be counted again — otherwise the same
        // sentence is re-translated and re-spoken a dozen times.
        let stripped = Self.removePrefix(text, prefix: lastEmitted)
        accumulated = TextUtil.mergeOverlap(accumulated, stripped)
        hebrewLive = accumulated.isEmpty ? lastEmitted : accumulated
        tracePartial(accumulated)
        evaluate(accumulated, isFinal: false)
    }

    func handleFinal(_ text: String) {
        let stripped = Self.removePrefix(text, prefix: lastEmitted)
        accumulated = TextUtil.mergeOverlap(accumulated, stripped)
        hebrewLive = accumulated.isEmpty ? lastEmitted : accumulated
        Self.trace("STT final: \(text)")
        evaluate(accumulated, isFinal: true)
    }

    func evaluate(_ text: String, isFinal: Bool) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let silence = recognizer.silenceDuration
        let age = pendingSince.map { Date().timeIntervalSince($0) } ?? 0
        let outcome = gate.evaluate(text, trailingSilence: silence, isSTTFinal: isFinal, pendingAge: age)
        lastGateReason = outcome.reason
        if outcome.emit {
            // Anti-spam: never emit twice in the same breath, and never for a one-word stub.
            if !isFinal, Date().timeIntervalSince(lastEmitAt) < 0.35 { return }
            if TextUtil.tokenize(text).count < 2 { return }
            emit(text, forced: outcome.forced, isFinal: isFinal)
        } else if pendingSince == nil {
            pendingSince = Date()
        }
    }

    func emit(_ text: String, forced: Bool, isFinal: Bool = false) {
        let sentence = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty else { return }
        // Item 5 (critical): never queue a word twice. Everything already queued or spoken for
        // this utterance is stripped, so a growing forced emit only ever speaks the new tail.
        let fresh = Self.removePrefix(sentence, prefix: spokenHebrew)
        lastEmitted = sentence
        lastEmitAt = Date()
        accumulated = ""
        pendingSince = nil
        // Keep the sentence on screen — blanking the Hebrew panel made it look like
        // nothing had been recognised at all.
        hebrewLive = sentence
        log.append(LogEntry(date: Date(), hebrew: sentence, english: "", forced: forced))
        if fresh.isEmpty {
            Self.trace("gate EMIT\(forced ? " (incomplete, forced)" : ""): \(sentence) — already spoken, skipped")
            return
        }
        spokenHebrew = sentence
        if isFinal { spokenHebrew = "" }   // utterance boundary: the next sentence starts clean
        Self.trace("gate EMIT\(forced ? " (incomplete, forced)" : ""): \(sentence) → new words: \(fresh)")
        queue.append(fresh)
        processQueue()
    }

    static func removePrefix(_ text: String, prefix: String) -> String {
        TextUtil.removePrefix(text, prefix: prefix)
    }

    // MARK: - Translation queue

    func processQueue() {
        guard !translating, !queue.isEmpty else { return }
        translating = true
        let sentence = queue.removeFirst()
        status = .translating
        Self.trace("translate IN: \(sentence)")
        let t0 = Date()
        Task { @MainActor in
            var translated = ""
            if let engine {
                do {
                    translated = TextUtil.sanitizeTranslation(try await engine.translate(sentence))
                    Self.trace("translate OUT (\(Int(Date().timeIntervalSince(t0) * 1000)) ms): \(translated)")
                } catch {
                    self.lastError = error.localizedDescription
                    Self.trace("translate ERROR: \(error.localizedDescription)")
                }
            } else {
                self.lastError = "No offline translation engine available"
            }
            // Item 6: control tokens (`<pad>`, `<unk>`, …) must never reach the screen or the TTS.
            if TextUtil.hasModelArtifacts(translated) {
                Self.trace("translate DROP (model artifacts): \(translated)")
                translated = ""
            }
            if !translated.isEmpty {
                if !self.englishText.isEmpty { self.englishText += "\n" }
                self.englishText += translated
                if let idx = self.log.lastIndex(where: { $0.hebrew == sentence && $0.english.isEmpty }) {
                    self.log[idx].english = translated
                }
                // Item 5: the same English sentence is never queued for TTS twice.
                if translated != self.lastSpokenEnglish {
                    self.lastSpokenEnglish = translated
                    self.pendingSpeech = translated
                    self.pendingSpeechAt = Date()
                } else {
                    Self.trace("speak SKIP (identical to previous sentence)")
                }
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
        if !accumulated.isEmpty && recognizer.silenceDuration >= gate.mode.silenceToEmit {
            evaluate(accumulated, isFinal: false)
        }
        if let speech = pendingSpeech, !recognizer.isSpeechActive, !speaker.isSpeaking, queue.isEmpty {
            pendingSpeech = nil
            status = .speaking
            // Mute the mic while talking: the speaker's own English must never be
            // transcribed and re-translated (feedback loop), and the TTS must not be cut off.
            recognizer.muted = true
            speaker.onFinish = { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.recognizer.muted = false
                    self.accumulated = ""
                    self.pendingSince = nil
                    self.status = self.running ? .listening : .idle
                }
            }
            lastSpeakRequestAt = Date()
            let latency = pendingSpeechAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
            pendingSpeechAt = nil
            Self.trace("TTS speaks (emit→speak \(latency) ms): \(speech)")
            speaker.speak(speech)
        }
        // Safety net: if the synthesizer never reported start/finish, un-mute anyway — but
        // only well after the request. Loading a voice can take a moment, and un-muting too
        // early would feed our own English straight back into the recognizer.
        let speakAge = Date().timeIntervalSince(lastSpeakRequestAt)
        if recognizer.muted && !speaker.isSpeaking && pendingSpeech == nil && status != .speaking && speakAge > 2.0 {
            recognizer.muted = false
        }
        if !speaker.isSpeaking && status == .speaking && speakAge > 0.5 { status = running ? .listening : .idle }
    }
}
