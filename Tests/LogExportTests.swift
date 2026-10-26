import XCTest
@testable import HEENInterpreter

/// The "send logs" report is a product feature (people mail it or drop it into a chat), so its
/// shape is pinned: header, device and model state, the conversation and the live trace in one
/// self-contained text file.
@MainActor
final class LogExportTests: XCTestCase {

    private func wait(_ seconds: TimeInterval, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testReportCarriesDeviceStateConversationAndTrace() async {
        let pipeline = Pipeline(stt: ScriptedSTT(steps: []))
        pipeline.engineStatus = "unit-test engine"
        pipeline.sttStatus = "unit-test speech"
        pipeline.log = [LogEntry(date: Date(), hebrew: "שלום", english: "Hello", forced: false),
                        LogEntry(date: Date(), hebrew: "תודה", english: "", forced: true)]

        // The trace is written on its own queue: wait until the marker really is on disk.
        Pipeline.trace("unit-test-trace-marker")
        await wait(5.0) { Pipeline.traceTail().contains("unit-test-trace-marker") }

        let report = pipeline.logText()
        XCTAssertTrue(report.contains("HE-EN OFFLINE INTERPRETER"), "the report header is missing")
        XCTAssertTrue(report.contains("== device =="), "the device block is missing")
        XCTAssertTrue(report.contains("unit-test engine"), "the engine state is missing")
        XCTAssertTrue(report.contains("unit-test speech"), "the speech state is missing")
        XCTAssertTrue(report.contains("gate balanced"), "the gate mode is missing")
        XCTAssertTrue(report.contains("nikud: "), "the diacritizer state is missing")
        XCTAssertTrue(report.contains("== conversation (2) =="), "the conversation count is wrong")
        XCTAssertTrue(report.contains("HE: שלום") && report.contains("EN: Hello"),
                      "a conversation line is missing")
        XCTAssertTrue(report.contains("(incomplete)"), "the forced-chunk marker is missing")
        XCTAssertTrue(report.contains("== trace"), "the trace block is missing")
        XCTAssertTrue(report.contains("unit-test-trace-marker"),
                      "the report does not include the live trace")
    }

    func testWriteLogFileProducesAShareableTextFile() throws {
        let pipeline = Pipeline(stt: ScriptedSTT(steps: []))
        pipeline.engineStatus = "unit-test engine"
        let url = try XCTUnwrap(pipeline.writeLogFile(), "writeLogFile() returned nil")

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the report file was not written")
        XCTAssertEqual(url.pathExtension, "txt", "the report is not a plain text file")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("log-"),
                      "unexpected report name: \(url.lastPathComponent)")

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertGreaterThan(content.count, 100, "the report is suspiciously small")
        XCTAssertTrue(content.contains("unit-test engine"), "the report has no engine state")
        XCTAssertNil(pipeline.lastError, "writing the report reported an error")

        try? FileManager.default.removeItem(at: url)
    }

    /// The session marker printed `[(stamp)]` instead of a time — a double-escaped string in
    /// `resetTrace()`. A pulled log has to start with a real timestamp.
    func testSessionMarkerIsARealTimestamp() async {
        Pipeline.resetTrace()
        await wait(5.0) { Pipeline.traceTail().contains("===== new session =====") }

        let line = Pipeline.traceTail()
            .split(separator: "\n")
            .first { $0.contains("===== new session =====") }
            .map(String.init) ?? ""
        XCTAssertFalse(line.isEmpty, "the session marker never reached the trace")
        XCTAssertFalse(line.contains("\\("), "the session marker is double-escaped: \(line)")
        XCTAssertTrue(line.hasPrefix("["), "the session marker has no timestamp: \(line)")
        XCTAssertTrue(line.contains("]"), "the session marker has no closing bracket: \(line)")
    }

    /// Documents is user-visible in Files and every open of the log screen writes a report, so
    /// only the newest few may survive.
    func testOldReportsArePruned() throws {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fm = FileManager.default
        for i in 0..<5 {
            let old = dir.appendingPathComponent("log-2020010\(i)-12000\(i).txt")
            try "old report \(i)".write(to: old, atomically: true, encoding: .utf8)
        }

        let pipeline = Pipeline(stt: ScriptedSTT(steps: []))
        let fresh = try XCTUnwrap(pipeline.writeLogFile(), "writeLogFile() returned nil")

        let remaining = (try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
            .filter { $0.lastPathComponent.hasPrefix("log-") && $0.pathExtension == "txt" }
        XCTAssertLessThanOrEqual(remaining.count, 3,
                                 "old reports were not pruned: \(remaining.map(\.lastPathComponent))")
        XCTAssertTrue(remaining.contains(fresh), "the newest report was pruned away")

        for url in remaining { try? fm.removeItem(at: url) }
    }
}
