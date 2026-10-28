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
        XCTAssertTrue(TextUtil.hasModelArtifacts("\u{2581}Hello"))   // SentencePiece underline
        XCTAssertFalse(TextUtil.hasModelArtifacts("Hello world"))
    }

    // MARK: - Item 5: the TTS must never speak the same words twice

    func testRemovePrefixStripsAlreadySpokenWords() {
        XCTAssertEqual(TextUtil.removePrefix("אני רוצה לשתות קפה עכשיו",
                                             prefix: "אני רוצה לשתות"),
                       "קפה עכשיו")
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
        XCTAssertEqual(TextUtil.mergeOverlap("שלום לכולם", "לכולם מה שלומכם"),
                       "שלום לכולם מה שלומכם")
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

    /// Item 2: the overlap-removal tool. The two recogniser streams (and every partial they send)
    /// repeat each other's tail — the repeated words are dropped and only the new tail is kept.
    func testOverlapRemovalDropsRepeatedWords() {
        XCTAssertEqual(TextUtil.dropOverlap(previous: "שלום מה שלומך", next: "מה שלומך היום"),
                       "היום")
        XCTAssertEqual(TextUtil.dropOverlap(previous: "שלום", next: "שלום"), "")
        XCTAssertEqual(TextUtil.dropOverlap(previous: "שלום", next: "מה שלומך"), "מה שלומך")
        XCTAssertEqual(TextUtil.dropOverlap(previous: "", next: "מה שלומך"), "מה שלומך")
    }

    /// Items 4 and 5: the points are what the Hebrew panel shows, and exactly what the translator
    /// must never receive — it was trained on unpointed Hebrew.
    func testNikudIsStrippedForTranslationOnly() {
        XCTAssertEqual(TextUtil.stripNikud("שלום\u{05B8}\u{05B0}"), "שלום")
        XCTAssertEqual(TextUtil.stripNikud("מה\u{05B7} שלומך\u{05BC}"), "מה שלומך")
        XCTAssertEqual(TextUtil.stripNikud("שלום"), "שלום")
    }

    /// The two lanes point the shared 0.3 s independently, so the same word comes back as
    /// `שָׁלוֹם` from one lane and `שלום` from the other. Compared raw the overlap is invisible and
    /// the word is spoken twice; the clearer has to compare the bare form.
    func testOverlapRemovalIsNotFooledByNikud() {
        XCTAssertEqual(TextUtil.dropOverlap(previous: "שָׁלוֹם מָה שְׁלוֹמְךָ",
                                            next: "מה שלומך היום"), "היום")
        XCTAssertEqual(TextUtil.dropOverlap(previous: "שלום מה שלומך",
                                            next: "שָׁלוֹם מָה שְׁלוֹמְךָ"), "")
        XCTAssertEqual(TextUtil.mergeOverlap("שָׁלוֹם מָה", "מה שְׁלוֹמְךָ"), "שָׁלוֹם מָה שְׁלוֹמְךָ")
        XCTAssertEqual(TextUtil.removePrefix("שָׁלוֹם מָה שְׁלוֹמְךָ", prefix: "שלום מה"), "שְׁלוֹמְךָ")
        XCTAssertTrue(TextUtil.sameWord("שָׁלוֹם", "שלום"))
        XCTAssertFalse(TextUtil.sameWord("שלום", "שלומה"))
    }

    /// The completeness rules are written unpointed. A pointed sentence must hit the same rules:
    /// a dangling connector may not be emitted as complete, and a finished pointed sentence must be.
    func testTheGateAppliesItsHebrewRulesToPointedText() {
        let gate = HebrewCompletenessGate(mode: .balanced)
        let dangling = gate.evaluate("אֲנִי רוֹצֶה לָלֶכֶת אֶל",
                                     trailingSilence: 0, isSTTFinal: false, pendingAge: 0)
        XCTAssertFalse(dangling.emit,
                       "a pointed sentence ending in a connector was called complete: \(dangling)")
        let finished = gate.evaluate("אֲנִי רוֹצֶה לָלֶכֶת הַבַּיְתָה.",
                                     trailingSilence: 0, isSTTFinal: false, pendingAge: 0)
        XCTAssertTrue(finished.emit, "a finished pointed sentence was not emitted: \(finished)")
        let prefix = gate.evaluate("אֲנִי רוֹצֶה לָלֶכֶת וְ",
                                   trailingSilence: 0, isSTTFinal: true, pendingAge: 0)
        XCTAssertFalse(prefix.emit, "a bare pointed prefix ended a sentence: \(prefix)")
    }

    /// Item 5: the translator's input contract is pointed Hebrew. The points survive wherever the
    /// model's own vocabulary can carry them; only a word the points would shatter falls back to
    /// its unpointed form — and that decision is made by the engine, not by the pipeline.
    func testNikudAwareTranslatorInput() {
        let pointed = "שלום\u{05B8} מה\u{05B7} שלומך\u{05BC}"
        // A vocabulary that can carry the points: every word keeps them.
        XCTAssertEqual(NikudAwareInput.prepare(pointed) { _ in 1 }, pointed)
        // A vocabulary that fragments pointed words: those words fall back to the unpointed form.
        XCTAssertEqual(NikudAwareInput.prepare(pointed) { NikudAwareInput.hasNikud($0) ? 9 : 1 },
                       "שלום מה שלומך")
        // Unpointed input is passed through untouched.
        XCTAssertEqual(NikudAwareInput.prepare("מה שלומך") { _ in 1 }, "מה שלומך")
        XCTAssertTrue(NikudAwareInput.hasNikud("שלום\u{05B8}"))
        XCTAssertFalse(NikudAwareInput.hasNikud("שלום"))
    }
}
