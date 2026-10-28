import Foundation
import CryptoKit

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    /// Pointed Hebrew (nikud) once the diacritizer has run; the raw transcript until then.
    var hebrew: String
    var english: String
    let forced: Bool
    var complete: Bool { !forced }
}

enum TextUtil {
    /// Merge streaming text with overlap: longest word-level suffix of `a` that is a prefix of `b`.
    static func mergeOverlap(_ a: String, _ b: String) -> String {
        let A = a.split(separator: " ").map(String.init)
        let B = b.split(separator: " ").map(String.init)
        if A.isEmpty { return b }
        if B.isEmpty { return a }
        var best = 0
        let maxK = min(A.count, B.count)
        var k = 1
        while k <= maxK {
            if zip(A.suffix(k), B.prefix(k)).allSatisfy({ sameWord($0.0, $0.1) }) { best = k }
            k += 1
        }
        return (A + B.dropFirst(best)).joined(separator: " ")
    }

    /// Item 2 — the overlap-removal tool. Every recogniser stream (and every partial it sends)
    /// repeats the tail of what was already taken. This drops the repeated words and returns only
    /// the new tail, so one valid sentence is left instead of the same words twice.
    static func dropOverlap(previous: String, next: String) -> String {
        let p = tokenize(previous)
        let n = tokenize(next)
        guard !p.isEmpty, !n.isEmpty else { return next }
        var overlap = 0
        for k in stride(from: min(p.count, n.count), through: 1, by: -1) {
            if zip(p.suffix(k), n.prefix(k)).allSatisfy({ sameWord($0.0, $0.1) }) { overlap = k; break }
        }
        guard overlap > 0 else { return next }
        // The cut is made on the raw string so punctuation and spacing survive untouched.
        var seen = 0
        var index = next.startIndex
        while index < next.endIndex {
            let atWordStart = index == next.startIndex || next[next.index(before: index)] == " "
            if next[index] != " " && atWordStart {
                if seen == overlap { return String(next[index...]) }
                seen += 1
            }
            index = next.index(after: index)
        }
        return ""
    }

    /// Hebrew points: cantillation marks and vowels (U+0591–U+05C7). The bundled translator was
    /// trained on unpointed Hebrew, so the pointed sentence is normalised before translation
    /// (item 5) while the pointed form is what stays on screen (item 4).
    static func stripNikud(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { !(0x0591...0x05C7).contains($0.value) }))
    }

    /// The same word from two lanes is rarely the same string: each lane points the shared 0.3 s
    /// independently, so it can arrive as `שָׁלוֹם` from one lane and `שלום` from the other.
    /// Compared raw, the overlap never matches, the word is not dropped, and it is spoken twice.
    /// Compare without the points; emit with them.
    static func sameWord(_ a: String, _ b: String) -> Bool {
        a == b || stripNikud(a) == stripNikud(b)
    }

    static func tokenize(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
    }

    /// Drops everything in `text` that is already covered by `prefix` (word-aligned).
    /// Used to keep the TTS from ever re-speaking words that were already said.
    static func removePrefix(_ text: String, prefix: String) -> String {
        guard !prefix.isEmpty else { return text }
        let p = tokenize(prefix)
        let t = tokenize(text)
        guard t.count >= p.count else { return text }
        if zip(t.prefix(p.count), p).allSatisfy({ sameWord($0.0, $0.1) }) {
            return t.dropFirst(p.count).joined(separator: " ")
        }
        return text
    }

    static func stripEdges(_ w: String) -> String {
        let junk = CharacterSet(charactersIn: ".,!?:;\"'()[]{}\u{05BE}\u{2013}\u{2014}\u{2026}")
        return w.trimmingCharacters(in: junk)
    }

    static func hasTerminalPunctuation(_ s: String) -> Bool {
        guard let last = s.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return ".!?".contains(last)
    }

    static func hasUnbalancedQuotes(_ s: String) -> Bool {
        let doubles = s.filter { $0 == "\"" }.count
        let singles = s.filter { $0 == "'" }.count
        return doubles % 2 == 1 || singles % 2 == 1
    }

    /// Removes control/placeholder tokens that ONNX MT exports leak into decoded text
    /// (`<pad>`, `</s>`, `<s>`, `<unk>`, `<0xAB>`, â€¦) and normalises spacing.
    /// Anything the model cannot say in plain English must never reach the screen or the TTS.
    static func sanitizeTranslation(_ s: String) -> String {
        var out = s
        if out.contains("<") {
            out = out.replacingOccurrences(of: "<[^<>]{0,48}>", with: " ", options: .regularExpression)
            out = out.replacingOccurrences(of: "<", with: " ")
        }
        if out.contains(">") { out = out.replacingOccurrences(of: ">", with: " ") }
        // SentencePiece marks the start of every decoded word with U+2581. Exports leak it, and
        // `hasModelArtifacts` used to reject the *whole* sentence for a single underline - real
        // speech was thrown away. Strip the mark and keep the words.
        if out.contains("\u{2581}") { out = out.replacingOccurrences(of: "\u{2581}", with: " ") }
        out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\s+([,.;:!?])", with: "$1", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the text still contains something that is not speakable English.
    static func hasModelArtifacts(_ s: String) -> Bool {
        s.contains("<") || s.contains(">") || s.contains("\u{2581}")
    }
}

