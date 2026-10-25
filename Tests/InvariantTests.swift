import XCTest
@testable import HEENInterpreter

/// Property-based tests: instead of pinning single examples, these hammer the text helpers and the
/// Hebrew gate with a few thousand *seeded* random inputs and assert invariants that must hold for
/// every one of them. The seed keeps CI deterministic (a failure is always reproducible), and the
/// invariants are the ones the device actually depends on:
///   * the TTS may never re-speak words that were already spoken,
///   * the screen may never show a control token,
///   * the gate may never invent, drop or randomly change a sentence.
final class InvariantTests: XCTestCase {

    // MARK: - Seeded generator (no dependency, reproducible)

    private struct Fuzz {
        private var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func pick<T>(_ items: [T]) -> T { items[Int(next() % UInt64(items.count))] }
        mutating func chance(_ oneIn: Int) -> Bool { next() % UInt64(oneIn) == 0 }
    }

    /// Hebrew words written as escapes on purpose: this file must survive any encoding round-trip
    /// (a mojibake round-trip already destroyed one test file in this repo).
    private let hebrewWords = [
        "\u{05E9}\u{05DC}\u{05D5}\u{05DD}",                         // shalom
        "\u{05DC}\u{05DB}\u{05D5}\u{05DC}\u{05DD}",                 // lekulam
        "\u{05DE}\u{05D4}",                                         // ma
        "\u{05E9}\u{05DC}\u{05D5}\u{05DE}\u{05DB}\u{05DD}",         // shlomchem
        "\u{05D0}\u{05E0}\u{05D9}",                                 // ani
        "\u{05E8}\u{05D5}\u{05E6}\u{05D4}",                         // rotze
        "\u{05DC}\u{05E7}\u{05E0}\u{05D5}\u{05EA}",                 // liknot
        "\u{05DC}\u{05D7}\u{05DD}",                                 // lechem
        "\u{05DE}\u{05D7}\u{05E8}",                                 // machar
        "\u{05D1}\u{05D1}\u{05D5}\u{05E7}\u{05E8}",                 // baboker
        "\u{05E2}\u{05DD}",                                         // im
        "\u{05D0}\u{05EA}",                                         // et
        "\u{05D4}\u{05D9}\u{05D5}\u{05DD}",                         // hayom
        "\u{05D4}\u{05EA}\u{05D7}\u{05E0}\u{05D4}",                 // hatachana
        "\u{05D4}\u{05DE}\u{05E8}\u{05DB}\u{05D6}\u{05D9}\u{05EA}"  // hamerkazit
    ]

    /// Builds something a streaming recogniser could hand over: one to nine words, the occasional
    /// stray comma, sometimes a full stop, sometimes sloppy whitespace.
    private func randomUtterance(_ fuzz: inout Fuzz) -> String {
        let count = 1 + Int(fuzz.next() % 9)
        var words: [String] = []
        for _ in 0..<count {
            var word = fuzz.pick(hebrewWords)
            if fuzz.chance(8) { word += "," }
            words.append(word)
        }
        var text = words.joined(separator: " ")
        if fuzz.chance(4) { text += "." }
        if fuzz.chance(12) { text = " " + text + "  " }
        return text
    }

    private func tokens(_ s: String) -> [String] { TextUtil.tokenize(s) }

    // MARK: - mergeOverlap: streaming STT re-sends the whole utterance every time

    func testMergeOverlapNeverLosesOrReordersTokens() {
        var fuzz = Fuzz(seed: 0x00C0_FFEE)
        for _ in 0..<2_000 {
            let a = randomUtterance(&fuzz)
            let b = randomUtterance(&fuzz)
            let merged = TextUtil.mergeOverlap(a, b)
            let ta = tokens(a), tb = tokens(b), tm = tokens(merged)

            XCTAssertGreaterThanOrEqual(tm.count, max(ta.count, tb.count),
                                        "mergeOverlap lost tokens: \(a) + \(b) = \(merged)")
            XCTAssertEqual(Array(tm.prefix(ta.count)), ta,
                           "mergeOverlap rewrote the text it was given: \(a) + \(b) = \(merged)")
        }
    }

