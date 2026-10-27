import Foundation
import SwiftUI

extension Pipeline {

    // MARK: - Recognition wiring

    func wireSTT() {
        stt.onPartial = { [weak self] text in
            Task { @MainActor in self?.handlePartial(text) }
        }
        stt.onEndpoint = { [weak self] text in
            Task { @MainActor in self?.handleEndpoint(text) }
        }
        stt.onError = { [weak self] message in
            Task { @MainActor in self?.lastError = message }
        }
    }

    func handlePartial(_ text: String) {
        // The recognizer re-sends the whole utterance on every partial, so the text *is* the
        // sentence so far. It used to be diffed against the previous partial and merged through an
        // overlap-removal tool — that mangled the Hebrew into nonsense chunks.
        accumulated = text
        hebrewLive = text
        tracePartial(text)
        evaluate(text, isFinal: false)
    }

    /// The recogniser detected an endpoint: the utterance is over, so this is the moment the
    /// gate is allowed to treat the text as final.
    func handleEndpoint(_ text: String) {
        // Same rule as a partial: what the recognizer returns is the whole utterance, not a delta.
        accumulated = text
        hebrewLive = text
        Self.trace("STT endpoint: \(text)")
        evaluate(text, isFinal: true)
        // Utterance boundary: forget what was emitted. The next utterance starts clean, so the
        // same words said again ("תודה רבה" twice) are new speech and must not be stripped as
        // if they were an echo of this one.
        lastEmitted = ""
        accumulated = ""
        pendingSince = nil
        // The next utterance may legitimately say the same words again, so the duplicate guard
        // belongs to this utterance only.
        lastQueuedSentence = ""
        // The anti-repeat memory belongs to this utterance only.
        lastSpokenEnglish = ""
        lastSpokenHebrew = ""
    }

