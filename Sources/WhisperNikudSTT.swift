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
        let missing = Self.missingFiles()
        if !missing.isEmpty {
            return "Hebrew ASR with nikud not available (\(missing.joined(separator: ", ")))"
        }
        // The weights load on Start, so "not loaded yet" is the normal state until then and must
        // not read as a failure. What matters to the user is whether the model is *there*.
        return recognizer == nil
            ? "Whisper-Nikudon (nikud from the voice), int8 — loads on Start"
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

    /// What the lanes are doing, in numbers.
    ///
    /// Two questions the design has to answer on a phone — is the audio covered, and does the text
    /// stay in order — cannot be answered from the source, only from a run: whether a 2.0 s window
    /// finishes inside the 3.4 s each lane is given, and whether two lanes ever hand their text back
    /// in the wrong order. So every window is counted here and the numbers are printed into the app's
    /// log, where the owner can read them and send them back.
    struct Stats {
        var windowsCut = 0
        var windowsDecoded = 0
        var windowsSkippedSilent = 0
        /// Windows waiting for a lane at the moment a new one was handed over.
        var maxBacklog = 0
        /// Times a window finished after a later one — the case the overlap clearer cannot see.
        var outOfOrder = 0
        var lastDecodeMS = 0
        var slowestDecodeMS = 0
        /// Audio inside the windows, in seconds. Overlap makes this exceed the time actually spoken.
        var audioSecondsCut: Double = 0
    }
    private(set) var stats = Stats()

    /// Where the numbers go. The pipeline points this at its own trace, so the lines land in the
    /// app's log panel and in the log that gets sent back.
    var trace: ((String) -> Void)?

    /// Test seam: drives the lanes without a microphone and without loading the 843 MB model, and
    /// records how long a stand-in decoder takes so ordering and backlog can be exercised on purpose.
    private var decodeOverride: (([Float], Double) -> String?)?
    private var lastFinishedWindow = -1
    private var windowIndex = 0
    private var pending = 0

    private let input: AudioInput
    private let lock = NSLock()
    /// Two decode lanes: window n runs on lane 0 while window n+1 runs on lane 1 — the overlapping
    /// windows are decoded in parallel so the gap between them is never left unrecognised. Each
    /// window gets its own stream; the model weights are loaded once and shared by both lanes, so
    /// running the two in parallel costs one copy of the model in memory, not two.
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
        // The weights are NOT loaded here. This initialiser runs during app launch (Pipeline builds
        // it at startup), and pulling 843 MB of int8 weights in at launch — before the user asked
        // for anything — is what made the app close instantly on the phone with no error. Launch
        // stays light; the model loads on the first Start.
        input.onSamples = { [weak self] chunk, rate in
            self?.accept(chunk, rate: rate)
        }
    }

    deinit {
        recognizer = nil
    }

    // MARK: - Model

    static func folder() -> URL? {
        // The bundle ships the int8 files: the fp32 exports are deleted right after quantization, so
        // probing for `encoder_model.onnx` found nothing and the recogniser was reported as "not in
        // bundle" while the folder was in the app all along. Ask for the name that really ships.
        Bundle.main.url(forResource: "encoder_model.int8", withExtension: "onnx",
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
            // 128 mel bins: the large-v3 family (this checkpoint is a large-v3-turbo fine-tune) is
            // trained on 128, not the 80 of the older Whisper sizes. The runtime takes the real
            // number from the encoder's `n_mels` metadata; this keeps the two in step.
            featConfig: sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 128),
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
            stats.windowsCut += 1
            stats.audioSecondsCut += Double(window.count) / rate
        }
        let ended = sinceSpeech > Self.endpointSilence && !utterance.isEmpty
        lock.unlock()

        if !window.isEmpty, Self.hasSpeech(window) {
            decode(window: window, rate: rate)
        } else if !window.isEmpty {
            stats.windowsSkippedSilent += 1
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

    /// One window, one model pass, on whichever lane is free. The two lanes run in parallel:
    /// window n is still decoding while window n+1 starts.
    private func decode(window: [Float], rate: Double) {
        lock.lock()
        lane = (lane + 1) % lanes.count
        let laneIndex = lane
        let queue = lanes[laneIndex]
        windowIndex += 1
        let index = windowIndex
        pending += 1
        stats.windowsDecoded += 1
        if pending > stats.maxBacklog { stats.maxBacklog = pending }
        let backlog = pending
        let override = decodeOverride
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let t0 = Date()
            var text: String?
            if let override {
                text = override(window, rate)
            } else if let recognizer = self.recognizer {
                // A fresh stream per window: a stream keeps the audio it was given, so a reused one
                // would hand the model this window *and* the previous one. The weights are shared —
                // that is what lets both lanes decode at once for one copy of the model in memory.
                let stream = recognizer.createStream()
                stream.acceptWaveform(samples: window, sampleRate: Int(rate))
                recognizer.decode(stream: stream)
                text = recognizer.getResult(stream: stream).text
            }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)

            self.lock.lock()
            self.pending -= 1
            self.stats.lastDecodeMS = ms
            if ms > self.stats.slowestDecodeMS { self.stats.slowestDecodeMS = ms }
            // A window landing after a later one is exactly the case the overlap clearer cannot see:
            // it compares against the last window that *finished*, not the one before it in time.
            if index < self.lastFinishedWindow { self.stats.outOfOrder += 1 }
            self.lastFinishedWindow = max(self.lastFinishedWindow, index)
            let outOfOrder = self.stats.outOfOrder
            let decoded = self.stats.windowsDecoded
            self.lock.unlock()

            self.trace?("window \(index): \(ms) ms on lane \(laneIndex), backlog \(backlog), "
                        + "out of order \(outOfOrder) of \(decoded)")

            guard let text else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            self.take(text: trimmed)
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
        // First Start loads the weights. Doing it here — not in `init`, which runs at app launch —
        // is what keeps launch alive on a phone that kills a sudden 843 MB spike. If the model is
        // broken this throws and the app shows it, instead of dying silently.
        if recognizer == nil { recognizer = Self.makeRecognizer() }
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
    // MARK: - Test seam

    /// Drives the lanes without a microphone and without the 843 MB model. `decoder` stands in for
    /// the recogniser and can be made slow on purpose, so ordering, backlog and coverage are
    /// exercised deliberately instead of guessed at.
    func beginForTest(decoder: @escaping ([Float], Double) -> String?) {
        lock.lock()
        decodeOverride = decoder
        running = true
        lock.unlock()
    }

    func feedForTest(_ samples: [Float], rate: Double) {
        accept(samples, rate: rate)
    }

    /// One line for the app's log: what the lanes did, in numbers. The budget is what a lane has per
    /// window — a window starts every `stride`, and each lane gets every second one.
    var statsLine: String {
        lock.lock()
        defer { lock.unlock() }
        let budget = Int(2 * Self.stride * 1000)
        return "lanes: \(stats.windowsDecoded) windows decoded, \(stats.windowsSkippedSilent) skipped "
            + "as silence, backlog max \(stats.maxBacklog), out of order \(stats.outOfOrder), "
            + "decode last \(stats.lastDecodeMS) ms, slowest \(stats.slowestDecodeMS) ms, "
            + "budget \(budget) ms per window"
    }

    func restartIfNeeded(maxSeconds: TimeInterval) {}
}
