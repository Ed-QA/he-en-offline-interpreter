import Foundation
import SwiftUI

extension Pipeline {

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
