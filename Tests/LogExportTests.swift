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
}
