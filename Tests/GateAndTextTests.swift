import XCTest
@testable import HEENInterpreter

/// Pure-logic gate/text tests. These run in the iOS Simulator (CI: macos runner) — never on
/// the phone — and pin the behaviours that were reported as bugs on device.
final class GateAndTextTests: XCTestCase {

    // MARK: - Item 6: control tokens must never reach the screen or the TTS

    func testSanitizeRemovesControlTokens() {
        XCTAssertEqual(TextUtil.sanitizeTranslation("Hello <pad> world"), "Hello world")
        XCTAssertEqual(TextUtil.sanitizeTranslation("<s> Hello there </s>"), "Hello there")
        XCTAssertEqual(TextUtil.sanitizeTranslation("Hello <unk>"), "Hello")
        XCTAssertEqual(TextUtil.sanitizeTranslation("Hi <0xE2><0x80> there"), "Hi there")
        XCTAssertEqual(TextUtil.sanitizeTranslation("<pad><pad><unk>"), "")
    }

    func testSanitizeTidiesSpacing() {
        XCTAssertEqual(TextUtil.sanitizeTranslation("Hello   world ,  friend ."), "Hello world, friend.")
    }

    func testSanitizeKeepsPlainEnglishIntact() {
        XCTAssertEqual(TextUtil.sanitizeTranslation("I want to go home."), "I want to go home.")
    }

    func testArtifactDetector() {
        XCTAssertTrue(TextUtil.hasModelArtifacts("Hello <pad>"))
        XCTAssertTrue(TextUtil.hasModelArtifacts("▁Hello"))
        XCTAssertFalse(TextUtil.hasModelArtifacts("Hello world"))
    }

    // MARK: - STT contract: Hebrew transcripts are never pointed (no nikud)

    func testStripNikudRemovesPointsAndCantillation() {
        // "shalom" spelled with qamats + shin-dot + holam
        XCTAssertEqual(TextUtil.stripNikud("ש\u{05B8}\u{05C1}לו\u{05B9}ם"), "שלום")
        // the exact failure the model produces: a standalone dagesh token glued onto a letter
        XCTAssertEqual(TextUtil.stripNikud("של\u{05BC}ום"), "שלום")
        // mixed points, spaces and letters survive as words
        XCTAssertEqual(TextUtil.stripNikud("ע\u{05B7}ל \u{05B0}ה\u{05E9}\u{05C1}\u{05B8}\u{05E2}\u{05B7}ר"), "על השער")
        XCTAssertEqual(TextUtil.stripNikud("ש\u{05B8}לו\u{05B9}ם ע\u{05D5}\u{05B9}ל\u{05B8}ם"), "שלום עולם")
    }

    func testStripNikudLeavesCleanTextAlone() {
        XCTAssertEqual(TextUtil.stripNikud("מה שלומך? 12"), "מה שלומך? 12")
        XCTAssertEqual(TextUtil.stripNikud("Hello שלום"), "Hello שלום")
        XCTAssertEqual(TextUtil.stripNikud(""), "")
        // maqaf (U+05BE) is punctuation, not nikud — it must survive
        XCTAssertEqual(TextUtil.stripNikud("בית\u{05BE}ספר"), "בית\u{05BE}ספר")
    }

    func testStripNikudIsIdempotent() {
        let once = TextUtil.stripNikud("ש\u{05B8}לו\u{05B9}ם")
        XCTAssertEqual(TextUtil.stripNikud(once), once)
    }

    func testGateSeesUnpointedWords() {
        // The gate's word sets are unpointed, so pointed text must never reach it: a pointed
        // "של" (dangling preposition) has to be held back exactly like the plain one.
        let gate = HebrewCompletenessGate()
        let outcome = gate.evaluate(TextUtil.stripNikud("אני רוצה לשתות עם\u{05B8}"),
                                    trailingSilence: 1.0, isSTTFinal: false, pendingAge: 0.5)
        XCTAssertFalse(outcome.emit)
    }

    // MARK: - Item 5: the TTS must never speak the same words twice

    func testRemovePrefixStripsAlreadySpokenWords() {
        XCTAssertEqual(TextUtil.removePrefix("אני רוצה לשתות קפה עכשיו", prefix: "אני רוצה לשתות"), "קפה עכשיו")
        XCTAssertEqual(TextUtil.removePrefix("אני רוצה", prefix: "אני רוצה לשתות"), "אני רוצה")
        XCTAssertEqual(TextUtil.removePrefix("שלום", prefix: ""), "שלום")
    }

    func testGrowingEmitOnlyYieldsTheNewTail() {
        let first = "שלום לכולם"
        let grown = "שלום לכולם מה שלומכם"
        XCTAssertEqual(TextUtil.removePrefix(grown, prefix: first), "מה שלומכם")
        XCTAssertEqual(TextUtil.removePrefix(grown, prefix: grown), "")
    }

    // MARK: - Overlap merge (streaming STT re-sends the whole utterance)

    func testMergeOverlap() {
        XCTAssertEqual(TextUtil.mergeOverlap("שלום לכולם", "לכולם מה שלומכם"), "שלום לכולם מה שלומכם")
        XCTAssertEqual(TextUtil.mergeOverlap("", "שלום"), "שלום")
        XCTAssertEqual(TextUtil.mergeOverlap("שלום", ""), "שלום")
    }

    // MARK: - Gate: nothing is spoken before it is sense-complete

    func testGateEmitsCompleteSentence() {
        let gate = HebrewCompletenessGate()
        let outcome = gate.evaluate("אני רוצה לקנות לחם מחר בבוקר.",
                                    trailingSilence: 1.0, isSTTFinal: true, pendingAge: 1.0)
        XCTAssertTrue(outcome.emit, "complete sentence must emit (reason: \(outcome.reason))")
        XCTAssertFalse(outcome.forced)
    }

    func testGateHoldsDanglingPreposition() {
        let gate = HebrewCompletenessGate()
        let outcome = gate.evaluate("אני רוצה לשתות עם",
                                    trailingSilence: 1.0, isSTTFinal: false, pendingAge: 0.5)
        XCTAssertFalse(outcome.emit, "a sentence ending on a preposition must be held back")
    }

    func testGateForcesAfterMaxPendingAge() {
        let gate = HebrewCompletenessGate()
        let outcome = gate.evaluate("אני רוצה לשתות עם",
                                    trailingSilence: 0.5, isSTTFinal: false, pendingAge: 30)
        XCTAssertTrue(outcome.emit)
        XCTAssertTrue(outcome.forced)
    }

    func testGateNeverEmitsEmptyText() {
        let gate = HebrewCompletenessGate()
        XCTAssertFalse(gate.evaluate("   ", trailingSilence: 5, isSTTFinal: true, pendingAge: 5).emit)
    }
}
