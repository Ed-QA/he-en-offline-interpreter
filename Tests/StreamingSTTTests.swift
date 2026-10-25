import XCTest
@testable import HEENInterpreter

/// Real offline STT inside the simulator: a Hebrew WAV (generated on the macOS runner with
/// the built-in Hebrew voice) is streamed through the bundled Zipformer2 transducer.
/// If the runner has no Hebrew voice or the model is missing, the test skips loudly.
final class StreamingSTTTests: XCTestCase {

    private func fixture() -> URL? {
        Bundle.main.url(forResource: "test-hebrew", withExtension: "wav", subdirectory: "Model")
            ?? Bundle.main.url(forResource: "test-hebrew", withExtension: "wav")
    }

    func testModelIsBundled() {
        let missing = SherpaStreamingSTT.missingFiles()
        XCTAssertTrue(missing.isEmpty,
                      "STT model not in the app bundle: \(missing.joined(separator: ", "))")
    }

    func testRecognizesHebrewFromFile() throws {
        try XCTSkipIf(!SherpaStreamingSTT.missingFiles().isEmpty,
                      "STT model not bundled — run Tools/prepare_stt.py")
        guard let url = fixture() else {
            throw XCTSkip("no Hebrew audio fixture (macOS Hebrew voice unavailable)")
        }

        let stt = SherpaStreamingSTT(input: FileAudioInput(url: url))
        var heard = ""

        stt.onPartial = { text in
            if text.count > heard.count { heard = text }
        }
        stt.onEndpoint = { text in
            if text.count > heard.count { heard = text }
        }

        try stt.start()
        // The fixture is replayed at real-time speed (100 ms chunks). A streaming transducer
        // only raises an endpoint when it sees trailing silence and `say` writes none, so the
        // transcript is collected until it stops growing instead of waiting for a signal that
        // may never arrive. The run loop must be pumped, otherwise the timers never fire.
        let deadline = Date().addingTimeInterval(60)
        var previous = ""
        var lastGrowth = Date()
        while Date() < deadline {
            if heard != previous {
                previous = heard
                lastGrowth = Date()
            }
            if !heard.isEmpty, Date().timeIntervalSince(lastGrowth) > 4 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        stt.stop()

        print("HEARD: \(heard)")
        XCTAssertFalse(heard.isEmpty, "the recogniser produced no text for the fixture")
        let letters = heard.filter { $0.unicodeScalars.first.map { $0.value >= 0x05D0 && $0.value <= 0x05EA } ?? false }
        XCTAssertGreaterThan(letters.count, 3,
                             "recognised text does not look like Hebrew: '\(heard)'")
        // The recogniser is not expected to point the text: nikud is added downstream by the
        // phonikud diacritizer (`Sources/Nikud.swift`) and only the pointed sentence is
        // translated — see `Pipeline.processQueue`.
    }
}
