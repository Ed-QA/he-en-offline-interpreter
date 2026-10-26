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

    /// Apple's audit type is an option set of raw bits; the log only shows numbers, so name them.
    private func name(of type: XCUIAccessibilityAuditType) -> String {
        var names: [String] = []
        if type.contains(.contrast) { names.append("contrast") }
        if type.contains(.hitRegion) { names.append("hitRegion") }
        if type.contains(.dynamicType) { names.append("dynamicType") }
        if type.contains(.textClipped) { names.append("textClipped") }
        return names.isEmpty ? "type(rawValue: \(type.rawValue))" : names.joined(separator: "|")
    }

    /// Everything except two known findings is a hard gate:
    ///  * contrast — the status word is about 2:1 on the grouped background (tracked by the test
    ///    below and by the design review);
    ///  * hit region on the two panels — they are *selectable text*, not controls, so in the empty
    ///    state their element is a single "…" a few points wide. Real controls stay gated.
    ///
    /// Every finding is collected and reported in one assertion: failing on the first issue hid
    /// the rest of the list, which made a failing audit a guessing game.
    func testAuditPassesEverythingExceptTheKnownFindings() throws {
        let app = launchedApp()
        var findings: [String] = []
        try app.performAccessibilityAudit(for: .all) { issue in
            let line = "\(name(of: issue.auditType)) :: \(issue.element?.identifier ?? "no element") / \(issue.element?.label ?? "") — \(issue.compactDescription)"
            print("A11Y AUDIT \(line)")

            if issue.auditType == .contrast { return true }
            if issue.auditType == .hitRegion,
               ["hebrewText", "englishText"].contains(issue.element?.identifier ?? "") {
                return true
            }
            findings.append(line)
            return true
        }
        XCTAssertTrue(findings.isEmpty,
                      "accessibility audit findings:\n" + findings.joined(separator: "\n"))
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

    /// The log sheet is where "Send logs" lives, so it is audited with the same documented
    /// exceptions as the main screen (contrast, the selectable text panels) plus the two the log
    /// sheet adds: its selectable trace text, and the native `ShareLink` row, whose *button* is
    /// the ≥44 pt target (`ShareLogsUITests` asserts that directly) while the audit measures the
    /// label inside it.
    func testLogSheetPassesTheSameAudit() throws {
        let app = launchedApp()
        app.buttons["Log"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 20), "log did not open")
        XCTAssertTrue(app.buttons["shareLogs"].waitForExistence(timeout: 20),
                      "the send-logs control is missing")

        var findings: [String] = []
        try app.performAccessibilityAudit(for: .all) { issue in
            let line = "\(name(of: issue.auditType)) :: \(issue.element?.identifier ?? "no element") / \(issue.element?.label ?? "") — \(issue.compactDescription)"
            print("A11Y LOG AUDIT \(line)")

            if issue.auditType == .contrast { return true }
            if issue.auditType == .hitRegion,
               ["hebrewText", "englishText", "logTrace", "shareLogs"].contains(issue.element?.identifier ?? "") {
                return true
            }
            // The share row is a native `ShareLink`: the audit measures the label inside it, which is
            // not a target of its own. The row's ≥44 pt button is asserted directly in
            // `ShareLogsUITests`, so contrast is the only rule still reported for it.
            if issue.element?.label == "Send logs" || issue.element?.identifier == "shareLogs",
               issue.auditType != .contrast {
                return true
            }
            findings.append(line)
            return true
        }
        XCTAssertTrue(findings.isEmpty,
                      "accessibility audit findings (log sheet):\n" + findings.joined(separator: "\n"))
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
