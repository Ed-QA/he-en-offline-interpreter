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
        // The recognizer re-sends the whole utterance on every partial, and the two streams
        // (item 1) repeat each other's tail. Item 2's overlap-removal tool drops the repeated
        // words first, so one valid text is left instead of the same words twice.
        let stripped = TextUtil.dropOverlap(previous: lastEmitted, next: text)
        accumulated = TextUtil.mergeOverlap(accumulated, stripped)
        hebrewLive = accumulated.isEmpty ? lastEmitted : accumulated
        tracePartial(accumulated)
        evaluate(accumulated, isFinal: false)
    }

    /// The recogniser detected an endpoint: the utterance is over, so this is the moment the
    /// gate is allowed to treat the text as final.
    func handleEndpoint(_ text: String) {
        let stripped = TextUtil.dropOverlap(previous: lastEmitted, next: text)
        accumulated = TextUtil.mergeOverlap(accumulated, stripped)
        hebrewLive = accumulated.isEmpty ? lastEmitted : accumulated
        Self.trace("STT endpoint: \(text)")
        evaluate(accumulated, isFinal: true)
        // Utterance boundary: forget what was emitted. The next utterance starts clean, so the
        // same words said again ("תודה רבה" twice) are new speech and must not be stripped as
        // if they were an echo of this one.
        lastEmitted = ""
        accumulated = ""
        pendingSince = nil
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
        if outcome.emit {
            // Anti-spam: never emit twice in the same breath, and never for a one-word stub
            // *mid-utterance*. At a real endpoint a bare "כן"/"תודה"/"מים" is a complete answer
            // and used to be swallowed here.
            if !isFinal, Date().timeIntervalSince(lastEmitAt) < 0.35 { return }
            if !isFinal, TextUtil.tokenize(text).count < 2 { return }
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
        let pointed = diacritize(sentence)
        if pointed != sentence {
            if let index = log.lastIndex(where: { $0.hebrew == sentence }) {
                log[index].hebrew = pointed
            }
        }
        // Item 4 (priority 1): nikud is applied straight after STT — before anything is translated.
        // Item 3: the pointed sentence is *appended* to the Hebrew transcript, so the panel fills
        // and scrolls like the English one instead of being blanked on every sentence.
        if !pointed.isEmpty, hebrewText != pointed {
            if !hebrewText.isEmpty { hebrewText += " " }
            hebrewText += pointed
        }
        hebrewLive = ""
        // Item 5: the translator was trained on unpointed Hebrew, so the points are removed for
        // translation only — the pointed form is what stays on screen and in the log.
        let forTranslation = TextUtil.stripNikud(pointed)
        Self.trace("translate IN: \(forTranslation)")
        let t0 = Date()
        Task { @MainActor in
            var translated = ""
            if let engine {
                do {
                    translated = TextUtil.sanitizeTranslation(try await engine.translate(forTranslation))
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
