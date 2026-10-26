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
    /// view, so every lookup scrolls first — down, then back up. The dark-mode CI run uses
    /// accessibility-extra-large text, where the form is several screens tall and even the upper
    /// rows start below the fold, so the swipes are fast and the cap is generous; the scan is still
    /// capped, because a long scan per lookup was slow enough to blow the per-test allowance in CI.
    /// Existence is the condition, not hittability: a fast swipe can overshoot, and a row that
    /// exists but sits under an edge is nudged back into view instead of being swiped past.
    private func scrollTo(_ app: XCUIApplication, _ id: String, maxSwipes: Int = 8) -> XCUIElement {
        scrollTo(app, app.descendants(matching: .any)[id].firstMatch, maxSwipes: maxSwipes)
    }

    /// The same lookup for an element that is only known by what it is (a section header exposes its
    /// title as a label, not as an identifier).
    private func scrollTo(_ app: XCUIApplication, _ element: XCUIElement, maxSwipes: Int = 8) -> XCUIElement {
        for _ in 0..<maxSwipes {
            if element.exists { return nudge(app, element) }
            app.swipeUp(velocity: .fast)
        }
        for _ in 0..<maxSwipes {
            if element.exists { return nudge(app, element) }
            app.swipeDown(velocity: .fast)
        }
        return element
    }

    /// One slow swipe back towards the row when it exists but is not tappable where it sits. If that
    /// swipe takes the row back out of the realised window, it is undone.
    private func nudge(_ app: XCUIApplication, _ element: XCUIElement) -> XCUIElement {
        guard element.exists, !element.isHittable else { return element }
        app.swipeDown(velocity: .slow)
        if !element.exists {
            app.swipeUp(velocity: .slow)
        }
        return element
    }

    /// Everything a user actually needs: pick a voice, set the rate, hear it, choose how the app
    /// chunks speech, send the logs, reset. The developer tools stay reachable but separate.
    func testSettingsOffersTheNeededControls() {
        let app = launch()
        openSettings(app)

        // Rows above the fold at the default text size. The lookup is targeted (one identifier, not
        // a snapshot per pass): the earlier scan (10 swipes down + 10 up per row, then a snapshot
        // per pass) took 110 s and hit the per-test allowance in CI. It still scrolls first, because
        // the dark-mode run uses large text, where even these rows start below the fold.
        for id in ["voicePicker", "rateSlider", "testVoice", "gateModePicker"] {
            XCTAssertTrue(scrollTo(app, id).waitForExistence(timeout: 5),
                          "\(id) is missing from Settings")
        }

        // The form is lazy, so the tail of the list only exists after a scroll.
        for id in ["shareLogsSettings", "resetSettings"] {
            XCTAssertTrue(scrollTo(app, id).waitForExistence(timeout: 5),
                          "\(id) is missing from Settings")
        }
        // A section header exposes its title as a label, not as an identifier, and at large text
        // sizes it sits below the reset row that the loop above stopped at.
        XCTAssertTrue(scrollTo(app, app.staticTexts["Developer"].firstMatch).waitForExistence(timeout: 5),
                      "the developer section is missing")
    }

    func testHearThisVoiceIsSafeToTap() {
        let app = launch()
        openSettings(app)
        let test = scrollTo(app, "testVoice")
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

        let picker = scrollTo(app, "gateModePicker")
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
