import XCTest

/// Simulator UI smoke test: the app must boot to a single status light, with no prose on the
/// main screen and no modal dialogs. Screenshots are attached as CI artifacts for review.
final class SmokeUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// The controls are only meaningful once the models are loaded: a tap that lands while the app
    /// is still STARTING can be swallowed, which is how `testSettingsAndLogOpen` flaked in CI.
    private func waitForReady(_ app: XCUIApplication) {
        let status = app.buttons["mainToggle"]
        XCTAssertTrue(status.waitForExistence(timeout: 90), "the start/stop control never appeared")
        let ready = expectation(for: NSPredicate(format: "value == %@", "READY"), evaluatedWith: status)
        wait(for: [ready], timeout: 180)
    }

    func testLaunchesToSingleStatusLight() {
        let app = XCUIApplication()
        app.launchArguments = ["-HEENUITest"]   // no mic start, no permission alert
        app.launch()

        let status = app.buttons["mainToggle"]
        XCTAssertTrue(status.waitForExistence(timeout: 90), "the start/stop control never appeared")

        XCTAssertTrue(app.staticTexts["hebrewText"].exists, "the Hebrew panel is missing")
        XCTAssertTrue(app.staticTexts["englishText"].exists, "the English panel is missing")
        XCTAssertTrue(app.buttons["mainToggle"].exists, "the start/stop control is missing")

        attachScreenshot(app, named: "main-screen")
    }

    func testSettingsAndLogOpen() {
        let app = XCUIApplication()
        app.launchArguments = ["-HEENUITest"]
        app.launch()

        waitForReady(app)

        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 20), "settings did not open")
        attachScreenshot(app, named: "settings")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["Log"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 20), "log did not open")
        attachScreenshot(app, named: "log")
    }

    /// Design-review tour: every screen, kept as a CI artifact. The wait for READY matters — a
    /// shot taken while the models are still loading would show the STARTING… placeholder and
    /// hide the real layout.
    func testScreenshotTour() {
        let app = XCUIApplication()
        app.launchArguments = ["-HEENUITest"]
        app.launch()

        waitForReady(app)

        attachScreenshot(app, named: "01-main-ready")

        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 20), "settings did not open")
        attachScreenshot(app, named: "02-settings-top")

        // The form is taller than the screen: scroll so the lower sections and the footer are
        // proven to render instead of being silently clipped. The dark-mode run uses large
        // accessibility text, which makes the form taller still, so keep scrolling until the
        // footer exists rather than assuming a fixed number of swipes.
        let footer = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS %@", "Total offline"))
            .firstMatch
        app.swipeUp()
        attachScreenshot(app, named: "03-settings-mid")
        for _ in 0..<6 where !footer.exists {
            app.swipeUp()
        }
        attachScreenshot(app, named: "04-settings-bottom")
        XCTAssertTrue(footer.exists,
                      "the offline footer is missing — the form is clipped or a section failed to render")

        app.navigationBars.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Log"].firstMatch.waitForExistence(timeout: 20), "settings did not close")

        app.buttons["Log"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 20), "log did not open")
        // No sentence is emitted in UI-test mode, so this screen must fall back to the live trace.
        XCTAssertTrue(
            app.scrollViews.firstMatch.staticTexts.firstMatch.waitForExistence(timeout: 20),
            "the log screen is blank — the trace fallback is not working")
        attachScreenshot(app, named: "05-log")
        app.navigationBars.buttons["Close"].firstMatch.tap()
    }

    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
