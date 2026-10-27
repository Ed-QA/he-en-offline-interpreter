import Foundation

#if canImport(SherpaOnnxShared)
import SherpaOnnxShared
#elseif canImport(SherpaOnnx)
import SherpaOnnx
#endif

/// Hebrew speech recognition that puts the nikud in the text **straight from the voice**.
///
/// The acoustic model is MayBog/whisper-hebrew-nikud-v1 ("Nikudon", Whisper large-v3-turbo
/// fine-tuned by ivrit-ai), prepared by `Tools/prepare_stt_nikud.py` into `Model/WhisperNikud`.
/// It is a Whisper, so it is not a streaming model: audio is recognised in windows. There is no
/// second model and no post-hoc diacritizer anywhere in this app — the points come out of the
/// same pass as the words.
final class WhisperNikudSTT: StreamingSTT {

    var onPartial: ((String) -> Void)?
    var onEndpoint: ((String) -> Void)?
    var onError: ((String) -> Void)?

    /// While true, incoming audio is dropped: our own speech must never be transcribed.
    var muted = false

    private(set) var silenceDuration: TimeInterval = .greatestFiniteMagnitude
    var isSpeechActive: Bool { silenceDuration < 0.35 }
    var statusText: String {
        recognizer == nil
            ? "Hebrew ASR with nikud not available (\(Self.missingFiles().joined(separator: ", ")))"
            : "Whisper-Nikudon (nikud from the voice), int8"
    }

    // MARK: - Tuning

    /// Longest window handed to the model at once.
    private static let maxWindow: TimeInterval = 12
    /// How much new audio triggers a fresh partial transcription.
    private static let partialStep: TimeInterval = 2.5
    /// Audio carried across an utterance handover, so a word split by the endpoint is still heard
    /// in full by the recogniser that transcribes it.
    private static let handover: TimeInterval = 0.3
    /// Trailing silence that closes an utterance.
    private static let endpointSilence: TimeInterval = 0.7
    /// Audio level above which a frame counts as speech.
    private static let speechLevel: Float = 0.008

    private let input: AudioInput
    private let lock = NSLock()

    private var recognizer: OpaquePointer?
    private var samples: [Float] = []
    private var sampleRate: Double = 16_000
    private var lastSpeechAt = Date.distantPast
    private var lastPartialLength = 0
    private var running = false
    /// Text of the last finished utterance. The next utterance's first result is passed through
    /// `TextUtil.dropOverlap` against it, so the 0.3 s of audio carried across the handover can
    /// never appear twice on screen, in the translation or in the voice.
    private var lastFinalText = ""
    private var pendingOverlapTrim = false

    init(input: AudioInput = MicrophoneInput()) {
        self.input = input
        recognizer = Self.makeRecognizer()
        input.onSamples = { [weak self] chunk, rate in
            self?.accept(chunk, rate: rate)
        }
    }

    deinit {
        if let recognizer { SherpaOnnxDestroyOfflineRecognizer(recognizer) }
    }

    // MARK: - Model

    static func folder() -> URL? {
        Bundle.main.url(forResource: "encoder_model", withExtension: "onnx",
                        subdirectory: "Model/WhisperNikud")?.deletingLastPathComponent()
    }

    static func missingFiles() -> [String] {
        guard let folder = folder() else { return ["Model/WhisperNikud (not in bundle)"] }
        let needed = ["encoder_model.int8.onnx", "decoder_model.int8.onnx", "tokens.txt"]
        return needed.filter {
            !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    private static func makeRecognizer() -> OpaquePointer? {
        guard missingFiles().isEmpty, let folder = folder() else { return nil }
        let base = folder.path
        let config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80),
            modelConfig: sherpaOnnxOfflineModelConfig(
                tokens: "\(base)/tokens.txt",
                whisper: sherpaOnnxOfflineWhisperModelConfig(
                    encoder: "\(base)/encoder_model.int8.onnx",
                    decoder: "\(base)/decoder_model.int8.onnx",
                    language: "he",
                    task: "transcribe"),
                numThreads: 2,
                provider: "cpu",
                debug: 0,
                modelType: "whisper"),
            decodingMethod: "greedy_search")
        return SherpaOnnxCreateOfflineRecognizer(&config)
    }

