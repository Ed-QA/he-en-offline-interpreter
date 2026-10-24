import Foundation
import AVFoundation
import Speech

/// Continuous on-device Hebrew STT (he-IL) with silence tracking and restart handling.
final class HebrewRecognizer {
    private let locale = Locale(identifier: "he-IL")
    private lazy var recognizer = SFSpeechRecognizer(locale: locale)
    private let audioEngine = AVAudioEngine()
    private var currentRequest: SFSpeechAudioBufferRecognitionRequest?
    private var currentTask: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var requestStart = Date()

    private let lock = NSLock()
    private var lastVoiceTime = Date.distantPast
    private var recentRMS: Float = 0

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((String) -> Void)?

    var supportsOnDevice: Bool { recognizer?.supportsOnDeviceRecognition ?? false }
    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    var silenceDuration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastVoiceTime)
    }

    var isSpeechActive: Bool { silenceDuration < 0.35 }

    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { done(status == .authorized) }
        }
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        if !tapInstalled {
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                self.currentRequest?.append(buffer)
                self.trackLevels(buffer)
            }
            tapInstalled = true
        }
        audioEngine.prepare()
        try audioEngine.start()
        startNewRequest()
    }

    func stop() {
        currentRequest?.endAudio()
        currentTask?.cancel()
        currentRequest = nil
        currentTask = nil
        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled { audioEngine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Restart long sessions proactively (on-device requests are time-limited).
    func restartIfNeeded(maxSeconds: TimeInterval = 50) {
        guard currentTask != nil, Date().timeIntervalSince(requestStart) > maxSeconds else { return }
        startNewRequest()
    }

    private func startNewRequest() {
        currentRequest?.endAudio()
        currentTask?.cancel()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        if #available(iOS 16.0, *) { request.addsPunctuation = true }
        currentRequest = request
        requestStart = Date()

        currentTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if result.isFinal { self.onFinal?(text) } else { self.onPartial?(text) }
            }
            if let error {
                let ns = error as NSError
                // Benign cancellations happen on restart; only surface real failures.
                if ns.domain != "kAFAssistantErrorDomain" || ns.code != 216 {
                    self.onError?(error.localizedDescription)
                }
            }
        }
    }

    private func trackLevels(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var acc: Float = 0
        let p = ch[0]
        for i in 0..<n { acc += p[i] * p[i] }
        let rms = (acc / Float(n)).squareRoot()
        lock.lock()
        recentRMS = rms
        if rms > 0.012 { lastVoiceTime = Date() }
        lock.unlock()
    }
}
