import XCTest
@testable import HEENInterpreter

/// The pipeline contract: the translator only ever sees **pointed** Hebrew, so every
/// recognised sentence is diacritized first (`Sources/Nikud.swift`, phonikud int8 ONNX).
/// These tests pin the port of `phonikud_onnx/model.py` — the pure part runs anywhere, the
/// last test runs the real model in the simulator when the bundle carries it.
final class NikudTests: XCTestCase {

    // MARK: - Class table (the order IS the argmax index)

    func testNikudClassTableMatchesReference() {
        XCTAssertEqual(NikudRestorer.nikudClasses.count, 29)
        XCTAssertEqual(NikudRestorer.nikudClasses[0], "")
        XCTAssertEqual(NikudRestorer.nikudClasses[1], "<MAT_LECT>")
        XCTAssertEqual(NikudRestorer.nikudClasses[2], "\u{05BC}")            // dagesh
        XCTAssertEqual(NikudRestorer.nikudClasses[11], "\u{05B8}")           // kamatz
        XCTAssertEqual(NikudRestorer.nikudClasses[15], "\u{05BC}\u{05B0}")   // dagesh + shva
        XCTAssertEqual(NikudRestorer.nikudClasses[28], "\u{05BC}\u{05C7}")   // dagesh + kamatz katan
        XCTAssertEqual(NikudRestorer.shinClasses, ["\u{05C1}", "\u{05C2}"])
    }

    // MARK: - Rebuilding the pointed sentence

    func testAppliesNikudAndShinDotToHebrewLetters() {
        // "shalom": shin gets the shin dot, lamed the dagesh, vav the holam, mem nothing
        let chars: [Character] = ["\u{05E9}", "\u{05DC}", "\u{05D5}", "\u{05DD}"]
        let out = NikudRestorer.apply(chars: chars,
                                      nikudClass: [10, 2, 12, 0],
                                      shinClass: [0, 0, 0, 0],
                                      stress: [false, false, false, false],
                                      vocalShva: [false, false, false, false],
                                      prefix: [false, false, false, false],
                                      markMatresLectionis: nil)
        let expected = "\u{05E9}\u{05C1}\u{05B7}" + "\u{05DC}\u{05BC}" + "\u{05D5}\u{05B9}" + "\u{05DD}"
        XCTAssertEqual(out, expected)
    }

    func testShinDotIsNeverAddedToOtherLetters() {
        let out = NikudRestorer.apply(chars: ["\u{05DC}"],
                                      nikudClass: [0],
                                      shinClass: [1],       // model says sin dot …
                                      stress: [false], vocalShva: [false], prefix: [false],
                                      markMatresLectionis: nil)
        XCTAssertEqual(out, "\u{05DC}")                   // … but lamed must not get it
    }

    func testMatresLectionisRules() {
        // matres on a vav without a marker: the letter stays bare, nothing is added
        XCTAssertEqual(NikudRestorer.apply(chars: ["\u{05D5}"],
                                           nikudClass: [1],
                                           shinClass: [0],
                                           stress: [false], vocalShva: [false], prefix: [false],
                                           markMatresLectionis: nil),
                       "\u{05D5}")
        // with a marker the mark is appended (phonikud's NIKUD_HASER_DIACRITIC = masora U+05AF)
        XCTAssertEqual(NikudRestorer.apply(chars: ["\u{05D5}"],
                                           nikudClass: [1],
                                           shinClass: [0],
                                           stress: [false], vocalShva: [false], prefix: [false],
                                           markMatresLectionis: "\u{05AF}"),
                       "\u{05D5}\u{05AF}")
        // matres is impossible on any other letter: the class collapses to "no nikud"
        XCTAssertEqual(NikudRestorer.apply(chars: ["\u{05DC}"],
                                           nikudClass: [1],
                                           shinClass: [0],
                                           stress: [false], vocalShva: [false], prefix: [false],
                                           markMatresLectionis: "\u{05AF}"),
                       "\u{05DC}")
    }

    func testAdditionalHeadsAppendStressVocalShvaAndPrefix() {
        let out = NikudRestorer.apply(chars: ["\u{05DC}"],
                                      nikudClass: [7],                     // hiriq
                                      shinClass: [0],
                                      stress: [true], vocalShva: [true], prefix: [true],
                                      markMatresLectionis: nil)
        XCTAssertEqual(out, "\u{05DC}\u{05B4}\u{05AB}\u{05BD}|")
    }

    func testNonHebrewTextIsUntouched() {
        let chars: [Character] = Array("Hello 42 ")
        let out = NikudRestorer.apply(chars: chars,
                                      nikudClass: [Int](repeating: 11, count: chars.count),
                                      shinClass: [Int](repeating: 0, count: chars.count),
                                      stress: [Bool](repeating: true, count: chars.count),
                                      vocalShva: [Bool](repeating: true, count: chars.count),
                                      prefix: [Bool](repeating: true, count: chars.count),
                                      markMatresLectionis: nil)
        XCTAssertEqual(out, "Hello 42 ")
    }

    // MARK: - Chunking and preprocessing

    func testChunksStayWithinTheModelLimit() {
        let sentence = String(repeating: "אני רוצה לקנות לחם מחר בבוקר. ", count: 200)  // ~5.8 k chars
        let chunks = NikudRestorer.chunks(of: sentence)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= NikudRestorer.maxChunkLength })
        XCTAssertEqual(chunks.joined(), sentence)
        XCTAssertEqual(NikudRestorer.chunks(of: "שלום עולם"), ["שלום עולם"])
    }

    func testRemoveNikudMatchesPhonikudPreprocessing() {
        // phonikud feeds the model *unpointed* text (its regex is [\u0590-\u05C7|])
        let pointed = "\u{05E9}\u{05C1}\u{05B7}\u{05DC}\u{05D5}\u{05B9}\u{05DD} עולם!"
        XCTAssertEqual(NikudRestorer.removeNikud(pointed), "שלום עולם!")
        XCTAssertEqual(NikudRestorer.removeNikud("a|b"), "ab")
    }

    // MARK: - The real int8 model

    func testRealModelAddsNikud() throws {
        try XCTSkipIf(!NikudModel.missingFiles().isEmpty,
                      "nikud model not bundled — run Tools/prepare_nikud.py")
        let restorer = try NikudRestorer.load()
        let plain = "שלום עולם"
        let pointed = restorer.addDiacritics(plain)
        XCTAssertEqual(NikudRestorer.removeNikud(pointed), plain,
                       "diacritization must not change the letters: '\(pointed)'")
        let marks = pointed.unicodeScalars.filter { (0x05B0...0x05C7).contains($0.value) }
        XCTAssertFalse(marks.isEmpty, "the diacritizer returned unpointed text: '\(pointed)'")
        print("POINTED: \(pointed)")
    }
}