    func testMergeOverlapIsIdempotentAndEmptySafe() {
        var fuzz = Fuzz(seed: 0x0000_BEEF)
        for _ in 0..<1_000 {
            let a = randomUtterance(&fuzz)
            XCTAssertEqual(tokens(TextUtil.mergeOverlap(a, a)), tokens(a),
                           "mergeOverlap(a, a) is not a no-op for: \(a)")
            XCTAssertEqual(tokens(TextUtil.mergeOverlap(a, "")), tokens(a),
                           "merging with empty changed: \(a)")
            XCTAssertEqual(tokens(TextUtil.mergeOverlap("", a)), tokens(a),
                           "merging into empty changed: \(a)")
        }
    }

    // MARK: - removePrefix: the TTS must never speak a word twice

    func testRemovePrefixOnlyEverDropsALeadingRun() {
        var fuzz = Fuzz(seed: 0x0000_5EED)
        for _ in 0..<2_000 {
            let text = randomUtterance(&fuzz)
            let prefix = randomUtterance(&fuzz)
            let t = tokens(text), p = tokens(prefix)
            let rest = tokens(TextUtil.removePrefix(text, prefix: prefix))

            if p.isEmpty || t.count < p.count || Array(t.prefix(p.count)) != p {
                XCTAssertEqual(rest, t, "removePrefix touched a text it should have left alone")
            } else {
                XCTAssertEqual(rest, Array(t.dropFirst(p.count)),
                               "removePrefix did not drop exactly the leading run")
            }
            XCTAssertLessThanOrEqual(rest.count, t.count, "removePrefix grew the text")
        }
    }

    func testRemovePrefixReachesAFixpoint() {
        var fuzz = Fuzz(seed: 0x0000_1DEA)
        for _ in 0..<1_000 {
            var current = randomUtterance(&fuzz)
            let prefix = fuzz.pick(hebrewWords)
            let p = tokens(prefix)
            for _ in 0..<8 {
                let next = TextUtil.removePrefix(current, prefix: prefix)
                if tokens(next) == tokens(current) { break }
                current = next
            }
            XCTAssertNotEqual(Array(tokens(current).prefix(p.count)), p,
                              "removePrefix left the spoken prefix in place: \(current)")
        }
    }

    // MARK: - sanitizeTranslation: nothing unspeakable may reach the screen or the speaker

    func testSanitizeIsIdempotentAndLeavesNoControlTokens() {
        var fuzz = Fuzz(seed: 0x000D_ECAF)
        let junk = ["<pad>", "</s>", "<s>", "<unk>", "<0xE2>", ">>en<<", "\u{2581}", "  ", "\n", " ..."]
        let marks = [",", ".", ";", ":", "!", "?"]

        for _ in 0..<2_000 {
            var text = randomUtterance(&fuzz)
            if fuzz.chance(2) { text += " " + fuzz.pick(junk) }
            if fuzz.chance(3) { text = fuzz.pick(junk) + text }

            let clean = TextUtil.sanitizeTranslation(text)
            XCTAssertEqual(TextUtil.sanitizeTranslation(clean), clean,
                           "sanitizeTranslation is not idempotent for: \(text)")
            XCTAssertFalse(clean.contains("<") || clean.contains(">"),
                           "a control token survived: \(clean)")
            XCTAssertEqual(clean, clean.trimmingCharacters(in: .whitespacesAndNewlines),
                           "leading/trailing whitespace survived: \(clean)")
            XCTAssertFalse(clean.contains("  "), "double space survived: \(clean)")
            for mark in marks {
                XCTAssertFalse(clean.contains(" " + mark), "space before \(mark) survived: \(clean)")
            }
            // NOTE: no `hasModelArtifacts(clean)` assertion here on purpose — the SentencePiece
            // underline (U+2581) is flagged by hasModelArtifacts but is NOT removed by
            // sanitizeTranslation yet. See testSentencePieceUnderlineIsNotSanitizedYet.
        }
    }