    func evaluate(_ text: String, isFinal: Bool) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let silence = stt.silenceDuration
        let age = pendingSince.map { Date().timeIntervalSince($0) } ?? 0
        let outcome = gate.evaluate(text, trailingSilence: silence, isSTTFinal: isFinal, pendingAge: age)
        lastGateReason = outcome.reason
        // Only a finished utterance is translated and spoken. Emitting half-finished text was what
        // produced the nonsense chunks and the audio that restarted from the beginning.
        if outcome.emit, isFinal {
            emit(text, forced: false, isFinal: true)
        } else if pendingSince == nil {
            pendingSince = Date()
        }
    }

    func emit(_ text: String, forced: Bool, isFinal: Bool = false) {
        let sentence = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty else { return }
        // One sentence is queued once per utterance: a forced emit followed by the real endpoint
        // used to push the same text through translation, TTS and the Hebrew panel twice.
        if sentence == lastQueuedSentence { return }
        lastQueuedSentence = sentence
        // The whole sentence goes to the translator exactly once, at the end of the utterance.
        // (It used to be trimmed against what was already spoken and queued as a tail fragment —
        // that is what made the translation read like nonsense.)
        lastEmitted = sentence
        lastEmitAt = Date()
        accumulated = ""
        pendingSince = nil
        // Keep the sentence on screen — blanking the Hebrew panel made it look like nothing had
        // been recognised at all.
        hebrewLive = sentence
        log.append(LogEntry(date: Date(), hebrew: sentence, english: "", forced: false))
        spokenHebrew = ""
        Self.trace("gate EMIT: \(sentence)")
        queue.append(sentence)
        processQueue()
    }

    static func removePrefix(_ text: String, prefix: String) -> String {
        TextUtil.removePrefix(text, prefix: prefix)
    }

    // MARK: - Translation queue

    /// Runs the on-device diacritizer (phonikud, int8 ONNX), loading it on first use.
    /// Falls back to the unpointed sentence when the model is missing or fails — live
    /// translation must keep working either way.
    func diacritize(_ text: String) -> String {
        if nikud == nil, !nikudUnavailable {
            do {
                nikud = try NikudRestorer.load()
                Self.trace("nikud model ready (\(NikudModel.modelFile))")
            } catch {
                nikudUnavailable = true
                Self.trace("nikud model unavailable: \(error.localizedDescription)")
            }
        }
        return nikud?.addDiacritics(text) ?? text
    }

    func processQueue() {
        guard !translating, !queue.isEmpty else { return }
        translating = true
        let sentence = queue.removeFirst()
        status = .translating
        // Contract: the translator only ever sees *pointed* Hebrew. A bare Hebrew word has
        // several readings, so the recognised sentence is diacritized first (nikud) and that
        // pointed text — not the raw transcript — is what gets translated and shown.
        // The post-hoc diacritizer (phonikud, a separate model that guessed the points *after*
        // recognition) is DELETED — it was crap: it added nikud late, and the points it invented
        // were not what the speaker said. Nikud must come from the recognizer itself, so the
        // recognised sentence goes on unchanged until that recognizer is in place.
        let pointed = sentence
        if pointed != sentence {
            if let index = log.lastIndex(where: { $0.hebrew == sentence }) {
                log[index].hebrew = pointed
            }
        }
        // Item 4 (priority 1): nikud is applied straight after STT — before anything is translated.
        // Item 3: the pointed sentence is *appended* to the Hebrew transcript, so the panel fills
        // and scrolls like the English one instead of being blanked on every sentence.
        if !pointed.isEmpty, !hebrewText.hasSuffix(pointed) {
            if !hebrewText.isEmpty { hebrewText += " " }
            hebrewText += pointed
        }
        hebrewLive = ""
        // Item 5: the translator is handed the *pointed* sentence — the nikud goes in with the
        // text. How each engine uses it is the engine's own policy: the bundled model keeps the
        // points its vocabulary can carry (NikudAwareInput), Apple's normalises because its
        // on-device model has no pointed vocabulary at all.
        Self.trace("translate IN: \(pointed)")
        let t0 = Date()
        Task { @MainActor in
            var translated = ""
            if let engine {
                do {
                    translated = TextUtil.sanitizeTranslation(try await engine.translate(pointed))
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
                if let idx = self.log.lastIndex(where: { $0.hebrew == pointed && $0.english.isEmpty }) {
                    self.log[idx].english = translated
                }
                // Item 5: the same sentence is never queued for TTS twice - but the check is on the
                // Hebrew/English *pair*, so a genuinely repeated answer is still spoken.
                if translated == self.lastSpokenEnglish && pointed == self.lastSpokenHebrew {
                    Self.trace("speak SKIP (identical sentence already spoken)")
                } else {
                    self.lastSpokenEnglish = translated
                    self.lastSpokenHebrew = pointed
                    if self.speechQueue.isEmpty { self.pendingSpeechAt = Date() }
                    self.speechQueue.append(translated)
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
        stt.restartIfNeeded(maxSeconds: 50)
        if !accumulated.isEmpty && stt.silenceDuration >= gate.mode.silenceToEmit {
            evaluate(accumulated, isFinal: false)
        }
        // Item 8: speak the moment a translation is ready. The old condition also waited for the
        // speaker to fall silent *and* for the translation queue to drain, which added seconds
        // between "translated" and "heard". The mic is muted in this same tick, so none of the
        // English can be transcribed back.
        if let speech = speechQueue.first, !speaker.isSpeaking {
            speechQueue.removeFirst()
            status = .speaking
            // Mute the mic while talking: the speaker's own English must never be
            // transcribed and re-translated (feedback loop), and the TTS must not be cut off.
            stt.muted = true
            speaker.onFinish = { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.stt.muted = false
                    self.accumulated = ""
                    self.pendingSince = nil
                    self.status = self.running ? .listening : .idle
                }
            }
            lastSpeakRequestAt = Date()
            let latency = pendingSpeechAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
            pendingSpeechAt = speechQueue.isEmpty ? nil : Date()
            Self.trace("TTS speaks (emit→speak \(latency) ms): \(speech)")
            speaker.speak(speech)
        }
        // Safety net: if the synthesizer never reported start/finish, un-mute anyway — but
        // only well after the request. Loading a voice can take a moment, and un-muting too
        // early would feed our own English straight back into the recognizer.
        let speakAge = Date().timeIntervalSince(lastSpeakRequestAt)
        if stt.muted && !speaker.isSpeaking && speechQueue.isEmpty && status != .speaking && speakAge > 2.0 {
            stt.muted = false
        }
        if !speaker.isSpeaking && status == .speaking && speakAge > 0.5 { status = running ? .listening : .idle }
    }
}
