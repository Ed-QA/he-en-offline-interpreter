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

    /// One recognition window: the audio a single model pass sees. The owner's scheme — a window
    /// starts, and 1.7 s later the next one starts while the first is still running.
    private static let window: TimeInterval = 2.0
    /// How often a new window starts. `window - stride` is the overlap: 2.0 - 1.7 = 0.3 s.
    private static let stride: TimeInterval = 1.7
    /// Trailing silence that closes an utterance.
    private static let endpointSilence: TimeInterval = 0.7
    /// Audio level above which a window counts as speech. Whisper invents text out of silence, so
    /// a window without speech is never decoded at all.
    private static let speechLevel: Float = 0.008

    private let input: AudioInput
    private let lock = NSLock()
    /// Two decode lanes: window n runs on lane 0 while window n+1 runs on lane 1. Two recognisers
    /// working in parallel, each holding its own stream over the same model.
    private let lanes = [DispatchQueue(label: "heen.whisper.lane0", qos: .userInitiated),
                         DispatchQueue(label: "heen.whisper.lane1", qos: .userInitiated)]
    private var lane = 0

    private var recognizer: SherpaOnnxOfflineRecognizer?
    /// Rolling audio, never longer than one window.
    private var ring: [Float] = []
    /// Samples collected since the last window was cut.
    private var sinceWindow = 0
    /// Full text of the previous window — what the clearer compares against.
    private var lastWindowText = ""
    /// New text of the utterance being spoken right now, cleared when it is handed over.
    private var utterance = ""
    private var sampleRate: Double = 16_000
    private var lastSpeechAt = Date.distantPast
    private var running = false

    init(input: AudioInput = MicrophoneInput()) {
        self.input = input
        recognizer = Self.makeRecognizer()
        input.onSamples = { [weak self] chunk, rate in
            self?.accept(chunk, rate: rate)
        }
    }

    deinit {
        recognizer = nil
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

    private static func makeRecognizer() -> SherpaOnnxOfflineRecognizer? {
        guard missingFiles().isEmpty, let folder = folder() else { return nil }
        let base = folder.path
        var config = sherpaOnnxOfflineRecognizerConfig(
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
        return SherpaOnnxOfflineRecognizer(config: &config)
    }

    // MARK: - Audio in

    private func accept(_ chunk: [Float], rate: Double) {
        guard !muted, running else { return }
        let level = chunk.isEmpty ? 0 : sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
        lock.lock()
        sampleRate = rate
        ring.append(contentsOf: chunk)
        sinceWindow += chunk.count
        if level > Self.speechLevel { lastSpeechAt = Date() }
        // The ring never holds more than one window. Older audio already went to a window of its
        // own; the next window starts 1.7 s later and still finds the shared 0.3 s tail here.
        let maxRing = Int(Self.window * rate)
        if ring.count > maxRing { ring.removeFirst(ring.count - maxRing) }
        let sinceSpeech = Date().timeIntervalSince(lastSpeechAt)
        silenceDuration = sinceSpeech
        let due = Double(sinceWindow) / rate >= Self.stride
        var window: [Float] = []
        if due {
            sinceWindow = 0
            window = ring
        }
        let ended = sinceSpeech > Self.endpointSilence && !utterance.isEmpty
        lock.unlock()

        if !window.isEmpty, Self.hasSpeech(window) {
            decode(window: window, rate: rate)
        }
        if ended { flush() }
    }

    /// Whisper invents words out of silence, so a window without speech is never decoded.
    private static func hasSpeech(_ window: [Float]) -> Bool {
        let step = 160
        var i = 0
        while i + step <= window.count {
            var sum: Float = 0
            for j in i..<(i + step) { sum += window[j] * window[j] }
            if sqrt(sum / Float(step)) > speechLevel { return true }
            i += step
        }
        return false
    }

    /// One window, one model pass, on whichever lane is free. The two lanes are the two recognisers
    /// running in parallel: window n is still decoding while window n+1 starts.
    private func decode(window: [Float], rate: Double) {
        lock.lock()
        lane = (lane + 1) % lanes.count
        let queue = lanes[lane]
        lock.unlock()
        queue.async { [weak self] in
            guard let self, let recognizer = self.recognizer else { return }
            let text = recognizer.decode(samples: window, sampleRate: Int(rate))
                .text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            self.take(text: text)
        }
    }

    /// The clearer. Only what this window added is kept: everything the previous window already
    /// produced — the words in the shared 0.3 s — is dropped, and dropped only there.
    private func take(text: String) {
        lock.lock()
        let previous = lastWindowText
        lastWindowText = text
        let fresh = previous.isEmpty ? text : TextUtil.dropOverlap(previous: previous, next: text)
        if !fresh.isEmpty {
            utterance = utterance.isEmpty ? fresh : utterance + " " + fresh
        }
        let live = utterance
        lock.unlock()
        if !live.isEmpty { onPartial?(live) }
    }

    /// The utterance ended: hand the finished sentence over, and keep `lastWindowText` so the first
    /// window of the next utterance is still cleared against the words that came before it.
    private func flush() {
        lock.lock()
        let finished = utterance
        utterance = ""
        sinceWindow = 0
        lock.unlock()
        if !finished.isEmpty { onEndpoint?(finished) }
    }

    // MARK: - StreamingSTT

    func start() throws {
        guard recognizer != nil else {
            throw NSError(domain: "heen.stt", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: statusText])
        }
        lock.lock()
        ring.removeAll(keepingCapacity: true)
        sinceWindow = 0
        lastWindowText = ""
        utterance = ""
        lastSpeechAt = .distantPast
        silenceDuration = .greatestFiniteMagnitude
        running = true
        lock.unlock()
        try input.start()
    }

    func stop() {
        lock.lock()
        running = false
        ring.removeAll(keepingCapacity: true)
        sinceWindow = 0
        utterance = ""
        silenceDuration = .greatestFiniteMagnitude
        lock.unlock()
        input.stop()
    }

    /// Nothing to restart: the model is offline and keeps no rolling state.
    func restartIfNeeded(maxSeconds: TimeInterval) {}
}
