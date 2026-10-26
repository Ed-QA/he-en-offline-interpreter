import XCTest
@testable import HEENInterpreter

/// Rendering a sample for every installed voice takes minutes, so the sampler has to be
/// interruptible — it used to run to the end with no way out.
final class VoiceSamplerTests: XCTestCase {

    func testCancelledSamplerRendersNothing() async {
        let flag = VoiceSampler.CancelFlag()
        flag.set()

        var lines: [String] = []
        let report = await VoiceSampler.generateAll(targetSeconds: 1, shouldCancel: { flag.isSet }) {
            lines.append($0)
        }

        XCTAssertTrue(report.samples.isEmpty,
                      "a cancelled sampler still rendered \(report.samples.count) voices")
        if !Speaker.englishVoices().isEmpty {
            XCTAssertTrue(lines.contains { $0.contains("Cancelled") },
                          "the cancellation was not reported: \(lines)")
        }
    }

    func testCancelFlagIsSharedState() {
        let flag = VoiceSampler.CancelFlag()
        XCTAssertFalse(flag.isSet, "a fresh flag is already set")
        flag.set()
        XCTAssertTrue(flag.isSet, "set() did not take")
        flag.clear()
        XCTAssertFalse(flag.isSet, "clear() did not take")
    }
}
