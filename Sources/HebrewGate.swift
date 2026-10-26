import Foundation

/// Hebrew-only real-time "is this sentence complete by logic and sense?" gate.
/// Pure, deterministic, unit-testable. No network, no model, no state beyond config.
struct HebrewCompletenessGate {
    var mode: GateMode = .balanced

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

        let terminal = TextUtil.hasTerminalPunctuation(text)
        let commaEnd = text.trimmingCharacters(in: .whitespaces).hasSuffix(",")
        let unbalanced = TextUtil.hasUnbalancedQuotes(text)
        let lastIsNeverEnd = HebrewCompletenessGate.neverEnd.contains(last)

        var score = 0
        var notes: [String] = []

        if terminal { score += 2; notes.append("terminal-punct") }
        if isSTTFinal { score += 1; notes.append("stt-final") }
        if trailingSilence >= mode.silenceToEmit { score += 1; notes.append("pause") }
        if words.count >= 4 { score += 1; notes.append("length-ok") }
        // The anti-fragment penalties below only make sense *while* the utterance is still open.
        // At a real STT endpoint a one-word answer ("כן", "תודה", "מים") is a complete utterance
        // and must not be scored down for being short.
        if words.count < 3, !isSTTFinal { score -= 2; notes.append("too-short") }
        if commaEnd { score -= 2; notes.append("comma-end") }
        if unbalanced { score -= 3; notes.append("open-quote") }
        if lastIsNeverEnd { score -= 4; notes.append("dangling:\(last)") }
        if last.count <= 2, !terminal, !isSTTFinal { score -= 1; notes.append("tiny-tail") }
        if HebrewCompletenessGate.subordinators.contains(first), words.count < 5, !terminal {
            score -= 1; notes.append("open-subordinate")
        }
        if HebrewCompletenessGate.questionWords.contains(first), (terminal || trailingSilence >= mode.silenceToEmit) {
            score += 1; notes.append("question-closed")
        }
        // Hebrew prefixes glued to a word are fine; a standalone prefix token is not.
        if ["ב", "ל", "מ", "כ", "ה", "ו", "ש"].contains(last) { score -= 4; notes.append("bare-prefix") }

        let hardBlocked = lastIsNeverEnd || unbalanced
        // A real endpoint is evidence that the speaker finished: any positive score emits, so a
        // short-but-final answer is never swallowed. Dangling connectors stay blocked either way.
        let passed = (score >= mode.scoreThreshold || (isSTTFinal && score >= 1)) && !hardBlocked
        let forced = pendingAge >= mode.maxPendingAge && words.count >= 3 && !hardBlocked
        let escape = pendingAge >= mode.hardMaxAge && words.count >= 3

        if passed { return Outcome(emit: true, forced: false, score: score, reason: notes.joined(separator: ",")) }
        if forced || escape { return Outcome(emit: true, forced: true, score: score, reason: "forced:" + notes.joined(separator: ",")) }
        return Outcome(emit: false, forced: false, score: score, reason: notes.joined(separator: ","))
    }
}
