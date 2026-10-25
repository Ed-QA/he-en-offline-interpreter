import Foundation
import OnnxRuntimeBindings
import Tokenizers

/// Fully offline Hebrew → English translation using a bundled quantized OPUS-MT model
/// (Marian, int8 ONNX) executed by ONNX Runtime on the CPU. Never touches the network.
final class ONNXTranslationEngine: TranslationEngine {

    let name = "Bundled offline model (OPUS-MT he→en, int8)"

    struct Meta: Decodable {
        let model: String
        let quantized: String
        let decoder_start_token_id: Int
        let eos_token_id: Int
        let max_new_tokens: Int
        let encoder_inputs: [String]
        let encoder_outputs: [String]
        let decoder_inputs: [String]
        let decoder_outputs: [String]
    }

    static let folderName = "Model"

    private let encoder: ORTSession
    private let decoder: ORTSession
    private let tokenizer: Tokenizer
    private let meta: Meta
    private let encInputIds: String
    private let encAttention: String
    private let encHidden: String
    private let decInputIds: String
    private let decAttention: String
    private let decHidden: String
    private let decLogits: String
    private let queue = DispatchQueue(label: "heen.onnx.translate", qos: .userInitiated)

    // MARK: - Locating the bundled model

    static func modelFolder() -> URL? {
        Bundle.main
            .url(forResource: "encoder_model", withExtension: "onnx", subdirectory: folderName)?
            .deletingLastPathComponent()
    }

