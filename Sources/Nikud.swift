import Foundation

/// Hebrew diacritization (nikud) for the text that is sent to the translator.
///
/// Port of **Phonikud** (`phonikud-onnx`, INTERSPEECH 2026, arXiv:2506.12311) — a
/// character-level DictaBERT diacritizer exported to int8 ONNX. Unpointed Hebrew is
/// ambiguous: a bare word has several possible readings, so neither a human nor the MT
/// model can be sure which one is meant. The pipeline contract is therefore:
///
///     STT text ──▶ diacritize (nikud) ──▶ only pointed text is translated
///
/// The model and its tokenizer ship inside the app bundle (`Model/Nikud/`) and are fetched
/// at build time by `Tools/prepare_nikud.py`:
///   - `phonikud-1.0.int8.onnx`  307,844,158 bytes  (Phonikud/phonikud-onnx)
///   - `tokenizer.json`               18,016 bytes  (Phonikud/phonikud)
/// Reported diacritization accuracy of this checkpoint: 85.44 % (wer_info.txt).
///
/// It runs on the ONNX Runtime the app already links (sherpa-onnx's `onnxruntime-libs`
/// 1.28.2) through `Sources/ORT.swift` — no extra runtime, no network.
enum NikudError: LocalizedError {
    case model(String)
    var errorDescription: String? {
        switch self {
        case .model(let why): return "nikud model: \(why)"
        }
    }
}

enum NikudModel {
    static let folderName = "Model/Nikud"
    static let modelFile = "phonikud-1.0.int8.onnx"
    static let tokenizerFile = "tokenizer.json"

    static func folder() -> URL? {
        Bundle.main
            .url(forResource: "phonikud-1.0.int8", withExtension: "onnx", subdirectory: folderName)?
            .deletingLastPathComponent()
            ?? Bundle.main.resourceURL?.appendingPathComponent(folderName, isDirectory: true)
    }

    static func missingFiles() -> [String] {
        guard let folder = folder() else { return [modelFile, tokenizerFile] }
        return [modelFile, tokenizerFile].filter {
            !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }
}

/// Character-level diacritizer. Mirrors `phonikud_onnx/model.py` one-to-one so the on-device
/// result matches the reference implementation.
final class NikudRestorer {
    // MARK: - Classes (the order IS the argmax index — never reorder)

    static let nikudClasses: [String] = [
        "",
        "<MAT_LECT>",
        "\u{05BC}",          // dagesh
        "\u{05B0}",          // shva
        "\u{05B1}",          // hataf segol
        "\u{05B2}",          // hataf patah
        "\u{05B3}",          // hataf kamatz
        "\u{05B4}",          // hiriq
        "\u{05B5}",          // tzere
        "\u{05B6}",          // segol
        "\u{05B7}",          // patah
        "\u{05B8}",          // kamatz
        "\u{05B9}",          // holam
        "\u{05BA}",          // holam haser
        "\u{05BB}",          // kubutz
        "\u{05BC}\u{05B0}",  // dagesh + shva
        "\u{05BC}\u{05B1}",
        "\u{05BC}\u{05B2}",
        "\u{05BC}\u{05B3}",
        "\u{05BC}\u{05B4}",
        "\u{05BC}\u{05B5}",
        "\u{05BC}\u{05B6}",
        "\u{05BC}\u{05B7}",
        "\u{05BC}\u{05B8}",
        "\u{05BC}\u{05B9}",
        "\u{05BC}\u{05BA}",
        "\u{05BC}\u{05BB}",
        "\u{05C7}",          // kamatz katan
        "\u{05BC}\u{05C7}",  // dagesh + kamatz katan
    ]

    static let shinClasses = ["\u{05C1}", "\u{05C2}"]   // shin dot, sin dot
    static let matLectToken = "<MAT_LECT>"
    static let matresLetters: Set<Character> = ["\u{05D0}", "\u{05D5}", "\u{05D9}"]  // alef, vav, yod
    static let stressMark = "\u{05AB}"      // ole — stress (phonikud: HATAMA_DIACRITIC)
    static let vocalShvaMark = "\u{05BD}"   // meteg — mobile shva (VOCAL_SHVA_DIACRITIC)
    static let prefixMark = "|"             // PREFIX_DIACRITIC
    static let maxChunkLength = 2046        // 2048 − [CLS] − [SEP]

    private let session: ORTSession
    private let vocab: [String: Int64]
    private let unkId: Int64
    private let clsId: Int64
    private let sepId: Int64

    private init(session: ORTSession, vocab: [String: Int64], clsId: Int64, sepId: Int64, unkId: Int64) {
        self.session = session
        self.vocab = vocab
        self.clsId = clsId
        self.sepId = sepId
        self.unkId = unkId
    }

    // MARK: - Pure text logic (unit-testable without the model)

