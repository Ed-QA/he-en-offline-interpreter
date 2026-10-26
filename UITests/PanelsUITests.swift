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

    /// The Hebrew panel was a fixed 110 pt strip next to a flexible English slab. With both
    /// panels flexible their heights follow their content, so the shared width and the layout
    /// order are what "the same size" means here.
    func testBothPanelsAreTheSameSize() {
        let app = launch()
        // Look the panels up by their own identifiers: `descendants(matching: .any)` walks the
        // whole tree and was slow enough to hit the 120 s per-test allowance in CI.
        let hebrew = app.otherElements["hebrewPanel"].firstMatch
        let english = app.otherElements["englishPanel"].firstMatch
        XCTAssertTrue(hebrew.waitForExistence(timeout: 20), "the Hebrew panel is missing")
        XCTAssertTrue(english.waitForExistence(timeout: 20), "the English panel is missing")

        XCTAssertEqual(hebrew.frame.width, english.frame.width, accuracy: 2,
                       "the panels are not the same width")
        XCTAssertLessThanOrEqual(hebrew.frame.maxY, english.frame.minY,
                                 "the Hebrew panel must sit above the English panel")
    }
}
