import Foundation

#if canImport(SherpaOnnxShared)
import SherpaOnnxShared
#elseif canImport(SherpaOnnx)
import SherpaOnnx
#endif

/// Everything the pipeline needs from a speech recogniser.
/// Keeping it a protocol is what makes the whole flow testable in the simulator with a
/// scripted recogniser — no phone, no microphone, fully deterministic.
protocol StreamingSTT: AnyObject {
    var onPartial: ((String) -> Void)? { get set }
    /// A complete utterance was recognised (endpoint detected).
    var onEndpoint: ((String) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    /// While true, incoming audio is dropped: our own English TTS must never be transcribed.
    var muted: Bool { get set }
    var silenceDuration: TimeInterval { get }
    var isSpeechActive: Bool { get }
    var statusText: String { get }
    func start() throws
    func stop()
    func restartIfNeeded(maxSeconds: TimeInterval)
}

/// Offline streaming Hebrew ASR: sherpa-onnx + a 66M-parameter Zipformer2 transducer
/// (ivrit-ai/zipformer2-66m-streaming-he, int8, ~72 MB, CC-BY-4.0).
///
/// Why this instead of Whisper: it decodes in 1.28 s chunks *while* the person is talking
/// (Whisper can only look at a finished clip), it needs ~0.2 GB instead of ~2 GB of RAM,
/// and on ivrit.ai's Hebrew test sets it scores better than whisper-large-v3-turbo
/// (5.3 / 8.8 WER vs 8.4 / 12.8 for stock whisper-large-v3-turbo).
/// Endpointing inside the model is the acoustic half of the sense gate.
final class SherpaStreamingSTT: StreamingSTT {

    static let folderName = "Model/STT"
    static let requiredFiles = ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"]

    private let input: AudioInput
    /// Two identical streams (item 1). Both are fed every sample; only the active one decodes.
    /// At an endpoint the other takes over, so the microphone is never left without a live
    /// decoder while the finished one is reset.
    private var recognizers: [SherpaOnnxRecognizer] = []
    private var active = 0
    /// The most recent 0.3 s of audio. At a handover it is replayed into the standby stream, so
    /// that stream has already been listening when it becomes live — the second stream starts
    /// recognising 0.3 s before the first one stops.
    private var tailSamples: [Float] = []
    private var tailRate: Double = 16_000
    private static let handoverSeconds: Double = 0.3
    /// What the outgoing stream had already reported; the incoming stream repeats the tail of it,
    /// and the clearer removes those repeated words from its first result.
    private var handoverText = ""
    private var clearNextResult = false
    private let lock = NSLock()
    /// Decoding must not run on the audio tap thread: it made the tap miss buffers, which is the
    /// "STT stops listening and drops words" that was reported.
    private let decodeQueue = DispatchQueue(label: "heen.stt.decode")
    private var pending: [Float] = []
    private var pendingRate: Double = 16_000
    private var draining = false
    private var lastVoiceTime = Date.distantPast
    private var lastText = ""
    private var startedAt = Date()
    private var loadNote = ""

    var onPartial: ((String) -> Void)?
    var onEndpoint: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var muted = false

    // MARK: - Model location

    static func folder() -> URL? {
        Bundle.main
            .url(forResource: "encoder.int8", withExtension: "onnx", subdirectory: folderName)?
            .deletingLastPathComponent()
    }