    /// Rebuilds the sentence from the model's predictions — mirrors `OnnxModel.predict`:
    /// only Hebrew letters (U+05D0–U+05EA) receive marks, everything else passes through.
    static func apply(chars: [Character],
                      nikudClass: [Int],
                      shinClass: [Int],
                      stress: [Bool],
                      vocalShva: [Bool],
                      prefix: [Bool],
                      markMatresLectionis: Character?) -> String {
        var out = ""
        out.reserveCapacity(chars.count * 2)
        for (index, character) in chars.enumerated() {
            let scalar = character.unicodeScalars.count == 1 ? character.unicodeScalars.first : nil
            let isHebrewLetter = scalar.map { (0x05D0...0x05EA).contains($0.value) } ?? false
            guard isHebrewLetter else {
                out.append(character)
                continue
            }

            var nikud = ""
            if nikudClass.indices.contains(index) {
                let classIndex = min(max(nikudClass[index], 0), nikudClasses.count - 1)
                nikud = nikudClasses[classIndex]
            }
            if nikud == matLectToken {
                if !matresLetters.contains(character) {
                    nikud = ""                       // matres only exists on alef / vav / yod
                } else if let mark = markMatresLectionis {
                    nikud = String(mark)
                } else {
                    out.append(character)            // bare matres letter, nothing added
                    continue
                }
            }
            let shin = character == "\u{05E9}" && shinClass.indices.contains(index)
                ? shinClasses[min(max(shinClass[index], 0), shinClasses.count - 1)]
                : ""
            let stressSuffix = stress.indices.contains(index) && stress[index] ? Self.stressMark : ""
            let vocalSuffix = vocalShva.indices.contains(index) && vocalShva[index] ? vocalShvaMark : ""
            let prefixSuffix = prefix.indices.contains(index) && prefix[index] ? prefixMark : ""

            out.append(character)
            out += shin
            out += nikud
            out += stressSuffix
            out += vocalSuffix
            out += prefixSuffix
        }
        return out
    }

