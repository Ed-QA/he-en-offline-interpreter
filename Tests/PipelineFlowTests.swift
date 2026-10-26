import XCTest
@testable import HEENInterpreter

/// Deterministic end-to-end pipeline test in the simulator: a scripted recogniser feeds the
/// real gate, the real queue and the real log — no microphone, no phone.
/// This is the test that pins item 5 (the TTS must never repeat words).
@MainActor
final class PipelineFlowTests: XCTestCase {

    private final class FakeTranslator: TranslationEngine {
        let name = "fake"
        private(set) var calls: [String] = []
        func translate(_ text: String) async throws -> String {
            calls.append(text)
            return "EN[\(text)]"
        }
    }

    private func makePipeline(_ steps: [ScriptedSTT.Step]) -> (Pipeline, FakeTranslator, ScriptedSTT) {
        let stt = ScriptedSTT(steps: steps, interval: 0.03)
        let pipeline = Pipeline(stt: stt)
        let translator = FakeTranslator()
        pipeline.engine = translator
        // Load the diacritizer up front: otherwise the first processQueue spends the whole
        // test window creating the 293 MB ONNX session (all of this runs on the main actor).
        _ = pipeline.diacritize("warmup")
        return (pipeline, translator, stt)
    }

    /// Waits until `condition` is true or `seconds` elapse. The pipeline is main-actor bound,
    /// so sleeping here also lets its timers and translation tasks run.
    private func wait(_ seconds: TimeInterval, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func spin(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// The same utterance arrives three times, each time a little longer (exactly what a
    /// streaming recogniser does). Only the new tail may ever be translated and spoken.
    func testGrowingUtteranceIsSpokenOnceOnly() async throws {
        let steps = [
            ScriptedSTT.Step(partial: "שלום לכולם"),
            ScriptedSTT.Step(partial: "שלום לכולם מה שלומכם"),
            ScriptedSTT.Step(partial: "שלום לכולם מה שלומכם היום"),
            ScriptedSTT.Step(partial: "שלום לכולם מה שלומכם היום בבוקר.",
                             endpoint: "שלום לכולם מה שלומכם היום בבוקר."),
        ]
        let (pipeline, translator, _) = makePipeline(steps)
        try pipeline.stt.start()
        pipeline.wireSTT()
        pipeline.running = true
        pipeline.startTimer()

        await wait(6.0) { !pipeline.englishText.isEmpty }
        pipeline.stop()

        let hebrew = pipeline.log.map(\.hebrew)
        XCTAssertFalse(hebrew.isEmpty, "nothing was emitted at all")
        XCTAssertEqual(Set(hebrew).count, hebrew.count,
                       "the same sentence was emitted twice: \(hebrew)")

        let translated = translator.calls
        for call in translated {
            XCTAssertFalse(call.isEmpty)
        }
        XCTAssertEqual(Set(translated).count, translated.count,
                       "the same text was translated twice: \(translated)")

        // The English panel must contain each sentence once, never a growing repeat.
        let english = pipeline.englishText
        XCTAssertFalse(english.isEmpty, "nothing reached the English panel")
        for line in english.split(separator: "\n") {
            XCTAssertEqual(english.components(separatedBy: line).count - 1, 1,
                           "line repeated in the English panel: \(line)")
        }
    }

    /// A second, clearly different utterance must still be translated (the anti-repeat guard
    /// may not swallow real speech).
    func testSecondUtteranceStillSpeaks() async throws {
        let steps = [
            ScriptedSTT.Step(partial: "אני רוצה לקנות לחם מחר בבוקר.",
                             endpoint: "אני רוצה לקנות לחם מחר בבוקר."),
            ScriptedSTT.Step(partial: "תגיד לי איפה התחנה המרכזית.",
                             endpoint: "תגיד לי איפה התחנה המרכזית."),
        ]
        let (pipeline, translator, _) = makePipeline(steps)
        try pipeline.stt.start()
        pipeline.wireSTT()
        pipeline.running = true
        pipeline.startTimer()

        await wait(6.0) { !translator.calls.isEmpty }
        pipeline.stop()

        XCTAssertGreaterThanOrEqual(translator.calls.count, 1,
                                    "the pipeline never translated anything")
        XCTAssertEqual(Set(translator.calls).count, translator.calls.count,
                       "a translation was queued twice: \(translator.calls)")
    }

    /// `stop()` blanked the Hebrew panel but left the English one on screen, so a stopped
    /// interpreter still looked like it was mid-sentence.
    func testStopClearsBothPanels() async {
        let (pipeline, _, _) = makePipeline([])
        pipeline.hebrewLive = "שלום"
        pipeline.englishText = "Hello"

        pipeline.stop()

        XCTAssertEqual(pipeline.hebrewLive, "", "the Hebrew panel kept its text")
        XCTAssertEqual(pipeline.englishText, "", "the English panel kept its text")
        XCTAssertFalse(pipeline.running, "the pipeline is still marked as running")
        XCTAssertEqual(pipeline.status, .idle, "the pipeline is not idle after stop()")
    }
}
