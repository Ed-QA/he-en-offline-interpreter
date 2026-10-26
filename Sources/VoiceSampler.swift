import Foundation
import AVFoundation

/// Renders offline audio for one utterance via AVSpeechSynthesizer.write.
final class OfflineRenderer: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var samples: [Float] = []
    private var sampleRate: Double = 22050
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumed = false

    override init() {
        super.init()
        synth.delegate = self
    }

    func render(_ text: String, voice: AVSpeechSynthesisVoice, rate: Float) async -> (samples: [Float], sampleRate: Double) {
        samples = []
        resumed = false
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            continuation = c
            synth.write(utterance) { [weak self] buffer in
                guard let self,
                      let pcm = buffer as? AVAudioPCMBuffer,
                      let channel = pcm.floatChannelData else { return }
                let frames = Int(pcm.frameLength)
                guard frames > 0 else { return }
                self.sampleRate = pcm.format.sampleRate
                self.samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: frames))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
                self?.finishIfNeeded()
            }
        }
        return (samples, sampleRate)
    }

    private func finishIfNeeded() {
        guard !resumed else { return }
        resumed = true
        continuation?.resume()
        continuation = nil
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { finishIfNeeded() }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { finishIfNeeded() }
}

/// Generates a 20-second sample for EVERY available English voice,
/// then verifies 3 times that no two samples share a voice.
final class VoiceSampler {

    struct Sample {
        let voiceName: String
        let identifier: String
        let language: String
        let quality: String
        let duration: Double
        let rms: Float
        let sha256: String
        let fileName: String
        let error: String?
    }

    struct Report {
        let samples: [Sample]
        let checks: [(String, Bool)]
        let reportURL: URL?
        var passed: Bool { checks.allSatisfy { $0.1 } && samples.allSatisfy { $0.error == nil } }
    }

    /// Cancellation shared with the render loop: rendering every installed voice takes minutes
    /// and there used to be no way out. A tiny locked box keeps it `Sendable` without bouncing
    /// every check through the main actor.
    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func set() { lock.lock(); flag = true; lock.unlock() }
        func clear() { lock.lock(); flag = false; lock.unlock() }
    }

    static let script = "This is a twenty second voice sample for the offline Hebrew to English interpreter. The quick brown fox jumps over the lazy dog. Numbers: one, two, three, twenty five, one hundred. Names: David, Sarah, Jerusalem, Tel Aviv. Please compare this voice with the other voices in the list and choose the clearest one."

    static func outputDirectory() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceSamples", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func generateAll(targetSeconds: Double = 20,
                            shouldCancel: @escaping @Sendable () -> Bool = { false },
                            progress: @escaping (String) -> Void) async -> Report {
        let dir = outputDirectory()
        let voices = Speaker.englishVoices()
        var samples: [Sample] = []

        for (idx, voice) in voices.enumerated() {
            if shouldCancel() {
                progress("Cancelled — \(idx) of \(voices.count) voices rendered.")
                break
            }
            progress("Rendering \(idx + 1)/\(voices.count): \(voice.name) [\(voice.language)]")
            let renderer = OfflineRenderer()
            var all: [Float] = []
            var sr: Double = 22050
            var pass = 0
            while Double(all.count) / max(sr, 1) < targetSeconds && pass < 3 {
                let out = await renderer.render(script, voice: voice, rate: 0.5)
                sr = out.sampleRate
                all.append(contentsOf: out.samples)
                pass += 1
            }
            let targetCount = Int(targetSeconds * sr)
            if all.count > targetCount { all = Array(all.prefix(targetCount)) }
            let duration = Double(all.count) / max(sr, 1)
            let rms = WAV.rms(all)
            let safe = voice.name.replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "/", with: "-")
            let fileName = "\(String(format: "%02d", idx + 1))_\(safe)_\(voice.language).wav"
            let url = dir.appendingPathComponent(fileName)
            var sha = ""
            var err: String?
            do {
                try WAV.write(samples: all, sampleRate: sr, to: url)
                sha = try WAV.sha256(of: url)
            } catch {
                err = error.localizedDescription
            }
            samples.append(Sample(voiceName: voice.name,
                                  identifier: voice.identifier,
                                  language: voice.language,
                                  quality: Speaker.qualityLabel(voice),
                                  duration: duration,
                                  rms: rms,
                                  sha256: sha,
                                  fileName: fileName,
                                  error: err))
        }

        progress("Verifying (3 checks)…")
        let ids = samples.map(\.identifier)
        let hashes = samples.map(\.sha256).filter { !$0.isEmpty }
        let checkIdentifiers = Set(ids).count == ids.count
        let checkHashes = Set(hashes).count == hashes.count
        let checkAudio = samples.allSatisfy {
            $0.error == nil && $0.duration >= targetSeconds - 0.15 && $0.rms > 0.0005
        }
        let checks: [(String, Bool)] = [
            ("CHECK 1 — every sample uses a different voice (unique identifiers)", checkIdentifiers),
            ("CHECK 2 — every sample has different audio (unique SHA-256)", checkHashes),
            ("CHECK 3 — every sample is ~20.0s and non-silent", checkAudio)
        ]

        var report = "VOICE SAMPLES — ALL ENGLISH VOICES\n"
        report += "Generated: \(Date())\n"
        report += "Voices rendered: \(samples.count)\n"
        for (name, ok) in checks { report += "\(ok ? "PASS" : "FAIL") — \(name)\n" }
        report += "\nListen: Files app → On My iPhone → HE-EN Offline → VoiceSamples\n\n"
        for s in samples {
            report += "\(s.voiceName) | \(s.language) | \(s.quality) | "
            report += String(format: "%.2fs | rms %.4f | ", s.duration, s.rms)
            report += "\(String(s.sha256.prefix(12))) | \(s.fileName)\n"
            if let error = s.error { report += "    ERROR: \(error)\n" }
        }

        var csv = "voice,identifier,language,quality,duration,rms,sha256,file,error\n"
        for s in samples {
            csv += "\"\(s.voiceName)\",\"\(s.identifier)\",\"\(s.language)\",\"\(s.quality)\","
            csv += String(format: "%.3f,%.5f,", s.duration, s.rms)
            csv += "\(s.sha256),\(s.fileName),\"\(s.error ?? "")\"\n"
        }

        let reportURL = dir.appendingPathComponent("report.txt")
        try? report.write(to: reportURL, atomically: true, encoding: .utf8)
        try? csv.write(to: dir.appendingPathComponent("report.csv"), atomically: true, encoding: .utf8)
        progress("Done: \(samples.count) voices — \(checks.allSatisfy { $0.1 } ? "all checks PASS" : "CHECKS FAILED")")
        return Report(samples: samples, checks: checks, reportURL: reportURL)
    }
}