    /// Characterisation test for a known gap: `hasModelArtifacts` treats the SentencePiece
    /// underline (U+2581) as an artifact, but `sanitizeTranslation` passes it through. Flip this
    /// test (assert the underline is gone) as soon as sanitize learns to strip it.
    func testSentencePieceUnderlineIsNotSanitizedYet() {
        let raw = "\u{2581}Hello"
        XCTAssertTrue(TextUtil.hasModelArtifacts(raw), "U+2581 must count as an artifact")
        XCTAssertEqual(TextUtil.sanitizeTranslation(raw), raw,
                       "sanitizeTranslation now strips U+2581 — update this test and the pipeline note")
    }

    // MARK: - Gate: deterministic, monotone, invariant under whitespace

    func testGateIsDeterministicAndNeverEmitsEmptyText() {
        var fuzz = Fuzz(seed: 0x0006_CA7E)
        for _ in 0..<2_000 {
            let text = randomUtterance(&fuzz)
            var gate = HebrewCompletenessGate()
            gate.mode = fuzz.pick(GateMode.allCases)
            let silence = fuzz.chance(2) ? 0.0 : 1.5
            let isFinal = fuzz.chance(2)
            let age = fuzz.chance(3) ? 30.0 : 0.2

            let first = gate.evaluate(text, trailingSilence: silence, isSTTFinal: isFinal, pendingAge: age)
            let second = gate.evaluate(text, trailingSilence: silence, isSTTFinal: isFinal, pendingAge: age)
            XCTAssertEqual(first, second, "the gate is not deterministic for: \(text)")

            if first.emit {
                XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "the gate emitted an empty text")
            }
            if first.forced {
                XCTAssertGreaterThanOrEqual(tokens(text).count, 3,
                                            "a forced emit must not be a stub: \(text)")
            }
        }
    }

    /// Metamorphic test: adding evidence (a pause, an STT endpoint, a full stop) may turn a hold
    /// into an emit, but it must never turn an emit into a hold — otherwise the live interpreter
    /// would drop a sentence it had already decided to speak.
    func testGateEmissionIsMonotoneInEvidence() {
        var fuzz = Fuzz(seed: 0x0000_90A1)
        var checked = 0
        for _ in 0..<4_000 {
            let text = randomUtterance(&fuzz)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var gate = HebrewCompletenessGate()
            gate.mode = fuzz.pick(GateMode.allCases)

            let base = gate.evaluate(text, trailingSilence: 0.0, isSTTFinal: false, pendingAge: 0.1)
            guard base.emit else { continue }
            checked += 1

            XCTAssertTrue(gate.evaluate(text, trailingSilence: 5.0, isSTTFinal: false, pendingAge: 0.1).emit,
                          "a long pause cancelled an emission: \(text)")
            XCTAssertTrue(gate.evaluate(text, trailingSilence: 0.0, isSTTFinal: true, pendingAge: 0.1).emit,
                          "an STT endpoint cancelled an emission: \(text)")
            XCTAssertTrue(gate.evaluate(text + ".", trailingSilence: 0.0, isSTTFinal: false, pendingAge: 0.1).emit,
                          "a full stop cancelled an emission: \(text)")
        }
        XCTAssertGreaterThan(checked, 50, "the generator never produced an emitting utterance")
    }

    /// Metamorphic test: the recogniser's spacing is noise. Double spaces, tabs and stray newlines
    /// must not change whether a sentence is considered complete.
    func testGateIgnoresSloppyWhitespace() {
        var fuzz = Fuzz(seed: 0x0000_4777)
        for _ in 0..<2_000 {
            let text = randomUtterance(&fuzz)
            let spaced = "   " + text.replacingOccurrences(of: " ", with: "  ") + "\t\n "
            var gate = HebrewCompletenessGate()
            gate.mode = fuzz.pick(GateMode.allCases)

            let plain = gate.evaluate(text, trailingSilence: 0.0, isSTTFinal: true, pendingAge: 0.2)
            let messy = gate.evaluate(spaced, trailingSilence: 0.0, isSTTFinal: true, pendingAge: 0.2)
            XCTAssertEqual(plain.emit, messy.emit, "whitespace changed the gate decision: \(text)")
            XCTAssertEqual(plain.forced, messy.forced, "whitespace changed the force decision: \(text)")
        }
    }
}
