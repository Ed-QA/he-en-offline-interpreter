import XCTest

/// The native "send logs" path: the Log sheet offers a share control that opens the iOS share
/// sheet (Mail, Messages, AirDrop, Save to Files). The sheet's chrome differs between iOS builds,
/// so the assertions accept any of the stable markers instead of one exact element.
final class ShareLogsUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HEENUITest"]
        app.launch()
        XCTAssertTrue(app.staticTexts["statusTitle"].waitForExistence(timeout: 90),
                      "the status light never appeared")
        return app
    }

    private func openLog(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["Log"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 20), "log did not open")
        let share = app.buttons["shareLogs"]
        XCTAssertTrue(share.waitForExistence(timeout: 20),
                      "the send-logs control is missing from the log sheet")
        return share
    }

    func testLogSheetOpensTheNativeShareSheet() {
        let app = launchedApp()
        let share = openLog(app)

        XCTAssertGreaterThanOrEqual(share.frame.height, 44, "the send-logs control is shorter than 44 pt")
        share.tap()

        XCTAssertTrue(waitForShareSheet(app), "the native share sheet never appeared")
        attach(app, named: "share-sheet")
    }

    /// The exported file has to be there before the sheet can hand it on: the sheet shows the file
    /// name, so a missing file shows up as an empty share.
    func testShareSheetCarriesTheExportedReport() {
        let app = launchedApp()
        openLog(app).tap()
        XCTAssertTrue(waitForShareSheet(app), "the native share sheet never appeared")

        let file = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ OR label CONTAINS %@", "log-", ".txt"))
            .firstMatch
        XCTAssertTrue(file.exists, "the share sheet does not show the exported log file")
        attach(app, named: "share-sheet-file")
    }

    private func waitForShareSheet(_ app: XCUIApplication) -> Bool {
        let markers = ["ActivityListView", "Copy", "Save to Files", "Mail", "Messages", "Print", "Markup"]
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            for marker in markers where app.descendants(matching: .any)[marker].exists {
                return true
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return false
    }

    private func attach(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
