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
        XCTAssertTrue(TextUtil.hasModelArtifacts("\u{2581}Hello"))   // SentencePiece underline
        XCTAssertFalse(TextUtil.hasModelArtifacts("Hello world"))
    }

    // MARK: - Item 5: the TTS must never speak the same words twice

    func testRemovePrefixStripsAlreadySpokenWords() {
        XCTAssertEqual(TextUtil.removePrefix("×× ×™ ×¨×•×¦×” ×œ×©×ª×•×ª ×§×¤×” ×¢×›×©×™×•",
                                             prefix: "×× ×™ ×¨×•×¦×” ×œ×©×ª×•×ª"),
                       "×§×¤×” ×¢×›×©×™×•")
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
        XCTAssertEqual(TextUtil.mergeOverlap("×©×œ×•× ×œ×›×•×œ×", "×œ×›×•×œ× ×ž×” ×©×œ×•×ž×›×"),
                       "×©×œ×•× ×œ×›×•×œ× ×ž×” ×©×œ×•×ž×›×")
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

    /// Item 2: the overlap-removal tool. The two recogniser streams (and every partial they send)
    /// repeat each other's tail â€” the repeated words are dropped and only the new tail is kept.
    func testOverlapRemovalDropsRepeatedWords() {
        XCTAssertEqual(TextUtil.dropOverlap(previous: "×©×œ×•× ×ž×” ×©×œ×•×ž×š", next: "×ž×” ×©×œ×•×ž×š ×”×™×•×"),
                       "×”×™×•×")
        XCTAssertEqual(TextUtil.dropOverlap(previous: "×©×œ×•×", next: "×©×œ×•×"), "")
        XCTAssertEqual(TextUtil.dropOverlap(previous: "×©×œ×•×", next: "×ž×” ×©×œ×•×ž×š"), "×ž×” ×©×œ×•×ž×š")
        XCTAssertEqual(TextUtil.dropOverlap(previous: "", next: "×ž×” ×©×œ×•×ž×š"), "×ž×” ×©×œ×•×ž×š")
    }

    /// Items 4 and 5: the points are what the Hebrew panel shows, and exactly what the translator
    /// must never receive â€” it was trained on unpointed Hebrew.
    func testNikudIsStrippedForTranslationOnly() {
        XCTAssertEqual(TextUtil.stripNikud("×©×œ×•×\u{05B8}\u{05B0}"), "×©×œ×•×")
        XCTAssertEqual(TextUtil.stripNikud("×ž×”\u{05B7} ×©×œ×•×ž×š\u{05BC}"), "×ž×” ×©×œ×•×ž×š")
        XCTAssertEqual(TextUtil.stripNikud("×©×œ×•×"), "×©×œ×•×")
    }

    /// The two lanes point the shared 0.3 s independently, so the same word comes back as
    /// `×©Ö¸××œ×•Ö¹×` from one lane and `×©×œ×•×` from the other. Compared raw the overlap is invisible and
    /// the word is spoken twice; the clearer has to compare the bare form.
    func testOverlapRemovalIsNotFooledByNikud() {
        XCTAssertEqual(TextUtil.dropOverlap(previous: "×©Ö¸××œ×•Ö¹× ×žÖ¸×” ×©Ö°××œ×•Ö¹×žÖ°×šÖ¸",
                                            next: "×ž×” ×©×œ×•×ž×š ×”×™×•×"), "×”×™×•×")
        XCTAssertEqual(TextUtil.dropOverlap(previous: "×©×œ×•× ×ž×” ×©×œ×•×ž×š",
                                            next: "×©Ö¸××œ×•Ö¹× ×žÖ¸×” ×©Ö°××œ×•Ö¹×žÖ°×šÖ¸"), "")
        XCTAssertEqual(TextUtil.mergeOverlap("×©Ö¸××œ×•Ö¹× ×žÖ¸×”", "×ž×” ×©Ö°××œ×•Ö¹×žÖ°×šÖ¸"), "×©Ö¸××œ×•Ö¹× ×žÖ¸×” ×©Ö°××œ×•Ö¹×žÖ°×šÖ¸")
        XCTAssertEqual(TextUtil.removePrefix("×©Ö¸××œ×•Ö¹× ×žÖ¸×” ×©Ö°××œ×•Ö¹×žÖ°×šÖ¸", prefix: "×©×œ×•× ×ž×”"), "×©Ö°××œ×•Ö¹×žÖ°×šÖ¸")
        XCTAssertTrue(TextUtil.sameWord("×©Ö¸××œ×•Ö¹×", "×©×œ×•×"))
        XCTAssertFalse(TextUtil.sameWord("×©×œ×•×", "×©×œ×•×ž×”"))
    }

    /// The completeness rules are written unpointed. A pointed sentence must hit the same rules:
    /// a dangling connector may not be emitted as complete, and a finished pointed sentence must be.
    func testTheGateAppliesItsHebrewRulesToPointedText() {
        let gate = HebrewCompletenessGate()
        let dangling = gate.evaluate("×Ö²× Ö´×™ ×¨×•Ö¹×¦Ö¶×” ×œÖ¸×œÖ¶×›Ö¶×ª ×Ö¶×œ",
                                     trailingSilence: 0, isSTTFinal: false, pendingAge: 0)
        XCTAssertFalse(dangling.emit,
                       "a pointed sentence ending in a connector was called complete: \(dangling)")
        let finished = gate.evaluate("×Ö²× Ö´×™ ×¨×•Ö¹×¦Ö¶×” ×œÖ¸×œÖ¶×›Ö¶×ª ×”Ö·×‘Ö·Ö¼×™Ö°×ªÖ¸×”.",
                                     trailingSilence: 0, isSTTFinal: false, pendingAge: 0)
        XCTAssertTrue(finished.emit, "a finished pointed sentence was not emitted: \(finished)")
        let prefix = gate.evaluate("×Ö²× Ö´×™ ×¨×•Ö¹×¦Ö¶×” ×œÖ¸×œÖ¶×›Ö¶×ª ×•Ö°",
                                   trailingSilence: 0, isSTTFinal: true, pendingAge: 0)
        XCTAssertFalse(prefix.emit, "a bare pointed prefix ended a sentence: \(prefix)")
    }

    /// Item 5: the translator's input contract is pointed Hebrew. The points survive wherever the
    /// model's own vocabulary can carry them; only a word the points would shatter falls back to
    /// its unpointed form â€” and that decision is made by the engine, not by the pipeline.
    func testNikudAwareTranslatorInput() {
        let pointed = "×©×œ×•×\u{05B8} ×ž×”\u{05B7} ×©×œ×•×ž×š\u{05BC}"
        // A vocabulary that can carry the points: every word keeps them.
        XCTAssertEqual(NikudAwareInput.prepare(pointed) { _ in 1 }, pointed)
        // A vocabulary that fragments pointed words: those words fall back to the unpointed form.
        XCTAssertEqual(NikudAwareInput.prepare(pointed) { NikudAwareInput.hasNikud($0) ? 9 : 1 },
                       "×©×œ×•× ×ž×” ×©×œ×•×ž×š")
        // Unpointed input is passed through untouched.
        XCTAssertEqual(NikudAwareInput.prepare("×ž×” ×©×œ×•×ž×š") { _ in 1 }, "×ž×” ×©×œ×•×ž×š")
        XCTAssertTrue(NikudAwareInput.hasNikud("×©×œ×•×\u{05B8}"))
        XCTAssertFalse(NikudAwareInput.hasNikud("×©×œ×•×"))
    }
}
