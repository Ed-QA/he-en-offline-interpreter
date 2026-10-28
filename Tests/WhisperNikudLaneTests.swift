import XCTest
@testable import HEENInterpreter

/// The two questions the lane design has to answer — is the audio covered, and does the text stay in
/// order — answered by driving the lanes, not by reading them.
///
/// The stand-in decoder stands in for the recogniser, so the lanes can be fed a known signal and made
/// as slow as needed. The audio is a ramp from 0.1 to 0.6: loud enough that no window counts as
/// silence, and every sample says where it came from, so a window's contents can be mapped back to
/// the audio that was fed and checked for gaps.
final class WhisperNikudLaneTests: XCTestCase {

    private let rate = 16_000.0
    private let low: Float = 0.1
    private let high: Float = 0.6

    private func ramp(seconds: Double) -> [Float] {
        let count = Int(seconds * rate)
        return (0..<count).map { low + (high - low) * Float($0) / Float(count - 1) }
    }

    private func index(of value: Float, in total: Int) -> Int {
        Int(((value - low) / (high - low)) * Float(total - 1))
    }

    /// A counter the two lanes can touch without racing — the stand-in decoders run on both of them.
    private final class Counter {
        private let lock = NSLock()
        private var value = 0
        /// Returns the number of calls so far, counting this one.
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// Feeds `audio` a microphone-sized buffer at a time and waits for the lanes to drain.
    private func feed(_ stt: WhisperNikudSTT, _ audio: [Float], drain: TimeInterval) {
        let chunk = Int(0.1 * rate)
        var fed = 0
        while fed < audio.count {
            let end = min(fed + chunk, audio.count)
            stt.feedForTest(Array(audio[fed..<end]), rate: rate)
            fed = end
        }
        let done = expectation(description: "lanes drained")
        DispatchQueue.global().asyncAfter(deadline: .now() + drain) { done.fulfill() }
        wait(for: [done], timeout: drain + 5)
    }

    func testEverySecondOfAudioIsInsideAWindow() {
        let stt = WhisperNikudSTT()
        let audio = ramp(seconds: 12)
        let lock = NSLock()
        var windows: [[Float]] = []
        stt.beginForTest { samples, _ in
            lock.lock()
            windows.append(samples)
            lock.unlock()
            return nil
        }

        feed(stt, audio, drain: 2)

        lock.lock()
        let captured = windows
        lock.unlock()
        XCTAssertGreaterThan(captured.count, 4, "the lanes should have been handed several windows")

        // A window holds the last 2.0 s and a new one starts every 1.7 s, so their union has to cover
        // the whole recording: any sample nobody decoded is a gap in the recording.
        var covered = Set<Int>()
        for window in captured {
            guard let first = window.min(), let last = window.max() else { continue }
            covered.formUnion(index(of: first, in: audio.count)...index(of: last, in: audio.count))
        }
        let missing = (0..<audio.count).filter { !covered.contains($0) }
        XCTAssertTrue(missing.isEmpty, "\(missing.count) samples were never inside a window")
    }

    func testTheCountersReportWhatTheLanesDid() {
        let stt = WhisperNikudSTT()
        let audio = ramp(seconds: 12)
        // The first window is made five seconds slow — far past the 3.4 s a lane is given — so the
        // other lane finishes its window first and a handover really does land out of order. Whether
        // that happens on a phone is exactly what the counters are for.
        let calls = Counter()
        stt.beginForTest { _, _ in
            let delay = calls.next() == 1 ? 5.0 : 0.01
            Thread.sleep(forTimeInterval: delay)
            return nil
        }

        feed(stt, audio, drain: 8)

        XCTAssertGreaterThan(stt.stats.windowsDecoded, 4)
        XCTAssertGreaterThan(stt.stats.outOfOrder, 0,
                             "a window landing after a later one must be counted, not ignored")
        XCTAssertGreaterThanOrEqual(stt.stats.maxBacklog, 2, "both lanes busy must show as backlog")
        XCTAssertGreaterThan(stt.stats.lastDecodeMS, 0, "decode time must be measured")
        XCTAssertTrue(stt.statsLine.contains("budget 3400 ms"), stt.statsLine)
    }

    func testASilentWindowIsNeverDecoded() {
        let stt = WhisperNikudSTT()
        let decoded = Counter()
        stt.beginForTest { _, _ in
            _ = decoded.next()
            return nil
        }

        feed(stt, [Float](repeating: 0, count: Int(12 * rate)), drain: 1)

        XCTAssertEqual(decoded.count, 0, "silence must not be sent to the model - Whisper invents words in it")
        XCTAssertGreaterThan(stt.stats.windowsSkippedSilent, 4)
    }
}