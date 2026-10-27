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
        XCTAssertTrue(app.buttons["mainToggle"].waitForExistence(timeout: 90),
                      "the start/stop control never appeared")
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

    /// The Hebrew panel was a fixed 110 pt strip next to a flexible English slab. With both panels
    /// flexible they share the width and split the height. Panel *element* frames are the union of
    /// their scrollable content, which overstates their height, so the stable checks are the shared
    /// width and the Hebrew-above-English order taken from the panel texts.
    func testBothPanelsAreTheSameSize() {
        let app = launch()
        let hebrew = app.descendants(matching: .any)["hebrewPanel"].firstMatch
        let english = app.descendants(matching: .any)["englishPanel"].firstMatch
        XCTAssertTrue(hebrew.waitForExistence(timeout: 20), "the Hebrew panel is missing")
        XCTAssertTrue(english.waitForExistence(timeout: 20), "the English panel is missing")

        XCTAssertEqual(hebrew.frame.width, english.frame.width, accuracy: 2,
                       "the panels are not the same width: \(hebrew.frame.width) vs \(english.frame.width)")

        let hebrewText = app.staticTexts["hebrewText"]
        let englishText = app.staticTexts["englishText"]
        XCTAssertTrue(hebrewText.exists, "the Hebrew panel text is missing")
        XCTAssertTrue(englishText.exists, "the English panel text is missing")
        XCTAssertLessThanOrEqual(hebrewText.frame.maxY, englishText.frame.minY,
                                 "the Hebrew panel must sit above the English panel")
    }
}
