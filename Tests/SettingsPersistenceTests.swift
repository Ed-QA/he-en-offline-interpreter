import XCTest
@testable import HEENInterpreter

/// Settings are real user choices now: the voice and the rate used to be forgotten on every launch,
/// so these tests pin the storage, the clamping and the reset. (How speech is chunked is not a
/// setting — the recogniser windows it and the gate decides when a sentence is complete.)
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
        XCTAssertEqual(pipeline.rate, Prefs.defaultRate, accuracy: 0.0001)
        XCTAssertEqual(pipeline.voiceIdentifier, Speaker.defaultEnglishVoice()?.identifier)
        XCTAssertEqual(pipeline.speaker.rate, Prefs.defaultRate, accuracy: 0.0001,
                       "the speaker did not get the rate at launch")
    }

    /// The whole point of the feature: a second launch must see what the user chose.
    func testChoicesSurviveANewPipeline() {
        let first = Pipeline(stt: ScriptedSTT(steps: []))
        first.rate = 0.42
        first.voiceIdentifier = "com.example.voice.test"

        let second = Pipeline(stt: ScriptedSTT(steps: []))
        XCTAssertEqual(second.rate, 0.42, accuracy: 0.0001, "the rate was not remembered")
        XCTAssertEqual(second.voiceIdentifier, "com.example.voice.test", "the voice was not remembered")
        XCTAssertEqual(second.speaker.rate, 0.42, accuracy: 0.0001, "the remembered rate was not applied")
        XCTAssertEqual(second.speaker.voiceIdentifier, "com.example.voice.test",
                       "the remembered voice was not applied to the speaker")
    }

    func testRateIsClampedAndGarbageFallsBackToDefaults() {
        Prefs.rate = 9.0
        XCTAssertEqual(Prefs.rate, Prefs.rateRange.upperBound, accuracy: 0.0001)
        Prefs.rate = -3.0
        XCTAssertEqual(Prefs.rate, Prefs.rateRange.lowerBound, accuracy: 0.0001)
    }

    func testResetRestoresTheShippedDefaultsAndForgetsThem() {
        let pipeline = Pipeline(stt: ScriptedSTT(steps: []))
        pipeline.rate = 0.6
        pipeline.voiceIdentifier = "com.example.voice.test"

        pipeline.resetSettings()

        XCTAssertEqual(pipeline.rate, Prefs.defaultRate, accuracy: 0.0001)
        XCTAssertNil(Prefs.voiceIdentifier, "reset left the voice in UserDefaults")
        XCTAssertEqual(Prefs.rate, Prefs.defaultRate, accuracy: 0.0001)
    }

    /// Each language keeps its own voice and speed: switching language must never overwrite the
    /// other language's choices, and the original single-language accessors stay English.
    func testEachLanguageKeepsItsOwnVoiceAndSpeed() {
        Prefs.setRate(0.40, for: .en)
        Prefs.setRate(0.62, for: .uk)
        XCTAssertEqual(Prefs.rate(for: .en), 0.40, accuracy: 0.0001)
        XCTAssertEqual(Prefs.rate(for: .uk), 0.62, accuracy: 0.0001)

        Prefs.setVoice("com.example.en.voice", for: .en)
        Prefs.setVoice("com.example.uk.voice", for: .uk)
        XCTAssertEqual(Prefs.voice(for: .en), "com.example.en.voice")
        XCTAssertEqual(Prefs.voice(for: .uk), "com.example.uk.voice")

        // The old accessors are the English ones, so nothing that predates the switch changed.
        XCTAssertEqual(Prefs.rate, Prefs.rate(for: .en), accuracy: 0.0001)
        XCTAssertEqual(Prefs.voiceIdentifier, "com.example.en.voice")

        // And a reset clears both languages, not just English.
        Prefs.reset()
        XCTAssertNil(Prefs.voice(for: .uk), "reset left the Ukrainian voice behind")
        XCTAssertEqual(Prefs.rate(for: .uk), Prefs.defaultRate, accuracy: 0.0001)
    }

    /// The selected language is remembered, and a fresh install starts in English.
    func testSelectedLanguageIsRemembered() {
        XCTAssertEqual(Prefs.target, .en, "a fresh install must start in English")
        Prefs.target = .uk
        XCTAssertEqual(Prefs.target, .uk)
        Prefs.target = .en
        XCTAssertEqual(Prefs.target, .en)
    }

    /// Ukrainian has its own model folder — that is what keeps the two models apart and lets the
    /// app load only the selected language's model.
    func testEachLanguageHasItsOwnModelFolder() {
        XCTAssertEqual(ONNXTranslationEngine.folderName(for: .en), "Model")
        XCTAssertEqual(ONNXTranslationEngine.folderName(for: .uk), "Model-uk")
    }
}