    // MARK: - Audio in

    private func accept(_ chunk: [Float], rate: Double) {
        guard !muted, running else { return }
        let level = chunk.isEmpty ? 0 : sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
        lock.lock()
        sampleRate = rate
        samples.append(contentsOf: chunk)
        if level > Self.speechLevel { lastSpeechAt = Date() }
        let seconds = Double(samples.count) / rate
        let sinceSpeech = Date().timeIntervalSince(lastSpeechAt)
        // Keep the window bounded: anything older than the window is dropped, so memory and the
        // cost of one recognition stay flat during a long monologue.
        if seconds > Self.maxWindow {
            let drop = Int((seconds - Self.maxWindow) * rate)
            samples.removeFirst(min(drop, samples.count))
        }
        let shouldFinish = sinceSpeech > Self.endpointSilence && seconds > 1.0
        let grew = Double(samples.count - lastPartialLength) / rate >= Self.partialStep
        silenceDuration = sinceSpeech
        lock.unlock()

        if shouldFinish {
            run(final: true)
        } else if grew {
            run(final: false)
        }
    }

    /// One pass of the model. `final` means the utterance ended: the text is reported as an
    /// endpoint and the audio window is cleared.
    private func run(final: Bool) {
        lock.lock()
        guard let recognizer, !samples.isEmpty else { lock.unlock(); return }
        let audio = samples
        let rate = Int(sampleRate)
        lastPartialLength = final ? 0 : audio.count
        lock.unlock()

        let stream = SherpaOnnxCreateOfflineStream(recognizer)
        SherpaOnnxAcceptWaveformOffline(stream, Int32(rate), audio, Int32(audio.count))
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        let result = SherpaOnnxGetOfflineStreamResult(stream)
        var text = result.map { String(cString: $0.pointee.text) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let result { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        SherpaOnnxDestroyOfflineStream(stream)

        guard !text.isEmpty else { return }
        lock.lock()
        if pendingOverlapTrim {
            let trimmed = TextUtil.dropOverlap(previous: lastFinalText, next: text)
            if !trimmed.isEmpty {
                text = trimmed
                pendingOverlapTrim = false
            }
        }
        lock.unlock()
        if final {
            lock.lock()
            // Handover: keep the last 0.3 s of audio, exactly like the two-recogniser scheme —
            // the standby became live carrying that tail. The next utterance starts from it, and
            // `dropOverlap` above is what stops the carried words from being said twice.
            let keep = Int(Self.handover * sampleRate)
            samples = keep > 0 ? Array(samples.suffix(keep)) : []
            lastPartialLength = 0
            lastFinalText = text
            pendingOverlapTrim = true
            silenceDuration = .greatestFiniteMagnitude
            lock.unlock()
            onEndpoint?(text)
        } else {
            onPartial?(text)
        }
    }

    // MARK: - StreamingSTT

    func start() throws {
        guard recognizer != nil else {
            throw NSError(domain: "heen.stt", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: statusText])
        }
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lastPartialLength = 0
        lastFinalText = ""
        pendingOverlapTrim = false
        lastSpeechAt = .distantPast
        silenceDuration = .greatestFiniteMagnitude
        running = true
        lock.unlock()
        try input.start()
    }

    func stop() {
        lock.lock()
        running = false
        samples.removeAll(keepingCapacity: true)
        lastPartialLength = 0
        lastFinalText = ""
        pendingOverlapTrim = false
        silenceDuration = .greatestFiniteMagnitude
        lock.unlock()
        input.stop()
    }

    /// Nothing to restart: the model is offline and keeps no rolling state.
    func restartIfNeeded(maxSeconds: TimeInterval) {}
}
