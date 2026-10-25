import XCTest
@testable import HEENInterpreter

/// Runs the REAL bundled int8 OPUS-MT model inside the iOS Simulator.
/// This is the emulator gate for the two critical bugs: translation latency and `<...>` junk.
final class TranslationModelTests: XCTestCase {

    func testRealModelLatencyAndCleanOutput() async throws {
        try XCTSkipIf(!ONNXTranslationEngine.missingFiles().isEmpty,
                      "Model/ is not in the app bundle — run Tools/prepare_model.py first")

        guard let engine = await ONNXTranslationEngine.shared() else {
            XCTFail("model failed to load: \(ONNXTranslationEngine.lastLoadError() ?? "unknown")")
            return
        }

        // Warm-up call: the first inference allocates ORT arenas. It must not be the one the
        // user hears, and everything after it must be fast.
        _ = try await engine.translate("שלום")

        let sentences = [
            "אני רוצה לקנות לחם מחר בבוקר.",
            "מה שלומך היום?",
            "אנחנו נוסעים לחיפה בשבוע הבא עם הילדים.",
            "תגיד לי בבקשה איפה התחנה המרכזית.",
        ]

        for hebrew in sentences {
            let started = Date()
            let raw = try await engine.translate(hebrew)
            let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
            let clean = TextUtil.sanitizeTranslation(raw)

            XCTAssertFalse(clean.isEmpty, "empty translation for: \(hebrew)")
            XCTAssertFalse(TextUtil.hasModelArtifacts(clean), "model artifacts leaked: \(clean)")
            XCTAssertLessThan(milliseconds, 2000, "translation of '\(hebrew)' took \(milliseconds) ms")

            print("HE: \(hebrew)\nEN: \(clean)\n[\(milliseconds) ms]\n")
        }
    }

    func testModelFilesArePresent() {
        let missing = ONNXTranslationEngine.missingFiles()
        XCTAssertTrue(missing.isEmpty, "missing model files: \(missing.joined(separator: ", "))")
    }
}
