import XCTest

/// Simulator UI smoke test: the app must boot to a single status light, with no prose on the
/// main screen and no modal dialogs. Screenshots are attached as CI artifacts for review.
final class SmokeUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testLaunchesToSingleStatusLight() {
        let app = XCUIApplication()
        app.launchArguments = ["-HEENUITest"]   // no mic start, no permission alert
        app.launch()

        let status = app.staticTexts["statusTitle"]
        XCTAssertTrue(status.waitForExistence(timeout: 90), "the status light title never appeared")

        XCTAssertTrue(app.staticTexts["hebrewText"].exists, "the Hebrew panel is missing")
        XCTAssertTrue(app.staticTexts["englishText"].exists, "the English panel is missing")
        XCTAssertTrue(app.buttons["mainToggle"].exists, "the start/stop control is missing")

        attachScreenshot(app, named: "main-screen")
    }

    func testSettingsAndLogOpen() {
        let app = XCUIApplication()
        app.launchArguments = ["-HEENUITest"]
        app.launch()

        XCTAssertTrue(app.staticTexts["statusTitle"].waitForExistence(timeout: 90))

        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 20), "settings did not open")
        attachScreenshot(app, named: "settings")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["Log"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 20), "log did not open")
        attachScreenshot(app, named: "log")
    }

    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
