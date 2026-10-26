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

    /// A picker exposes its selection as the element label, as its value, or as a separate static
    /// text depending on the style - accept any of them, so the assertion tests the setting and
    /// not the rendering.
    private func shows(_ app: XCUIApplication, _ picker: XCUIElement, _ text: String) -> Bool {
        if picker.label.contains(text) { return true }
        if let value = picker.value as? String, value.contains(text) { return true }
        return app.staticTexts[text].exists || app.buttons[text].exists
    }

    /// The settings form is lazy: a row below the fold does not exist until it is scrolled into
    /// view, so every lookup has to scroll first (the "missing" rows were simply off screen).
    /// The scan is capped: a long scan per lookup was slow enough to blow the 120 s per-test
    /// allowance in CI.
    private func scrollTo(_ app: XCUIApplication, _ id: String, maxSwipes: Int = 4) -> XCUIElement {
        var element = app.descendants(matching: .any)[id].firstMatch
        if element.exists && element.isHittable { return element }
        for _ in 0..<maxSwipes {
            app.swipeUp()
            element = app.descendants(matching: .any)[id].firstMatch
            if element.exists && element.isHittable { return element }
        }
        for _ in 0..<maxSwipes {
            app.swipeDown()
            element = app.descendants(matching: .any)[id].firstMatch
            if element.exists && element.isHittable { return element }
        }
        return element
    }

    /// Everything a user actually needs: pick a voice, set the rate, hear it, choose how the app
    /// chunks speech, send the logs, reset. The developer tools stay reachable but separate.
    func testSettingsOffersTheNeededControls() {
        let app = launch()
        openSettings(app)

        // The form is lazy, so walk it once and collect what shows up, instead of scanning for
        // every row separately: the old per-row scan (10 swipes down + 10 up, at slow velocity)
        // was expensive enough to blow the 120 s per-test allowance in CI.
        let wanted: Set<String> = ["voicePicker", "rateSlider", "testVoice", "gateModePicker",
                                   "shareLogsSettings", "resetSettings", "Developer"]
        var seen = Set<String>()
        for _ in 0..<6 {
            let identifiers = app.descendants(matching: .any).allElementsBoundByIndex.map(\.identifier)
            seen.formUnion(identifiers.filter { wanted.contains($0) })
            if seen == wanted { break }
            app.swipeUp()
        }
        for id in wanted.sorted() {
            XCTAssertTrue(seen.contains(id), "\(id) is missing from Settings")
        }
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
        let shown = scrollTo(relaunched, "gateModePicker")
        XCTAssertTrue(shown.waitForExistence(timeout: 20))
        XCTAssertTrue(wait(15) { shows(relaunched, shown, "Complete") },
                      "the chunking mode was not remembered across a relaunch (picker says \"\(shown.label)\")")

        let reset = scrollTo(relaunched, "resetSettings")
        XCTAssertTrue(reset.waitForExistence(timeout: 10), "the reset row is missing")
        reset.tap()
        _ = scrollTo(relaunched, "gateModePicker")   // back up: the form is lazy
        XCTAssertTrue(wait(15) { shows(relaunched, shown, "Balanced") },
                      "reset did not restore the default chunking mode (picker says \"\(shown.label)\")")
    }

    func testSendLogsFromSettingsOpensTheNativeShareSheet() {
        let app = launch()
        openSettings(app)

        let share = scrollTo(app, "shareLogsSettings")
        XCTAssertTrue(share.waitForExistence(timeout: 10), "the send-logs row is missing")
        share.tap()

        let markers = ["ActivityListView", "Copy", "Save to Files", "Mail", "Messages", "Print", "Markup"]
        let shown = wait(30) { markers.contains { app.descendants(matching: .any)[$0].exists } }
        XCTAssertTrue(shown, "the native share sheet never appeared from Settings")
    }
}