    static func missingFiles() -> [String] {
        guard let folder = folder() else { return ["\(folderName)/ (folder not in bundle)"] }
        return requiredFiles.filter {
            !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    var statusText: String {
        let missing = Self.missingFiles()
        if !missing.isEmpty { return "STT model missing: \(missing.joined(separator: ", "))" }
        return "zipformer2-66m-streaming-he (int8, offline)"
            + (loadNote.isEmpty ? "" : " — \(loadNote)")
    }

    // MARK: - Lifecycle

    init(input: AudioInput = MicrophoneInput()) {
        self.input = input
        self.input.onSamples = { [weak self] samples, rate in
            self?.enqueue(samples, sampleRate: rate)
        }
    }

    func start() throws {
        if recognizers.isEmpty {
            let began = Date()
            recognizers = [Self.makeRecognizer(), Self.makeRecognizer()].compactMap { $0 }
            loadNote = "loaded in \(Int(Date().timeIntervalSince(began) * 1000)) ms"
            Pipeline.trace("STT engine ready (2 streams): \(statusText)")
        }
        guard !recognizers.isEmpty else {
            let message = statusText
            onError?(message)
            throw NSError(domain: "heen.stt", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        startedAt = Date()
        lastVoiceTime = Date()
        try input.start()
    }

    func stop() {
        input.stop()
        lock.lock()
        for r in recognizers { r.reset() }
        // A new session starts with no handover in flight and no replayed audio.
        tailSamples = []
        handoverText = ""
        clearNextResult = false
        pending.removeAll()
        lastText = ""
        lock.unlock()
    }

    /// Long sessions are fine for this model, but an utterance that never ends is not:
    /// after 50 s with no endpoint the stream is reset so memory cannot creep.
    func restartIfNeeded(maxSeconds: TimeInterval = 50) {
        guard Date().timeIntervalSince(startedAt) > maxSeconds, silenceDuration > 2.0 else { return }
        // The *standby* stream is cleared, never the live one: resetting the live recogniser threw
        // away whatever had just been said.
        lock.lock()
        if recognizers.count == 2 { recognizers[1 - active].reset() }
        lock.unlock()
        startedAt = Date()
    }

    var silenceDuration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastVoiceTime)
    }

    var isSpeechActive: Bool { silenceDuration < 0.35 }

    // MARK: - Recognition

    /// Audio-tap thread. It only copies the samples and returns — decoding happens on
    /// `decodeQueue`, so a slow decode can no longer make the tap drop audio.
    private func enqueue(_ samples: [Float], sampleRate: Double) {
        guard !muted, !samples.isEmpty else { return }
        lock.lock()
        // Bounded backlog: if decoding ever falls behind, the oldest audio goes rather than
        // growing without limit.
        let cap = 16_000 * 6
        if pending.count > cap { pending.removeFirst(pending.count - cap) }
        pending.append(contentsOf: samples)
        pendingRate = sampleRate
        let needsDrain = !draining
        if needsDrain { draining = true }
        lock.unlock()
        if needsDrain { decodeQueue.async { [weak self] in self?.drain() } }
    }

    /// Decode thread. Both streams (item 1) are fed every sample; only the active one is decoded,
    /// so the cost stays close to a single recogniser while the standby keeps a warm context.
    private func drain() {
        while true {
            lock.lock()
            if muted || recognizers.count != 2 {
                pending.removeAll()
                draining = false
                lock.unlock()
                return
            }
            let chunk = pending
            let rate = pendingRate
            pending.removeAll(keepingCapacity: true)
            if chunk.isEmpty {
                draining = false
                lock.unlock()
                return
            }
            lock.unlock()

            for r in recognizers { r.acceptWaveform(samples: chunk, sampleRate: Int(rate)) }
            // Keep the newest audio for the handover replay. The standby stream gets this the
            // moment it becomes live, which is what makes it start 0.3 s early.
            let keep = Int(rate * Self.handoverSeconds)
            tailRate = rate
            if chunk.count >= keep {
                tailSamples = Array(chunk.suffix(keep))
            } else {
                tailSamples.append(contentsOf: chunk)
                if tailSamples.count > keep { tailSamples.removeFirst(tailSamples.count - keep) }
            }
            let activeIndex = active
            let current = recognizers[activeIndex]
            while current.isReady() { current.decode() }
            let raw = current.getResult().text
            // The clearer: a stream that just took over repeats the tail of the sentence the
            // previous stream finished with, and those repeated words are removed here — this is
            // the overlap between the two streams, cleared before anything is shown or spoken.
            var text = raw
            if clearNextResult, !raw.isEmpty {
                let cleared = TextUtil.dropOverlap(previous: handoverText, next: raw)
                if !cleared.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    text = cleared
                    clearNextResult = false
                }
            }
            let endpoint = current.isEndpoint()

            lock.lock()
            if !text.isEmpty { lastVoiceTime = Date() }
            let changed = !text.isEmpty && text != lastText
            if changed { lastText = text }
            if endpoint {
                // Item 1, exactly as specified: the standby stream is cleared and then fed the last
                // 0.3 s of audio, so it has been recognising since *before* this boundary — the two
                // streams hand over to each other at every endpoint, and no word is lost at the
                // seam. What the incoming stream repeats from the sentence just finished is removed
                // by the clearer on its first result.
                let next = 1 - activeIndex
                recognizers[next].reset()
                if !tailSamples.isEmpty {
                    recognizers[next].acceptWaveform(samples: tailSamples, sampleRate: Int(tailRate))
                }
                recognizers[activeIndex].reset()
                active = next
                handoverText = text
                clearNextResult = true
                lastText = ""
            }
            lock.unlock()

            if changed { onPartial?(text) }
            if endpoint {
                let final = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !final.isEmpty { onEndpoint?(final) }
            }
        }
    }

    private static func makeRecognizer() -> SherpaOnnxRecognizer? {
        guard missingFiles().isEmpty, let folder = folder() else { return nil }
        let transducer = sherpaOnnxOnlineTransducerModelConfig(
            encoder: folder.appendingPathComponent("encoder.int8.onnx").path,
            decoder: folder.appendingPathComponent("decoder.int8.onnx").path,
            joiner: folder.appendingPathComponent("joiner.int8.onnx").path)
        let model = sherpaOnnxOnlineModelConfig(
            tokens: folder.appendingPathComponent("tokens.txt").path,
            transducer: transducer,
            numThreads: 2,
            modelType: "zipformer2")
        let features = sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80)
        // Endpointing is the acoustic half of the sense gate: 1.1 s of silence closes a clause,
        // 0.7 s while the transcript is still growing, and nothing may run past 12 s.
        var config = sherpaOnnxOnlineRecognizerConfig(
            featConfig: features,
            modelConfig: model,
            enableEndpoint: true,
            rule1MinTrailingSilence: 1.1,
            rule2MinTrailingSilence: 0.7,
            rule3MinUtteranceLength: 12,
            decodingMethod: "greedy_search",
            maxActivePaths: 4)
        return SherpaOnnxRecognizer(config: &config)
    }
}

/// Deterministic test double: replays scripted partials/endpoints through the real pipeline,
/// so the gate, the anti-repeat rule and the TTS queue can be verified in the simulator
/// without a microphone.
final class ScriptedSTT: StreamingSTT {
    struct Step {
        let partial: String?
        let endpoint: String?
        init(partial: String? = nil, endpoint: String? = nil) {
            self.partial = partial
            self.endpoint = endpoint
        }
    }

    private let steps: [Step]
    private let interval: TimeInterval
    private var index = 0
    private var timer: Timer?

    var onPartial: ((String) -> Void)?
    var onEndpoint: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var muted = false
    var silenceDuration: TimeInterval = 0
    var isSpeechActive: Bool { false }
    var statusText: String { "scripted (test)" }

    init(steps: [Step], interval: TimeInterval = 0.05) {
        self.steps = steps
        self.interval = interval
    }

    func start() throws {
        index = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.advance()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func restartIfNeeded(maxSeconds: TimeInterval) {}

    private func advance() {
        guard index < steps.count else {
            timer?.invalidate()
            timer = nil
            return
        }
        let step = steps[index]
        index += 1
        if let partial = step.partial { onPartial?(partial) }
        if let endpoint = step.endpoint { onEndpoint?(endpoint) }
    }
}
