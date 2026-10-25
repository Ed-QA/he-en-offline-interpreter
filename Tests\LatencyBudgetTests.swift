import AVFoundation
import XCTest
@testable import HEENInterpreter

/// Where the seconds actually go. This class is named so it runs **before** `ModelQualityTests`
/// (XCTest orders classes alphabetically), which means the 293 MB diacritizer session is still cold
/// and its creation time can be measured. Everything it prints stays in the CI log as evidence.
@MainActor
final class LatencyBudgetTests: XCTestCase {

    // Hebrew as escapes: an encoding round-trip must not be able to corrupt this file.
    private let oneWord = "\u{05E9}\u{05DC}\u{05D5}\u{05DD}"
    private let sixWords = "\u{05D0}\u{05E0}\u{05D9} \u{05E8}\u{05D5}\u{05E6}\u{05D4} \u{05DC}\u{05E7}\u{05E0}\u{05D5}\u{05EA} \u{05DC}\u{05D7}\u{05DD} \u{05DE}\u{05D7}\u{05E8} \u{05D1}\u{05D1}\u{05D5}\u{05E7}\u{05E8}."
    private let fifteenWords = "\u{05D0}\u{05E0}\u{05D9} \u{05E8}\u{05D5}\u{05E6}\u{05D4} \u{05DC}\u{05E7}\u{05E0}\u{05D5}\u{05EA} \u{05DC}\u{05D7}\u{05DD} \u{05DE}\u{05D7}\u{05E8} \u{05D1}\u{05D1}\u{05D5}\u{05E7}\u{05E8}. \u{05EA}\u{05D2}\u{05D9}\u{05D3} \u{05DC}\u{05D9} \u{05D0}\u{05D9}\u{05E4}\u{05D4} \u{05D4}\u{05EA}\u{05D7}\u{05E0}\u{05D4} \u{05D4}\u{05DE}\u{05E8}\u{05DB}\u{05D6}\u{05D9}\u{05EA}."

    private func ms(_ work: () throws -> Void) rethrows -> Int {
        let start = Date()
        try work()
        return Int(Date().timeIntervalSince(start) * 1000)
    }

    private func msAsync(_ work: () async throws -> Void) async rethrows -> Int {
        let start = Date()
        try await work()
        return Int(Date().timeIntervalSince(start) * 1000)
    }

    private static var sharedPipeline: Pipeline?

    /// One diacritizer session per process: building it costs seconds and ~293 MB.
    private func warmPipeline() -> Pipeline {
        if let existing = Self.sharedPipeline { return existing }
        let pipeline = Pipeline()
        _ = pipeline.diacritize(oneWord)
        Self.sharedPipeline = pipeline
        return pipeline
    }

    /// Cold load of the diacritizer (the 293 MB session) plus the first inference after it.
    func testColdDiacritizerLoad() throws {
        var restorer: NikudRestorer?
        let cold = try ms { restorer = try NikudRestorer.load() }
        guard let restorer else { return XCTFail("the diacritizer did not load") }

        let firstInference = ms { _ = restorer.addDiacritics(oneWord) }
        print("LATENCY cold nikud session \(cold) ms, first inference \(firstInference) ms")
        XCTAssertLessThan(cold, 60_000, "the diacritizer session took \(cold) ms to build")
    }

    /// Warm diacritize cost as the sentence grows. Character-level model: cost tracks length.
    func testWarmDiacritizeScaling() {
        let pipeline = warmPipeline()   // session + graph warm

        let cases = [("1w", oneWord), ("6w", sixWords), ("15w", fifteenWords),
                     ("40w", Array(repeating: sixWords, count: 7).joined(separator: " "))]
        var times: [String: Int] = [:]
        for (label, text) in cases {
            times[label] = ms { _ = pipeline.diacritize(text) }
        }
        print("LATENCY warm diacritize " + cases.map { "\($0.0) \(times[$0.0] ?? -1) ms" }.joined(separator: " | "))
        XCTAssertLessThan(times["40w"] ?? 99_999, 3_000, "a 40-word diacritize took \(times["40w"] ?? -1) ms")
    }

    /// Warm translation cost as the sentence grows, plus the realistic end-to-end pair.
    func testWarmTranslationAndEndToEnd() async throws {
        guard let engine = await ONNXTranslationEngine.shared() else {
            throw XCTSkip("bundled ONNX model unavailable: \(ONNXTranslationEngine.missingFiles())")
        }
        _ = try await engine.translate(oneWord)   // warm the graph

        let short = try await msAsync { _ = try await engine.translate(sixWords) }
        let medium = try await msAsync { _ = try await engine.translate(fifteenWords) }
        let long = try await msAsync {
            _ = try await engine.translate(Array(repeating: sixWords, count: 7).joined(separator: " "))
        }
        print("LATENCY warm translate 6w \(short) ms | 15w \(medium) ms | 40w \(long) ms")

        let pipeline = warmPipeline()
        let nikudMS = ms { _ = pipeline.diacritize(sixWords) }
        let translateMS = try await msAsync { _ = try await engine.translate(sixWords) }
        let endToEnd = nikudMS + translateMS
        print("LATENCY end-to-end 6w (nikud \(nikudMS) ms + translate \(translateMS) ms) \(endToEnd) ms")
        XCTAssertLessThan(endToEnd, 5_000, "one sentence took \(endToEnd) ms end to end")
    }

    /// The TTS path re-resolves the voice and re-configures the audio session on **every**
    /// utterance - both are candidate corners to cut, so measure them here.
    func testTextToSpeechPathCost() {
        let voiceLookup = ms { _ = AVSpeechSynthesisVoice.speechVoices() }
        let defaultVoice = ms { _ = Speaker.defaultEnglishVoice() }

        let session = AVAudioSession.sharedInstance()
        let sessionAssert = ms {
            try? session.setCategory(.playAndRecord, mode: .default,
                                     options: [.defaultToSpeaker, .allowBluetoothA2DP, .duckOthers])
            try? session.overrideOutputAudioPort(.speaker)
            try? session.setActive(true)
        }

        let speaker = Speaker()
        let enqueue = ms { speaker.speak("Hello, how are you?") }
        print("LATENCY tts speechVoices() \(voiceLookup) ms | defaultEnglishVoice() \(defaultVoice) ms "
              + "| audio session assert \(sessionAssert) ms | speak() enqueue \(enqueue) ms")
        speaker.stop()
    }
}
