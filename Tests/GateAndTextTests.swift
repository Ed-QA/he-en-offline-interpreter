import XCTest
@testable import HEENInterpreter

/// Pure-logic gate/text tests. These run in the iOS Simulator (CI: macos runner) â€” never on
/// the phone â€” and pin the behaviours that were reported as bugs on device.
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
        XCTAssertTrue(TextUtil.hasModelArtifacts("â–Hello"))
        XCTAssertFalse(TextUtil.hasModelArtifacts("Hello world"))
    }

    // MARK: - Item 5: the TTS must never speak the same words twice

    func testRemovePrefixStripsAlreadySpokenWords() {
        XCTAssertEqual(TextUtil.removePrefix("×× ×™ ×¨×•×¦×” ×œ×©×ª×•×ª ×§×¤×” ×¢×›×©×™×•", prefix: "×× ×™ ×¨×•×¦×” ×œ×©×ª×•×ª"), "×§×¤×” ×¢×›×©×™×•")
        XCTAssertEqual(TextUtil.removePrefix("×× ×™ ×¨×•×¦×”", prefix: "×× ×™ ×¨×•×¦×” ×œ×©×ª×•×ª"), "×× ×™ ×¨×•×¦×”")
        XCTAssertEqual(TextUtil.removePrefix("×©×œ×•×", prefix: ""), "×©×œ×•×")
    }

    func testGrowingEmitOnlyYieldsTheNewTail() {
        let first = "×©×œ×•× ×œ×›×•×œ×"
        let grown = "×©×œ×•× ×œ×›×•×œ× ×ž×” ×©×œ×•×ž×›×"
        XCTAssertEqual(TextUtil.removePrefix(grown, prefix: first), "×ž×” ×©×œ×•×ž×›×")
        XCTAssertEqual(TextUtil.removePrefix(grown, prefix: grown), "")
    }

    // MARK: - Overlap merge (streaming STT re-sends the whole utterance)

    func testMergeOverlap() {
        XCTAssertEqual(TextUtil.mergeOverlap("×©×œ×•× ×œ×›×•×œ×", "×œ×›×•×œ× ×ž×” ×©×œ×•×ž×›×"), "×©×œ×•× ×œ×›×•×œ× ×ž×” ×©×œ×•×ž×›×")
        XCTAssertEqual(TextUtil.mergeOverlap("", "×©×œ×•×"), "×©×œ×•×")
        XCTAssertEqual(TextUtil.mergeOverlap("×©×œ×•×", ""), "×©×œ×•×")
    }

    // MARK: - Gate: nothing is spoken before it is sense-complete

    func testGateEmitsCompleteSentence() {
        let gate = HebrewCompletenessGate()
        let outcome = gate.evaluate("×× ×™ ×¨×•×¦×” ×œ×§× ×•×ª ×œ×—× ×ž×—×¨ ×‘×‘×•×§×¨.",
                                    trailingSilence: 1.0, isSTTFinal: true, pendingAge: 1.0)
        XCTAssertTrue(outcome.emit, "complete sentence must emit (reason: \(outcome.reason))")
        XCTAssertFalse(outcome.forced)
    }

    func testGateHoldsDanglingPreposition() {
        let gate = HebrewCompletenessGate()
        let outcome = gate.evaluate("×× ×™ ×¨×•×¦×” ×œ×©×ª×•×ª ×¢×",
                                    trailingSilence: 1.0, isSTTFinal: false, pendingAge: 0.5)
        XCTAssertFalse(outcome.emit, "a sentence ending on a preposition must be held back")
    }

    func testGateForcesAfterMaxPendingAge() {
        let gate = HebrewCompletenessGate()
        let outcome = gate.evaluate("×× ×™ ×¨×•×¦×” ×œ×©×ª×•×ª ×¢×",
                                    trailingSilence: 0.5, isSTTFinal: false, pendingAge: 30)
        XCTAssertTrue(outcome.emit)
        XCTAssertTrue(outcome.forced)
    }

    func testGateNeverEmitsEmptyText() {
        let gate = HebrewCompletenessGate()
        XCTAssertFalse(gate.evaluate("   ", trailingSilence: 5, isSTTFinal: true, pendingAge: 5).emit)
    }
}
