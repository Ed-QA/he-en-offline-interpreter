import XCTest
@testable import HEENInterpreter

/// Loading the model is the step that only the phone can get wrong, and the step no test covered:
/// the recogniser was shipped pointing at a file that is never in the bundle, and — once that was
/// fixed — it loaded 843 MB of int8 weights inside `init`, which runs during app launch.
final class WhisperNikudLoadTests: XCTestCase {

    /// Loading the weights is the step only the phone used to get wrong, and the step no test
    /// covered. `start()` is what loads them; the microphone part may fail in a simulator and that
    /// is not what this test is about, so its error is ignored.
    func testTheRecognizerLoadsTheShippedWeights() {
        let stt = WhisperNikudSTT()
        _ = try? stt.start()
        XCTAssertFalse(stt.statusText.contains("loads on Start"),
                       "the weights were never loaded: \(stt.statusText)")
        XCTAssertFalse(stt.statusText.contains("not available"),
                       "the recogniser did not load: \(stt.statusText)")
        stt.stop()
    }
}