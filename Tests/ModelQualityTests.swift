import XCTest
@testable import HEENInterpreter

/// Quality tests against the *real* on-device models (293 MB diacritizer + int8 OPUS-MT).
/// They answer what the pure-logic tests cannot: does the diacritizer survive junk and really add
/// nikud, does the translator still keep the meaning, and is a warm pass fast enough to interpret
/// live? Hebrew is written as escapes so an encoding round-trip cannot corrupt this file.
@MainActor
final class ModelQualityTests: XCTestCase {

    // MARK: - Sentences (escapes only)

    private let shalom = "\u{05E9}\u{05DC}\u{05D5}\u{05DD}"
    private let greetingQuestion = "\u{05E9}\u{05DC}\u{05D5}\u{05DD}, \u{05DE}\u{05D4} \u{05E9}\u{05DC}\u{05D5}\u{05DE}\u{05DA}?"
    private let breadSentence = "\u{05D0}\u{05E0}\u{05D9} \u{05E8}\u{05D5}\u{05E6}\u{05D4} \u{05DC}\u{05E7}\u{05E0}\u{05D5}\u{05EA} \u{05DC}\u{05D7}\u{05DD} \u{05DE}\u{05D7}\u{05E8} \u{05D1}\u{05D1}\u{05D5}\u{05E7}\u{05E8}."
    private let studySentence = "\u{05D0}\u{05E0}\u{05D9} \u{05DC}\u{05D5}\u{05DE}\u{05D3} \u{05E2}\u{05D1}\u{05E8}\u{05D9}\u{05EA} \u{05DB}\u{05DC} \u{05D9}\u{05D5}\u{05DD} \u{05E2}\u{05DD} \u{05D7}\u{05D1}\u{05E8}\u{05D9}\u{05DD} \u{05E9}\u{05DC}\u{05D9}."
    private let stationSentence = "\u{05EA}\u{05D2}\u{05D9}\u{05D3} \u{05DC}\u{05D9} \u{05D0}\u{05D9}\u{05E4}\u{05D4} \u{05D4}\u{05EA}\u{05D7}\u{05E0}\u{05D4} \u{05D4}\u{05DE}\u{05E8}\u{05DB}\u{05D6}\u{05D9}\u{05EA}."

    private static var sharedPipeline: Pipeline?

    /// One Pipeline per test process: the diacritizer session is 293 MB and costs seconds to build,
    /// so paying for it once keeps the whole class inside the test time allowance.
    private func warmPipeline() -> Pipeline {
        if let existing = Self.sharedPipeline { return existing }
        let pipeline = Pipeline()
        _ = pipeline.diacritize(shalom)
        Self.sharedPipeline = pipeline
        return pipeline
    }

