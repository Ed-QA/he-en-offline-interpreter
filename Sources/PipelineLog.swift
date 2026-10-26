import Foundation
import SwiftUI

extension Pipeline {

    // MARK: - On-device trace (the PC pulls Documents/live.log to verify a run)

    private static let traceQueue = DispatchQueue(label: "heen.trace")

    nonisolated static func trace(_ line: String) {
        NSLog("[HEEN] %@", line)   // visible in the device syslog, streamed from the PC
        let stamp = DateFormatter.logStamp.string(from: Date())
        let text = "[\(stamp)] \(line)\n"
        traceQueue.async {
            guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let url = dir.appendingPathComponent("live.log")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(text.data(using: .utf8) ?? Data())
                try? handle.close()
            } else {
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Starts a new session marker instead of deleting the file: a pulled log must never
    /// look "empty" after a restart, and previous evidence has to survive.
    nonisolated static func resetTrace() {
        traceQueue.async {
            guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let url = dir.appendingPathComponent("live.log")
            let stamp = DateFormatter.logStamp.string(from: Date())
            let line = "[\\(stamp)] ===== new session =====\n"
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8) ?? Data())
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Last lines of the on-device trace file. The log screen falls back to this, so it is
    /// never blank just because no sentence has been emitted yet.
    nonisolated static func traceTail(maxLines: Int = 200) -> String {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return "" }
        let url = dir.appendingPathComponent("live.log")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    /// Partials are UI-only. They are deliberately NOT written to the trace file,
    /// so the on-device log stays a short list of real events (emit → translate → speak).
    func tracePartial(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != Self.lastTracedPartial else { return }
        Self.lastTracedPartial = trimmed
    }

    // MARK: - Log export

    /// The report the "Send logs" control hands to the native share sheet: header, device and
    /// model state, the conversation and the live trace. One self-contained text file, so it can
    /// be mailed or dropped into a chat as-is.
    func logText() -> String {
        var out = "HE-EN OFFLINE INTERPRETER — FULL LOG\n\(Date())\n\n"
        out += "== device ==\n"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        out += "app: \(version) (\(build))\n"
        out += "device: \(UIDevice.current.name), iOS \(UIDevice.current.systemVersion)\n"
        out += "state: \(running ? "running" : "stopped"), \(status.rawValue), gate \(gate.mode.rawValue)\n"
        out += "engine: \(engineStatus)\n"
        switch modelsState {
        case .loading: out += "models: loading\n"
        case .active(let detail): out += "models: ready — \(detail)\n"
        case .failed(let why): out += "models: FAILED — \(why)\n"
        }
        out += "speech: \(sttStatus)\n"
        out += "nikud: \(nikud != nil ? "loaded" : (nikudUnavailable ? "unavailable" : "not loaded yet"))\n"
        if let lastError { out += "last error: \(lastError)\n" }
        out += "\n== conversation (\(log.count)) ==\n"
        for e in log {
            out += "[\(DateFormatter.logStamp.string(from: e.date))]\(e.forced ? " (incomplete)" : "")\n"
            out += "HE: \(e.hebrew)\n"
            out += "EN: \(e.english)\n\n"
        }
        out += "== trace (Documents/live.log, last 400 lines) ==\n"
        out += Self.traceTail(maxLines: 400)
        return out
    }

    func writeLogFile() -> URL? {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("log-\(f.string(from: Date())).txt")
        do {
            try logText().write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Voice samples

    func runVoiceSampler() {
        voiceSampleProgress = "Starting…"
        Task { @MainActor in
            let report = await VoiceSampler.generateAll { line in
                Task { @MainActor in self.voiceSampleProgress = line }
            }
            self.voiceSampleReport = report
        }
    }
}
