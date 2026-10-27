import XCTest
@testable import HEENInterpreter

/// The Whisper-Nikudon recogniser is the app's only Hebrew ASR, so the bundle has to contain the
/// exact files it opens. This is the check whose absence let a wrong name reach the phone: the app
/// probed for `encoder_model.onnx` — the fp32 export that `Tools/prepare_stt_nikud.py` deletes right
/// after quantization — and reported "Model/WhisperNikud (not in bundle)" while the folder sat in
/// the app the whole time. The old recogniser had such a test; the new one was shipped without it.
final class WhisperNikudModelTests: XCTestCase {

    func testRecognizerFolderIsInTheBundle() {
        XCTAssertNotNil(WhisperNikudSTT.folder(),
                        "Model/WhisperNikud was not found in the app bundle")
    }

    func testEveryFileTheRecognizerOpensIsBundled() {
        let missing = WhisperNikudSTT.missingFiles()
        XCTAssertTrue(missing.isEmpty,
                      "ASR model not in the app bundle: \(missing.joined(separator: ", "))")
    }

    /// Existence alone is not enough: a name that ships empty, or the wrong name, is exactly the
    /// failure this file exists for, so the shipped sizes are checked too.
    func testTheShippedFileNamesCarryRealWeights() throws {
        let folder = try XCTUnwrap(WhisperNikudSTT.folder(), "no Model/WhisperNikud in the bundle")
        for name in ["encoder_model.int8.onnx", "decoder_model.int8.onnx", "tokens.txt"] {
            let path = folder.appendingPathComponent(name)
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            XCTAssertGreaterThan(size, 0, "\(name) is missing or empty in the app bundle")
        }
    }
}