    /// Drops Hebrew points/accents (U+0591–U+05C7) so letters can be compared with the input.
    private func withoutMarks(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { !(0x0591...0x05C7).contains($0.value) }))
    }

    // MARK: - Diacritizer

    func testDiacritizerAddsNikudAndSurvivesJunk() {
        let pipeline = warmPipeline()

        let pointed = pipeline.diacritize(shalom)
        // Compare *scalars*: a pointed letter is still one grapheme cluster, so `count` (characters)
        // stays 4 for the pointed word — only the scalar count shows the added marks.
        XCTAssertGreaterThan(pointed.unicodeScalars.count, shalom.unicodeScalars.count,
                             "the diacritizer returned the bare word: \(pointed)")
        XCTAssertTrue(pointed.unicodeScalars.contains { (0x05B0...0x05C7).contains($0.value) },
                      "no nikud mark in: \(pointed)")
        XCTAssertTrue(withoutMarks(pointed).contains(shalom),
                      "the diacritizer changed the letters: \(pointed)")

        // Junk must never crash the pipeline and must never come back empty: whatever the model
        // cannot handle has to fall through unchanged rather than disappear.
        let junk = ["   ", "!!!", "abc", "12345", "\u{1F600}\u{1F600}",
                    "\u{05E9}\u{05DC}\u{05D5}\u{05DD} abc",
                    String(repeating: shalom + " ", count: 60)]
        for input in junk {
            let out = pipeline.diacritize(input)
            XCTAssertFalse(out.isEmpty, "the diacritizer returned empty for: \(input.prefix(20))")
            print("NIKUD-JUNK [\(input.prefix(20))] -> [\(out.prefix(40))] (\(out.count) chars)")
        }
    }

    // MARK: - Translator

    func testTranslationsKeepTheMeaning() async throws {
        guard let engine = await ONNXTranslationEngine.shared() else {
            throw XCTSkip("bundled ONNX model unavailable: \(ONNXTranslationEngine.missingFiles()) "
                          + "\(ONNXTranslationEngine.lastLoadError() ?? "")")
        }
        let cases: [(hebrew: String, anyOf: [String])] = [
            (greetingQuestion, ["hello", "how are you"]),
            (breadSentence, ["bread"]),
            (studySentence, ["hebrew"]),
            (stationSentence, ["station"]),
        ]
        for testCase in cases {
            let clean = TextUtil.sanitizeTranslation(try await engine.translate(testCase.hebrew))
            print("GOLDEN [\(testCase.hebrew)] -> [\(clean)]")
            XCTAssertFalse(clean.isEmpty, "empty translation for: \(testCase.hebrew)")
            XCTAssertFalse(TextUtil.hasModelArtifacts(clean), "control tokens leaked: \(clean)")
            XCTAssertTrue(testCase.anyOf.contains { clean.lowercased().contains($0) },
                          "expected one of \(testCase.anyOf) in: \(clean)")
        }
    }

    /// The translator's contract is *pointed* Hebrew (items 4/5). Each golden sentence is
    /// diacritized first — exactly what the live pipeline hands over — and must still come out
    /// with the same meaning: the points are carried where the model's vocabulary can hold them
    /// and normalised word by word where they would shatter, and either way nothing is lost.
    func testTranslationsWorkFromPointedHebrew() async throws {
        guard let engine = await ONNXTranslationEngine.shared() else {
            throw XCTSkip("bundled ONNX model unavailable: \(ONNXTranslationEngine.missingFiles())")
        }
        let pipeline = warmPipeline()
        let cases: [(hebrew: String, anyOf: [String])] = [
            (greetingQuestion, ["hello", "how are you"]),
            (breadSentence, ["bread"]),
            (studySentence, ["hebrew"]),
            (stationSentence, ["station"]),
        ]
        var pointedCases = 0
        for testCase in cases {
            let pointed = pipeline.diacritize(testCase.hebrew)
            if NikudAwareInput.hasNikud(pointed) { pointedCases += 1 }
            let clean = TextUtil.sanitizeTranslation(try await engine.translate(pointed))
            print("GOLDEN POINTED [\(pointed)] -> [\(clean)]")
            XCTAssertFalse(clean.isEmpty, "empty translation for pointed: \(pointed)")
            XCTAssertFalse(TextUtil.hasModelArtifacts(clean), "control tokens leaked: \(clean)")
            XCTAssertTrue(testCase.anyOf.contains { clean.lowercased().contains($0) },
                          "expected one of \(testCase.anyOf) in: \(clean)")
        }
        // When the diacritizer is present the points must really have been produced, or this test
        // would quietly degrade into a second copy of the unpointed one.
        if !pipeline.nikudUnavailable {
            XCTAssertGreaterThan(pointedCases, 0, "the diacritizer produced no nikud at all")
        }
    }

    /// The interpreter is live: a warm diacritize + translate must stay well inside the window a
    /// speaker leaves between sentences. Generous budgets — the runner is a shared simulator.
    func testWarmLatencyFitsLiveInterpreting() async throws {
        guard let engine = await ONNXTranslationEngine.shared() else {
            throw XCTSkip("bundled ONNX model unavailable: \(ONNXTranslationEngine.missingFiles())")
        }
        _ = try await engine.translate(shalom)          // warm the translation graph

        let pipeline = warmPipeline()
        _ = pipeline.diacritize(shalom)                 // session already built by warmPipeline

        let nikudStart = Date()
        _ = pipeline.diacritize(breadSentence)
        let nikudMS = Date().timeIntervalSince(nikudStart) * 1000

        let translateStart = Date()
        let out = try await engine.translate(breadSentence)
        let translateMS = Date().timeIntervalSince(translateStart) * 1000

        print("LATENCY nikud \(Int(nikudMS)) ms, translate \(Int(translateMS)) ms -> [\(out.prefix(60))]")
        XCTAssertLessThan(nikudMS, 2_000, "a warm diacritize took \(Int(nikudMS)) ms")
        XCTAssertLessThan(translateMS, 2_500, "a warm translation took \(Int(translateMS)) ms")
    }
}
