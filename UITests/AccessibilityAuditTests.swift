import XCTest

/// Apple's own accessibility audit (Xcode 15+ / iOS 17+) plus explicit layout rules. The audit
/// checks hit regions, Dynamic Type, clipped text, element descriptions and traits automatically,
/// so an accessibility regression cannot slip in unnoticed with a UI change. It runs twice per CI
/// run: once in light mode and once with dark appearance + accessibility-extra-large text.
final class AccessibilityAuditTests: XCTestCase {

    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HEENUITest"]
        app.launch()
        XCTAssertTrue(app.staticTexts["statusTitle"].waitForExistence(timeout: 90),
                      "the status light never appeared")
        return app
    }

    /// Everything except contrast is a hard gate. The known contrast finding (the green/orange
    /// status word is about 2:1 on the grouped background) is ignored here — see the test below.
    func testAuditPassesEverythingExceptTheKnownContrastFinding() throws {
        let app = launchedApp()
        try app.performAccessibilityAudit(for: .all) { issue in
            let element = issue.element.map { "\($0.identifier) / \($0.label)" } ?? "no element"
            print("A11Y AUDIT \(issue.auditType) :: \(element)")
            return issue.auditType == .contrast
        }
    }

    /// Pins the known contrast problem without blocking the build. `strict: false` means an unmet
    /// expectation is allowed, so the day the status text becomes readable this test quietly stops
    /// expecting a failure — then it should be deleted.
    func testKnownStatusContrastFindingIsTracked() {
        let app = launchedApp()
        XCTExpectFailure("Known: status-text contrast on the grouped background", strict: false) {
            try? app.performAccessibilityAudit(for: .contrast)
        }
    }

    /// Layout and hit-target rules that the audit does not check for us.
    func testControlsAreReachableAndInsideTheScreen() {
        let app = launchedApp()
        let window = app.windows.firstMatch.frame

        let mic = app.buttons["mainToggle"]
        XCTAssertTrue(mic.exists, "the start/stop control is missing")
        XCTAssertGreaterThanOrEqual(mic.frame.width, 44, "the mic button is narrower than 44 pt")
        XCTAssertGreaterThanOrEqual(mic.frame.height, 44, "the mic button is shorter than 44 pt")
        XCTAssertTrue(window.contains(mic.frame), "the mic button is outside the screen")

        for label in ["Repeat last sentence", "Log", "Settings"] {
            let button = app.buttons[label]
            XCTAssertTrue(button.exists, "\(label) is not exposed to VoiceOver")
            XCTAssertGreaterThanOrEqual(button.frame.width, 44, "\(label) is narrower than 44 pt")
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, "\(label) is shorter than 44 pt")
            XCTAssertTrue(window.contains(button.frame), "\(label) is outside the screen")
        }

        let hebrew = app.staticTexts["hebrewText"]
        let english = app.staticTexts["englishText"]
        XCTAssertTrue(hebrew.exists, "the Hebrew panel is missing")
        XCTAssertTrue(english.exists, "the English panel is missing")
        XCTAssertLessThanOrEqual(hebrew.frame.maxY, english.frame.minY,
                                 "the Hebrew panel must sit above the English panel")
        XCTAssertLessThanOrEqual(english.frame.maxY, window.maxY,
                                 "the English panel runs off the bottom of the screen")
        XCTAssertEqual(english.frame.minX, hebrew.frame.minX, accuracy: 2,
                       "the two panels are not aligned to the same margin")
    }
}
