import Foundation
import Tokenizers

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Model"
let folder = URL(fileURLWithPath: path)

func note(_ text: String) {
    FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
}

note("checking tokenizer in \(folder.path)")

do {
    let tokenizer = try await AutoTokenizer.from(modelFolder: folder, strict: false)

    let hebrew = "אני לומד עברית כל יום עם חברים שלי."
    let ids = tokenizer.encode(text: hebrew)
    print("ENCODE OK — \(ids.count) ids: \(ids.prefix(12).map(String.init).joined(separator: ","))")
    print("HE ROUNDTRIP: \(tokenizer.decode(tokens: ids, skipSpecialTokens: true))")

    let english = "I learn Hebrew every day with my friends."
    let enIds = tokenizer.encode(text: english)
    print("EN IDS: \(enIds.count)  EN ROUNDTRIP: \(tokenizer.decode(tokens: enIds, skipSpecialTokens: true))")
} catch {
    note("TOKENIZER FAILED: \(error)")
    exit(1)
}