    static func missingFiles() -> [String] {
        guard let folder = modelFolder() else { return ["Model/ (folder not in bundle)"] }
        let needed = ["encoder_model.onnx", "decoder_model.onnx", "tokenizer.json", "model_info.json"]
        return needed.filter {
            !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    // MARK: - Shared instance (loading twice would double the RAM use)

    private static var cached: ONNXTranslationEngine?
    private static var loadError: String?

    static func shared() async -> ONNXTranslationEngine? {
        if let cached { return cached }
        guard missingFiles().isEmpty, let folder = modelFolder() else { return nil }
        do {
            // Load off the main thread — two ORT sessions (~350 MB) take seconds.
            let engine = try await Task.detached(priority: .userInitiated) {
                try await ONNXTranslationEngine(folder: folder)
            }.value
            cached = engine
            loadError = nil
            return engine
        } catch {
            loadError = String(describing: error)
            return nil
        }
    }

    static func lastLoadError() -> String? { loadError }

    // MARK: - Init

    init(folder: URL) async throws {
        let metaURL = folder.appendingPathComponent("model_info.json")
        let metaData = try Data(contentsOf: metaURL)
        let metaLocal = try JSONDecoder().decode(Meta.self, from: metaData)
        meta = metaLocal

        let envLocal = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
        env = envLocal
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(4)
        encoder = try ORTSession(
            env: envLocal,
            modelPath: folder.appendingPathComponent("encoder_model.onnx").path,
            sessionOptions: options)
        decoder = try ORTSession(
            env: envLocal,
            modelPath: folder.appendingPathComponent("decoder_model.onnx").path,
            sessionOptions: options)
        tokenizer = try await AutoTokenizer.from(modelFolder: folder, strict: false)

        encInputIds = try Self.pick(metaLocal.encoder_inputs, "input_ids")
        encAttention = try Self.pick(metaLocal.encoder_inputs, "attention_mask")
        encHidden = try Self.pick(metaLocal.encoder_outputs, "last_hidden_state", "hidden")
        decInputIds = try Self.pick(metaLocal.decoder_inputs, "input_ids")
        decAttention = try Self.pick(metaLocal.decoder_inputs, "encoder_attention_mask", "attention_mask")
        decHidden = try Self.pick(metaLocal.decoder_inputs, "encoder_hidden_states")
        decLogits = try Self.pick(metaLocal.decoder_outputs, "logits")
    }

    private let env: ORTEnv

    private static func pick(_ names: [String], _ keys: String...) throws -> String {
        for key in keys {
            if let hit = names.first(where: { $0.lowercased().contains(key.lowercased()) }) { return hit }
        }
        throw TranslationError.engineFailure("ONNX model is missing an expected tensor (looked for \(keys.joined(separator: "/")) among \(names.joined(separator: ", ")))")
    }

    // MARK: - Translation

    func translate(_ text: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            queue.async {
                do { cont.resume(returning: try self.runGreedy(trimmed)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Sanitises and (optionally) reports latency for one translation. Never returns
    /// control tokens such as `<pad>` / `<unk>` — they must not reach the screen or TTS.
    func translateSanitized(_ text: String) async throws -> String {
        let raw = try await translate(text)
        return TextUtil.sanitizeTranslation(raw)
    }

    /// Encoder runs once, then greedy token-by-token decoding with the non-cached decoder.
    private func runGreedy(_ text: String) throws -> String {
        var source = tokenizer.encode(text: text)
        guard !source.isEmpty else { return "" }
        if source.count > 400 { source = Array(source.prefix(400)) }
        let mask = Array(repeating: 1, count: source.count)

        let encoderOutputs = try encoder.run(
            withInputs: [
                encInputIds: try Self.int64Value(source, shape: [1, source.count]),
                encAttention: try Self.int64Value(mask, shape: [1, source.count]),
            ],
            outputNames: [encHidden],
            runOptions: nil)
        guard let hidden = encoderOutputs[encHidden] else {
            throw TranslationError.engineFailure("encoder produced no \(encHidden)")
        }
        let hiddenShape = try hidden.tensorTypeAndShapeInfo().shape.map { $0.intValue }
        let hiddenData = try hidden.tensorData()
        let hiddenValue = try ORTValue(tensorData: hiddenData, elementType: .float,
                                       shape: hiddenShape.map { NSNumber(value: $0) })

        var generated: [Int] = [meta.decoder_start_token_id]
        var produced: [Int] = []
        let limit = min(meta.max_new_tokens, 2 * source.count + 16)

        for _ in 0..<limit {
            let outputs = try decoder.run(
                withInputs: [
                    decInputIds: try Self.int64Value(generated, shape: [1, generated.count]),
                    decAttention: try Self.int64Value(mask, shape: [1, mask.count]),
                    decHidden: hiddenValue,
                ],
                outputNames: [decLogits],
                runOptions: nil)
            guard let logits = outputs[decLogits] else {
                throw TranslationError.engineFailure("decoder produced no \(decLogits)")
            }
            let shape = try logits.tensorTypeAndShapeInfo().shape.map { $0.intValue }
            let vocab = shape.last ?? 0
            guard vocab > 0 else { throw TranslationError.engineFailure("empty logits shape") }
            let data = try logits.tensorData()
            let floats = data.bytes.assumingMemoryBound(to: Float.self)
            let offset = (generated.count - 1) * vocab
            var bestIndex = 0
            var bestScore = -Float.greatestFiniteMagnitude
            for i in 0..<vocab {
                let score = floats[offset + i]
                if score > bestScore { bestScore = score; bestIndex = i }
            }
            if bestIndex == meta.eos_token_id { break }
            generated.append(bestIndex)
            produced.append(bestIndex)
        }
        return tokenizer.decode(tokens: produced, skipSpecialTokens: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func int64Value(_ values: [Int], shape: [Int]) throws -> ORTValue {
        var widened = values.map { Int64($0) }
        let data = NSMutableData(length: widened.count * MemoryLayout<Int64>.size)!
        widened.withUnsafeBufferPointer { buffer in
            data.mutableBytes.assumingMemoryBound(to: Int64.self)
                .update(from: buffer.baseAddress!, count: widened.count)
        }
        return try ORTValue(tensorData: data, elementType: .int64,
                            shape: shape.map { NSNumber(value: $0) })
    }

    // MARK: - Diagnostics (used by the in-app capability probe)

    static func diagnostics() async -> String {
        var lines: [String] = []
        guard let folder = modelFolder() else {
            return "  Bundled model: NOT in app bundle (Model/ missing)"
        }
        for file in ["encoder_model.onnx", "decoder_model.onnx", "tokenizer.json", "model_info.json"] {
            let path = folder.appendingPathComponent(file)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
               let size = attrs[.size] as? Int {
                lines.append("  \(file): \(size / 1_048_576) MB")
            } else {
                lines.append("  \(file): MISSING")
            }
        }
        lines.append("  ONNX Runtime version: \(String(describing: ORTVersion()))")
        let started = Date()
        guard let engine = await shared() else {
            lines.append("  engine load: FAILED — \(lastLoadError() ?? "unknown")")
            return lines.joined(separator: "\n")
        }
        lines.append("  engine loaded in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        lines.append("  encoder in: \(engine.meta.encoder_inputs.joined(separator: ", "))")
        lines.append("  decoder in: \(engine.meta.decoder_inputs.joined(separator: ", "))")
        lines.append("  start id: \(engine.meta.decoder_start_token_id)  eos id: \(engine.meta.eos_token_id)")
        let sample = "אני לומד עברית כל יום עם חברים שלי."
        do {
            let t0 = Date()
            let english = try await engine.translate(sample)
            lines.append("  self-test HE: \(sample)")
            lines.append("  self-test EN: \(english)   [\(String(format: "%.1f", Date().timeIntervalSince(t0)))s]")
        } catch {
            lines.append("  self-test FAILED: \(error.localizedDescription)")
        }
        return lines.joined(separator: "\n")
    }
}
