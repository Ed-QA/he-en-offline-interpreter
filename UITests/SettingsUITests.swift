import XCTest

/// Settings end to end: the controls exist, a choice survives a relaunch, "Send logs" opens the
/// native share sheet, and "Reset settings" puts everything back.
final class SettingsUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// `-HEENResetPrefs` makes every test start from the shipped defaults, so the suite is not
    /// affected by whatever the previous test left behind.
    private func launch(resetPrefs: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HEENUITest"] + (resetPrefs ? ["-HEENResetPrefs"] : [])
        app.launch()
        XCTAssertTrue(app.staticTexts["statusTitle"].waitForExistence(timeout: 90),
                      "the status light never appeared")
        return app
    }

    private func openSettings(_ app: XCUIApplication) {
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 20), "settings did not open")
    }

    private func closeSettings(_ app: XCUIApplication) {
        app.navigationBars.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Settings"].firstMatch.waitForExistence(timeout: 20),
                      "settings did not close")
    }

    private func wait(_ seconds: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return condition()
    }

    /// Everything a user actually needs: pick a voice, set the rate, hear it, choose how the app
    /// chunks speech, send the logs, reset. The developer tools stay reachable but separate.
    func testSettingsOffersTheNeededControls() {
        let app = launch()
        openSettings(app)

        for id in ["voicePicker", "rateSlider", "testVoice", "gateModePicker",
                   "shareLogsSettings", "resetSettings"] {
            XCTAssertTrue(app.descendants(matching: .any)[id].waitForExistence(timeout: 20),
                          "\(id) is missing from Settings")
        }
        XCTAssertTrue(app.staticTexts["Developer"].exists || app.buttons["Developer"].exists,
                      "the developer section is missing")
    }

    func testHearThisVoiceIsSafeToTap() {
        let app = launch()
        openSettings(app)
        let test = app.buttons["testVoice"]
        XCTAssertTrue(test.waitForExistence(timeout: 20))
        test.tap()
        // The sample speaks asynchronously; the app must stay responsive and the sheet open.
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 20),
                      "settings closed itself when the voice sample played")
        closeSettings(app)
    }

    func testChunkingModeSurvivesARelaunchAndResetRestoresIt() {
        let app = launch()
        openSettings(app)

        let picker = app.descendants(matching: .any)["gateModePicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 20), "the chunking picker is missing")
        picker.tap()
        let option = app.descendants(matching: .any)["Complete (wait for sense)"].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 10), "the chunking options did not open")
        option.tap()

        closeSettings(app)
        app.terminate()

        // Second launch, without the reset flag: the choice must come back by itself.
        let relaunched = launch(resetPrefs: false)
        openSettings(relaunched)
        let shown = relaunched.descendants(matching: .any)["gateModePicker"].firstMatch
        XCTAssertTrue(shown.waitForExistence(timeout: 20))
        XCTAssertTrue(wait(15) { shown.label.contains("Complete") },
                      "the chunking mode was not remembered across a relaunch (showing \"\(shown.label)\")")

        relaunched.buttons["resetSettings"].firstMatch.tap()
        XCTAssertTrue(wait(15) { shown.label.contains("Balanced") },
                      "reset did not restore the default chunking mode (showing \"\(shown.label)\")")
    }

    func testSendLogsFromSettingsOpensTheNativeShareSheet() {
        let app = launch()
        openSettings(app)

        let share = app.buttons["shareLogsSettings"]
        XCTAssertTrue(share.waitForExistence(timeout: 20), "the send-logs row is missing")
        share.tap()

        let markers = ["ActivityListView", "Copy", "Save to Files", "Mail", "Messages", "Print", "Markup"]
        let shown = wait(30) { markers.contains { app.descendants(matching: .any)[$0].exists } }
        XCTAssertTrue(shown, "the native share sheet never appeared from Settings")
    }
}
