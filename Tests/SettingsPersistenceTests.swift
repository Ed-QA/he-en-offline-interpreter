import XCTest
@testable import HEENInterpreter

/// Settings are real user choices now: the voice, the rate and the chunking mode used to be
/// forgotten on every launch, so these tests pin the storage, the clamping and the reset.
@MainActor
final class SettingsPersistenceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Prefs.reset()
    }

    override func tearDown() {
        Prefs.reset()
        super.tearDown()
    }

    func testDefaultsWhenNothingIsStored() {
        let pipeline = Pipeline(stt: ScriptedSTT(steps: []))
        XCTAssertEqual(pipeline.gateMode, .balanced)
        XCTAssertEqual(pipeline.rate, Prefs.defaultRate, accuracy: 0.0001)
        XCTAssertEqual(pipeline.voiceIdentifier, Speaker.defaultEnglishVoice()?.identifier)
        XCTAssertEqual(pipeline.gate.mode, .balanced, "the gate did not get the default mode")
        XCTAssertEqual(pipeline.speaker.rate, Prefs.defaultRate, accuracy: 0.0001,
                       "the speaker did not get the rate at launch")
    }

    /// The whole point of the feature: a second launch must see what the user chose.
    func testChoicesSurviveANewPipeline() {
        let first = Pipeline(stt: ScriptedSTT(steps: []))
        first.gateMode = .complete
        first.rate = 0.42
        first.voiceIdentifier = "com.example.voice.test"

        let second = Pipeline(stt: ScriptedSTT(steps: []))
        XCTAssertEqual(second.gateMode, .complete, "the chunking mode was not remembered")
        XCTAssertEqual(second.rate, 0.42, accuracy: 0.0001, "the rate was not remembered")
        XCTAssertEqual(second.voiceIdentifier, "com.example.voice.test", "the voice was not remembered")
        XCTAssertEqual(second.gate.mode, .complete, "the remembered mode was not applied to the gate")
        XCTAssertEqual(second.speaker.rate, 0.42, accuracy: 0.0001, "the remembered rate was not applied")
        XCTAssertEqual(second.speaker.voiceIdentifier, "com.example.voice.test",
                       "the remembered voice was not applied to the speaker")
    }

    func testRateIsClampedAndGarbageFallsBackToDefaults() {
        Prefs.rate = 9.0
        XCTAssertEqual(Prefs.rate, Prefs.rateRange.upperBound, accuracy: 0.0001)
        Prefs.rate = -3.0
        XCTAssertEqual(Prefs.rate, Prefs.rateRange.lowerBound, accuracy: 0.0001)

        UserDefaults.standard.set("nonsense", forKey: Prefs.gateKey)
        XCTAssertEqual(Prefs.gateMode, .balanced, "an unreadable mode must fall back to the default")
    }

    func testResetRestoresTheShippedDefaultsAndForgetsThem() {
        let pipeline = Pipeline(stt: ScriptedSTT(steps: []))
        pipeline.gateMode = .fast
        pipeline.rate = 0.6
        pipeline.voiceIdentifier = "com.example.voice.test"

        pipeline.resetSettings()

        XCTAssertEqual(pipeline.gateMode, .balanced)
        XCTAssertEqual(pipeline.rate, Prefs.defaultRate, accuracy: 0.0001)
        XCTAssertEqual(pipeline.gate.mode, .balanced, "the gate kept the old mode")
        XCTAssertNil(Prefs.voiceIdentifier, "reset left the voice in UserDefaults")
        XCTAssertEqual(Prefs.gateMode, .balanced, "reset left the mode in UserDefaults")
        XCTAssertEqual(Prefs.rate, Prefs.defaultRate, accuracy: 0.0001)
    }
}