    /// Splits text into pieces the model can read (≤ 2046 characters). Mirrors
    /// `prepare_chunks`: break after a dot / newline when possible, hard-split otherwise.
    static func chunks(of text: String) -> [String] {
        guard text.count > maxChunkLength else { return [text] }
        var pieces: [String] = []
        var buffer = ""
        for character in text {
            buffer.append(character)
            if character == "." || character == "\n" {
                pieces.append(buffer)
                buffer = ""
            }
        }
        if !buffer.isEmpty { pieces.append(buffer) }

        var chunks: [String] = []
        var current = ""
        for piece in pieces {
            if piece.count > maxChunkLength {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                var rest = Substring(piece)
                while rest.count > maxChunkLength {
                    let cut = rest.index(rest.startIndex, offsetBy: maxChunkLength)
                    chunks.append(String(rest[rest.startIndex..<cut]))
                    rest = rest[cut...]
                }
                if !rest.isEmpty { chunks.append(String(rest)) }
            } else if current.count + piece.count <= maxChunkLength {
                current += piece
            } else {
                chunks.append(current)
                current = piece
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// phonikud's own preprocessing: the model is fed *unpointed* text (`remove_nikkud`,
    /// regex `[\u0590-\u05C7|]`), so any nikud the recogniser produced is dropped first and
    /// the diacritizer predicts the full pointing itself.
    static func removeNikud(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(s.unicodeScalars.count)
        for scalar in s.unicodeScalars {
            let value = scalar.value
            if (0x0590...0x05C7).contains(value) || value == 0x7C { continue }
            out.append(scalar)
        }
        return String(out)
    }

    // MARK: - Inference

    /// Adds nikud to `text`. `markMatresLectionis` is phonikud's "nikud male" marker: when
    /// set, a matres letter (א/ו/י) that only carries a vowel is followed by that mark so the
    /// reading can be reconstructed later. `nil` leaves such letters bare — what the MT model
    /// wants, and what a human reads most easily.
    func addDiacritics(_ text: String, markMatresLectionis: Character? = nil) -> String {
        guard !text.isEmpty else { return text }
        return Self.chunks(of: text)
            .map { diacritize($0, markMatresLectionis: markMatresLectionis) }
            .joined()
    }

    private func diacritize(_ text: String, markMatresLectionis: Character?) -> String {
        let plain = Self.removeNikud(text)
        let chars = Array(plain)
        guard !chars.isEmpty else { return text }

        var ids: [Int64] = [clsId]
        ids.reserveCapacity(chars.count + 2)
        for character in chars { ids.append(vocab[String(character)] ?? unkId) }
        ids.append(sepId)

        do {
            let length = ids.count
            let shape: [NSNumber] = [1, NSNumber(value: length)]
            let ones = [Int64](repeating: 1, count: length)
            let zeros = [Int64](repeating: 0, count: length)
            let inputs: [String: ORTValue] = [
                "input_ids": try ORTValue(tensorData: Self.int64Data(ids), elementType: .int64, shape: shape),
                "attention_mask": try ORTValue(tensorData: Self.int64Data(ones), elementType: .int64, shape: shape),
                "token_type_ids": try ORTValue(tensorData: Self.int64Data(zeros), elementType: .int64, shape: shape),
            ]
            let outputs = try session.run(withInputs: inputs,
                                          outputNames: ["nikud_logits", "shin_logits", "additional_logits"])
            guard let nikudValue = outputs["nikud_logits"],
                  let shinValue = outputs["shin_logits"],
                  let additionalValue = outputs["additional_logits"] else {
                throw NikudError.model("model did not return the expected heads")
            }
            let nikud = try Self.argmax(Self.floats(of: nikudValue),
                                        classes: Self.nikudClasses.count, positions: length)
            let shin = try Self.argmax(Self.floats(of: shinValue),
                                       classes: Self.shinClasses.count, positions: length)
            let additional = try Self.floats(of: additionalValue)
            guard additional.count >= length * 3 else {
                throw NikudError.model("unexpected additional_logits shape")
            }
            // The model sees [CLS] text [SEP]: prediction 0 belongs to [CLS] and the last one
            // to [SEP], so the characters own predictions 1 ..< length-1.
            guard length >= 3 else { return text }
            let first = 1
            let last = length - 2
            var stress = [Bool](); stress.reserveCapacity(chars.count)
            var vocal = [Bool](); vocal.reserveCapacity(chars.count)
            var prefix = [Bool](); prefix.reserveCapacity(chars.count)
            for position in first...last {
                let base = position * 3
                stress.append(additional[base] > 0)
                vocal.append(additional[base + 1] > 0)
                prefix.append(additional[base + 2] > 0)
            }
            return Self.apply(chars: chars,
                              nikudClass: Array(nikud[first...last]),
                              shinClass: Array(shin[first...last]),
                              stress: stress,
                              vocalShva: vocal,
                              prefix: prefix,
                              markMatresLectionis: markMatresLectionis)
        } catch {
            // Diacritization must never break live translation.
            return text
        }
    }

    // MARK: - Tensors

    static func int64Data(_ values: [Int64]) -> NSData {
        let copy = values
        return copy.withUnsafeBufferPointer { buffer in
            NSData(bytes: buffer.baseAddress, length: buffer.count * MemoryLayout<Int64>.size)
        }
    }

    static func floats(of value: ORTValue) throws -> [Float] {
        let data = try value.tensorData()
        let count = data.length / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        data.getBytes(&out, length: count * MemoryLayout<Float>.size)
        return out
    }

    /// Per-position argmax over `classes` consecutive logits (`positions × classes` floats).
    static func argmax(_ values: [Float], classes: Int, positions: Int) throws -> [Int] {
        guard classes > 0, values.count >= positions * classes else {
            throw NikudError.model("logits shape \(values.count) does not fit \(positions)×\(classes)")
        }
        var out = [Int](repeating: 0, count: positions)
        for position in 0..<positions {
            let base = position * classes
            var best = 0
            var bestValue = values[base]
            for index in 1..<classes where values[base + index] > bestValue {
                bestValue = values[base + index]
                best = index
            }
            out[position] = best
        }
        return out
    }

    // MARK: - Loading

    /// Loads the int8 diacritizer and its char tokenizer. Throws when the bundle lacks the
    /// files (the caller then keeps the pipeline working on unpointed text).
    static func load() throws -> NikudRestorer {
        guard let folder = NikudModel.folder() else {
            throw NikudError.model("Model/Nikud folder missing in the app bundle")
        }
        let modelURL = folder.appendingPathComponent(NikudModel.modelFile)
        let tokenizerURL = folder.appendingPathComponent(NikudModel.tokenizerFile)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw NikudError.model("\(NikudModel.modelFile) missing — run Tools/prepare_nikud.py")
        }
        let tokenizer = try TokenizerFile(url: tokenizerURL)

        let env = try ORTEnv(loggingLevel: .error)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(4)
        let session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
        return NikudRestorer(session: session,
                             vocab: tokenizer.vocab,
                             clsId: tokenizer.clsId,
                             sepId: tokenizer.sepId,
                             unkId: tokenizer.unkId)
    }
}

/// Minimal reader for the Hugging Face `tokenizer.json` of the diacritizer: a char-level
/// WordPiece model whose pre-tokenizer splits `[\s\S]`, i.e. one token == one character.
private struct TokenizerFile {
    let vocab: [String: Int64]
    let clsId: Int64
    let sepId: Int64
    let unkId: Int64

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NikudError.model("tokenizer.json is not a JSON object")
        }
        var specialIds: [String: Int64] = [:]
        for token in (root["added_tokens"] as? [[String: Any]]) ?? [] {
            if let content = token["content"] as? String, let id = token["id"] as? NSNumber {
                specialIds[content] = id.int64Value
            }
        }
        var vocab: [String: Int64] = [:]
        if let model = root["model"] as? [String: Any],
           let table = model["vocab"] as? [String: NSNumber] {
            for (key, value) in table { vocab[key] = value.int64Value }
        }
        guard !vocab.isEmpty else { throw NikudError.model("tokenizer.json has no vocabulary") }
        self.vocab = vocab
        self.clsId = specialIds["[CLS]"] ?? 1
        self.sepId = specialIds["[SEP]"] ?? 2
        self.unkId = specialIds["[UNK]"] ?? 0
    }
}