enum WAV {
    static func write(samples: [Float], sampleRate: Double, to url: URL) throws {
        var data = Data()
        func ascii(_ s: String) { data.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        let sr = UInt32(sampleRate)
        ascii("RIFF"); u32(UInt32(36 + samples.count * 2)); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1); u32(sr); u32(sr * 2); u16(2); u16(16)
        ascii("data"); u32(UInt32(samples.count * 2))
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            u16(UInt16(bitPattern: Int16(clamped * 32767)))
        }
        try data.write(to: url)
    }

    static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Reads a WAV file (16-bit PCM or 32-bit float) into mono float samples.
    /// Used by the file audio input so a recording can drive the whole pipeline offline.
    static func readMono(url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let data = try Data(contentsOf: url)
        guard data.count > 44 else { throw NSError(domain: "heen.wav", code: 1) }

        func u16(_ offset: Int) -> Int {
            Int(data.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian)
        }
        func u32(_ offset: Int) -> Int {
            Int(data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        }

        var offset = 12
        var sampleRate: Double = 16_000
        var channels = 1
        var bits = 16
        var format = 1
        var payload: Data?
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            let size = u32(offset + 4)
            let body = offset + 8
            if id == "fmt " {
                format = u16(body)
                channels = max(1, u16(body + 2))
                sampleRate = Double(u32(body + 4))
                bits = u16(body + 14)
            } else if id == "data" {
                payload = data.subdata(in: body..<min(body + size, data.count))
            }
            offset = body + size + (size % 2)
        }
        guard let payload else { throw NSError(domain: "heen.wav", code: 2) }

        var samples: [Float] = []
        samples.reserveCapacity(payload.count / 2)
        payload.withUnsafeBytes { raw in
            if bits == 16 {
                let values = raw.bindMemory(to: Int16.self)
                var index = 0
                while index + channels <= values.count {
                    var acc: Float = 0
                    for channel in 0..<channels { acc += Float(values[index + channel]) / 32_768 }
                    samples.append(acc / Float(channels))
                    index += channels
                }
            } else if bits == 32, format == 3 {
                let values = raw.bindMemory(to: Float.self)
                var index = 0
                while index + channels <= values.count {
                    var acc: Float = 0
                    for channel in 0..<channels { acc += values[index + channel] }
                    samples.append(acc / Float(channels))
                    index += channels
                }
            }
        }
        guard !samples.isEmpty else { throw NSError(domain: "heen.wav", code: 3) }
        return (samples, sampleRate)
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var acc: Float = 0
        for s in samples { acc += s * s }
        return (acc / Float(samples.count)).squareRoot()
    }
}

extension DateFormatter {
    static let logStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
