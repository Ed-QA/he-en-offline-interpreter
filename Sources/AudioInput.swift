import Foundation
import AVFoundation

/// Where 16 kHz mono float samples come from: the microphone on a phone, a WAV file in tests.
/// This split is what lets the entire pipeline run inside the iOS Simulator with no hardware.
protocol AudioInput: AnyObject {
    var onSamples: (([Float], Double) -> Void)? { get set }
    func start() throws
    func stop()
    var describe: String { get }
}

// MARK: - Microphone (the only real-device source)

final class MicrophoneInput: AudioInput {
    private let engine = AVAudioEngine()
    private var tapInstalled = false
    var onSamples: (([Float], Double) -> Void)?

    /// Routing is the system's job: iOS already uses the earbuds when they are connected and the
    /// phone's own mic and speaker when they are not. The app only follows that.
    var describe: String { "microphone" }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // NOTE: `.voiceChat` turns on voice-processing (AEC/AGC) which silences or badly ducks
        // AVSpeechSynthesizer output. `.default` keeps the mic live while the translation plays.
        // `.allowBluetooth` is what makes a Bluetooth headset usable as the microphone at all;
        // `.allowBluetoothA2DP` keeps high-quality audio going out to those same earbuds.
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .allowBluetoothA2DP,
                                          .allowBluetooth, .duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        // The saved microphone/output choices can only be applied once the session is active.
        AudioRoute.applySaved()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        if !tapInstalled {
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self, let samples = Self.mono(buffer) else { return }
                self.onSamples?(samples, format.sampleRate)
            }
            tapInstalled = true
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Down-mixes the mic buffer to mono float samples (rate is passed through — sherpa
    /// resamples to the model rate itself).
    static func mono(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { return nil }
        let channelCount = Int(buffer.format.channelCount)
        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channels[0], count: frames))
        }
        var out = [Float](repeating: 0, count: frames)
        for channel in 0..<channelCount {
            let pointer = channels[channel]
            for frame in 0..<frames { out[frame] += pointer[frame] }
        }
        let scale = 1 / Float(channelCount)
        for frame in 0..<frames { out[frame] *= scale }
        return out
    }
}

// MARK: - File input (simulator / CI / offline replay)

/// Replays a WAV file at real-time speed. Used by the simulator tests and by "replay a lesson
/// recording" runs, so the whole pipeline can be verified without a phone or a microphone.
final class FileAudioInput: AudioInput {
    private let url: URL
    private let queue = DispatchQueue(label: "heen.fileaudio")
    private var timer: DispatchSourceTimer?
    private var samples: [Float] = []
    private var offset = 0
    private var rate: Double = 16_000
    private let chunkFrames = 1_600   // 100 ms of audio per tick

    var onSamples: (([Float], Double) -> Void)?

    var describe: String { "file: \(url.lastPathComponent)" }

    init(url: URL) {
        self.url = url
    }

    func start() throws {
        let decoded = try WAV.readMono(url: url)
        samples = decoded.samples
        rate = decoded.sampleRate
        offset = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync { offset = samples.count }
    }

    private func tick() {
        guard offset < samples.count else { return }
        let end = min(offset + chunkFrames, samples.count)
        let slice = Array(samples[offset..<end])
        offset = end
        onSamples?(slice, rate)
    }
}
