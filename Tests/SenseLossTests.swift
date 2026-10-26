import XCTest
@testable import HEENInterpreter

/// Regressions for the ways the interpreter could silently swallow what the speaker said.
/// Every test is driven through the real gate, the real queue and the real log, with a scripted
/// recogniser and a fake translator - no microphone, no phone, no model download.
@MainActor
final class SenseLossTests: XCTestCase {

    private final class EchoTranslator: TranslationEngine {
        let name = "echo"
        private(set) var calls: [String] = []
        func translate(_ text: String) async throws -> String {
            calls.append(text)
            return "EN[\(text)]"
        }
    }

    private func makePipeline() -> (Pipeline, EchoTranslator, ScriptedSTT) {
        let stt = ScriptedSTT(steps: [], interval: 0.05)
        stt.silenceDuration = 2.0   // an unmistakable pause: the gate's pause evidence is present
        let pipeline = Pipeline(stt: stt)
        let translator = EchoTranslator()
        pipeline.engine = translator
        // Build the 293 MB diacritizer session before the assertions: it is created on first use.
        _ = pipeline.diacritize("warmup")
        pipeline.wireSTT()
        return (pipeline, translator, stt)
    }

    private func wait(_ seconds: TimeInterval, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// A one-word answer ("כן", "תודה", "מים") is a complete utterance. It used to be dropped
    /// twice over: the gate scored short finals below threshold, and `evaluate` refused
    /// anything under two tokens.
    func testOneWordAnswerIsTranslated() async {
        let (pipeline, translator, _) = makePipeline()
        pipeline.handleEndpoint("כן")
        await wait(3.0) { !translator.calls.isEmpty }
        XCTAssertEqual(pipeline.log.count, 1, "a one-word answer produced no log entry")
        XCTAssertEqual(translator.calls, ["כן"], "a one-word answer was never translated")
    }

    /// Two sentences that finish while the speaker is still talking must both reach the TTS.
    /// The single `pendingSpeech` slot overwrote the first one: it was shown but never spoken.
    func testBothSentencesReachTheSpeaker() async {
        let (pipeline, translator, _) = makePipeline()
        pipeline.handleEndpoint("אני רוצה לקנות לחם מחר בבוקר.")
        await wait(3.0) { translator.calls.count == 1 }
        pipeline.handleEndpoint("תגיד לי איפה התחנה המרכזית.")
        await wait(3.0) { translator.calls.count == 2 }

        XCTAssertEqual(pipeline.speechQueue,
                       ["EN[אני רוצה לקנות לחם מחר בבוקר.]", "EN[תגיד לי איפה התחנה המרכזית.]"],
                       "a translated sentence never made it into the speech queue")

        // One tick hands exactly the head of the queue to the synthesizer and keeps the rest.
        pipeline.running = true
        pipeline.tick()
        XCTAssertEqual(pipeline.speechQueue, ["EN[תגיד לי איפה התחנה המרכזית.]"],
                       "tick() did not hand over exactly one sentence")
    }

    /// The same words said again in a *new* utterance are new speech: they must not be stripped
    /// as if they were an echo of the previous sentence, and the anti-repeat memory must not
    /// swallow them either.
    func testRepeatedSentenceInANewUtteranceIsSpokenAgain() async {
        let (pipeline, translator, _) = makePipeline()
        pipeline.handleEndpoint("תודה רבה")
        await wait(3.0) { translator.calls.count == 1 }
        pipeline.handleEndpoint("תודה רבה")
        await wait(3.0) { translator.calls.count == 2 }
        XCTAssertEqual(translator.calls, ["תודה רבה", "תודה רבה"],
                       "the second utterance was swallowed as a repeat: \(translator.calls)")
        XCTAssertEqual(pipeline.speechQueue.count, 2, "the repeat was never queued for speech")
    }

    /// The diacritizer reads at most 2046 characters, so a long monologue is split. The split
    /// must land on a word boundary: half a word is a word the translator never sees.
    func testLongMonologueIsSplitOnWordBoundaries() {
        let words = (0..<600).map { "מילה\($0)" }
        let text = words.joined(separator: " ")
        let chunks = NikudRestorer.chunks(of: text)
        XCTAssertGreaterThan(chunks.count, 1, "a 4000+ character text must be split")
        XCTAssertEqual(chunks.joined(), text, "splitting lost or changed characters")
        for chunk in chunks.dropLast() {
            XCTAssertTrue(chunk.hasSuffix(" "), "a chunk ends mid-word: [\(chunk.suffix(10))]")
        }
        XCTAssertEqual(chunks.joined().split(separator: " ").count, words.count,
                       "the word count changed across the split")
    }

    /// Sanity check on the same split path: a text that fits is returned untouched.
    func testShortTextIsNotSplit() {
        let text = "אני רוצה לקנות לחם מחר בבוקר."
        XCTAssertEqual(NikudRestorer.chunks(of: text), [text])
    }
}
