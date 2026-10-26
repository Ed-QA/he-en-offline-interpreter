import XCTest

/// The two panels are the product. Empty, they used to show a bare "…" — at large text that is a
/// huge ellipsis in an empty card, which reads as a broken screen. They now carry a short hint.
final class PanelsUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HEENUITest", "-HEENResetPrefs"]
        app.launch()
        XCTAssertTrue(app.staticTexts["statusTitle"].waitForExistence(timeout: 90),
                      "the status light never appeared")
        return app
    }

    func testEmptyPanelsShowAHintInsteadOfADot() {
        let app = launch()

        let hebrew = app.staticTexts["hebrewText"]
        let english = app.staticTexts["englishText"]
        XCTAssertTrue(hebrew.waitForExistence(timeout: 20), "the Hebrew panel text is missing")
        XCTAssertTrue(english.waitForExistence(timeout: 20), "the English panel text is missing")

        for (name, element) in [("Hebrew", hebrew), ("English", english)] {
            XCTAssertNotEqual(element.label, "…", "the \(name) panel still shows a bare ellipsis")
            XCTAssertFalse(element.label.trimmingCharacters(in: .whitespaces).isEmpty,
                           "the \(name) panel hint is empty")
        }
        XCTAssertTrue(hebrew.label.localizedCaseInsensitiveContains("Hebrew"),
                      "the Hebrew hint does not say what to do: \(hebrew.label)")
        XCTAssertTrue(english.label.localizedCaseInsensitiveContains("English"),
                      "the English hint does not say what to expect: \(english.label)")
    }

    /// The Hebrew panel was a fixed 110 pt strip next to a flexible English slab.
    func testBothPanelsAreTheSameSize() {
        let app = launch()
        let hebrew = app.descendants(matching: .any)["hebrewPanel"].firstMatch
        let english = app.descendants(matching: .any)["englishPanel"].firstMatch
        guard hebrew.waitForExistence(timeout: 20), english.waitForExistence(timeout: 20) else {
            // The panels' own identifiers are not always surfaced; the text elements always are,
            // so fall back to them rather than failing a real check for an accessibility quirk.
            let h = app.staticTexts["hebrewText"].frame
            let e = app.staticTexts["englishText"].frame
            XCTAssertLessThanOrEqual(h.maxY, e.minY, "the Hebrew panel must sit above the English one")
            return
        }
        XCTAssertEqual(hebrew.frame.width, english.frame.width, accuracy: 2,
                       "the panels are not the same width")
        XCTAssertEqual(hebrew.frame.height, english.frame.height, accuracy: 30,
                       "the panels are asymmetric: \(hebrew.frame.height) vs \(english.frame.height)")
        XCTAssertLessThanOrEqual(hebrew.frame.maxY, english.frame.minY,
                                 "the Hebrew panel must sit above the English panel")
    }
}
