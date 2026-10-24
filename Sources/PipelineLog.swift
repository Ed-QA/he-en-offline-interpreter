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

    nonisolated static func resetTrace() {
        traceQueue.async {
            guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("live.log"))
        }
    }

    /// Partials are UI-only. They are deliberately NOT written to the trace file,
    /// so the on-device log stays a short list of real events (emit → translate → speak).
    func tracePartial(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != Self.lastTracedPartial else { return }
        Self.lastTracedPartial = trimmed
    }

    // MARK: - Log export

    func logText() -> String {
        var out = "HE-EN OFFLINE INTERPRETER — FULL LOG\n\(Date())\n\n"
        for e in log {
            out += "[\(DateFormatter.logStamp.string(from: e.date))]\(e.forced ? " (incomplete)" : "")\n"
            out += "HE: \(e.hebrew)\n"
            out += "EN: \(e.english)\n\n"
        }
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
