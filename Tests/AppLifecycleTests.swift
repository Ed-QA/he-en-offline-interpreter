import XCTest
@testable import HEENInterpreter

/// Launch behaviour. The app auto-starts by design (launch == live), but a test host must never
/// grab the microphone, raise the system permission alert or spend a minute loading models.
@MainActor
final class AppLifecycleTests: XCTestCase {

    func testTestHostIsDetected() {
        XCTAssertTrue(Pipeline.isRunningTests,
                      "XCTestConfigurationFilePath is invisible - the app would auto-start in tests")
    }

    /// Before this, `prepare()` ran the full app path in the unit-test host: it requested the
    /// microphone (system alert) and loaded the 293 MB diacritizer.
    func testPrepareInATestHostStaysIdleAndSkipsTheDiacritizer() async {
        let pipeline = Pipeline(stt: ScriptedSTT(steps: []))
        await pipeline.prepare()

        XCTAssertFalse(pipeline.running, "the test host started listening")
        XCTAssertEqual(pipeline.status, .idle, "the test host is not idle after prepare()")
        XCTAssertNil(pipeline.nikud, "the test host loaded the 293 MB diacritizer")
    }
}
