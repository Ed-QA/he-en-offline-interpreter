import Foundation

/// Hebrew-only real-time "is this sentence complete by logic and sense?" gate.
/// Pure, deterministic, unit-testable. No network, no model, no state beyond config.
struct HebrewCompletenessGate {
    /// Fixed thresholds — one behaviour, no user-facing chunking mode. A sentence is emitted when it
    /// is complete by logic and sense; that is the intent, and it is not a setting. How speech is cut
    /// into windows belongs to the recogniser (2.0 s window, 1.7 s stride), not to this gate.
    static let silenceToEmit: TimeInterval = 0.7
    static let scoreThreshold = 2
    static let maxPendingAge: TimeInterval = 6.0
    static let hardMaxAge: TimeInterval = 9.0

    struct Outcome: Equatable {
        let emit: Bool
        let forced: Bool
        let score: Int
        let reason: String
    }

    // Words that can never END a sense-complete Hebrew sentence.
    static let neverEnd: Set<String> = [
        "ו", "או", "אבל", "אך", "אלא", "כי", "ש", "אם", "אז", "לכן", "בגלל", "מכיוון", "משום",
        "כדי", "כמו", "כאשר", "כש", "לפני", "אחרי", "בזמן", "עד", "בלי", "עם", "על", "אל",
        "מן", "בין", "אצל", "ליד", "מול", "תחת", "מעל", "לתוך", "מתוך", "לפי", "נגד", "עבור",
        "בשביל", "בעקבות", "לקראת", "כנגד", "תוך", "בעוד", "כלומר", "אולי", "גם", "רק",
        "אפילו", "הרי", "אמנם", "אולם", "בערך", "כמעט", "של", "את", "כל", "כמה", "יותר",
        "פחות", "מאוד", "נורא", "ממש", "בדיוק", "עוד", "כבר", "היה", "הייתה", "הייתי",
        "היית", "היינו", "הייתם", "היו", "יהיה", "תהיה", "צריך", "צריכה", "יכול", "יכולה",
        "רוצה", "רוצים", "הולך", "הולכת", "באים", "בא", "עומד", "עומדת", "אמור", "אמורה",
        "בגללו", "בגללה", "למרות", "במקום", "כדי_ש", "מפני", "בשל", "עבור_ש", "בלי_ש"
    ]

    // Openers that REQUIRE a following clause to be complete.
    static let subordinators: Set<String> = [
        "אם", "כאשר", "כש", "בגלל", "מכיוון", "משום", "כדי", "למרות", "לפני", "אחרי",
        "בזמן", "בעוד", "עד", "בלי", "במקום", "מפני", "בשל", "אלא", "אף"
    ]

    static let questionWords: Set<String> = [
        "האם", "מה", "למה", "מדוע", "איך", "איפה", "מתי", "מי", "כמה", "איזה", "איזו",
        "לאן", "מאיפה", "באיזה", "באיזו", "למה_כך"
    ]

    func evaluate(_ raw: String,
                  trailingSilence: TimeInterval,
                  isSTTFinal: Bool,
                  pendingAge: TimeInterval) -> Outcome {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return Outcome(emit: false, forced: false, score: 0, reason: "empty") }

        let words = TextUtil.tokenize(text)
        guard let lastRaw = words.last else { return Outcome(emit: false, forced: false, score: 0, reason: "empty") }
        let last = TextUtil.stripEdges(lastRaw)
        let first = TextUtil.stripEdges(words.first ?? "")
        // Every lookup below is against unpointed word lists, and a pointed word counted in scalars
        // is never "2 characters or fewer". The rules are matched on the bare form; the text that
        // leaves this gate keeps its points.
        let lastBare = TextUtil.stripNikud(last)
        let firstBare = TextUtil.stripNikud(first)

        let terminal = TextUtil.hasTerminalPunctuation(text)
        let commaEnd = text.trimmingCharacters(in: .whitespaces).hasSuffix(",")
        let unbalanced = TextUtil.hasUnbalancedQuotes(text)
        let lastIsNeverEnd = HebrewCompletenessGate.neverEnd.contains(lastBare)

        var score = 0
        var notes: [String] = []

        if terminal { score += 2; notes.append("terminal-punct") }
        if isSTTFinal { score += 1; notes.append("stt-final") }
        if trailingSilence >= Self.silenceToEmit { score += 1; notes.append("pause") }
        if words.count >= 4 { score += 1; notes.append("length-ok") }
        // The anti-fragment penalties below only make sense *while* the utterance is still open.
        // At a real STT endpoint a one-word answer ("כן", "תודה", "מים") is a complete utterance
        // and must not be scored down for being short.
        if words.count < 3, !isSTTFinal { score -= 2; notes.append("too-short") }
        if commaEnd { score -= 2; notes.append("comma-end") }
        if unbalanced { score -= 3; notes.append("open-quote") }
        if lastIsNeverEnd { score -= 4; notes.append("dangling:\(last)") }
        if lastBare.count <= 2, !terminal, !isSTTFinal { score -= 1; notes.append("tiny-tail") }
        if HebrewCompletenessGate.subordinators.contains(firstBare), words.count < 5, !terminal {
            score -= 1; notes.append("open-subordinate")
        }
        if HebrewCompletenessGate.questionWords.contains(firstBare), (terminal || trailingSilence >= Self.silenceToEmit) {
            score += 1; notes.append("question-closed")
        }
        // Hebrew prefixes glued to a word are fine; a standalone prefix token is not.
        if ["ב", "ל", "מ", "כ", "ה", "ו", "ש"].contains(lastBare) { score -= 4; notes.append("bare-prefix") }

        let hardBlocked = lastIsNeverEnd || unbalanced
        // A real endpoint is evidence that the speaker finished: any positive score emits, so a
        // short-but-final answer is never swallowed. Dangling connectors stay blocked either way.
        let passed = (score >= Self.scoreThreshold || (isSTTFinal && score >= 1)) && !hardBlocked
        let forced = pendingAge >= Self.maxPendingAge && words.count >= 3 && !hardBlocked
        let escape = pendingAge >= Self.hardMaxAge && words.count >= 3

        if passed { return Outcome(emit: true, forced: false, score: score, reason: notes.joined(separator: ",")) }
        if forced || escape { return Outcome(emit: true, forced: true, score: score, reason: "forced:" + notes.joined(separator: ",")) }
        return Outcome(emit: false, forced: false, score: score, reason: notes.joined(separator: ","))
    }
}
