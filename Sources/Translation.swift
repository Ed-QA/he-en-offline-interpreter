import Foundation
import Translation

protocol TranslationEngine: AnyObject {
    var name: String { get }
    func translate(_ text: String) async throws -> String
}

enum TranslationError: LocalizedError {
    case notReady
    case unsupported
    case engineFailure(String)
    var errorDescription: String? {
        switch self {
        case .notReady: return "Translation session not ready"
        case .unsupported: return "Hebrew → English not supported by this engine"
        case .engineFailure(let message): return message
        }
    }
}

/// Apple's on-device translation (Translation framework). iOS 18+.
/// Uses the same on-device models as system-wide translation; the language pack
/// is shared with the system and must already be installed for full offline use.
@available(iOS 18.0, *)
final class AppleTranslationEngine: TranslationEngine {
    let name = "Apple on-device translation"
    var session: TranslationSession?

    func translate(_ text: String) async throws -> String {
        guard let session else { throw TranslationError.notReady }
        // Same input contract as the bundled engine: pointed Hebrew is what arrives. Apple's
        // on-device model has no pointed vocabulary at all, so this engine's nikud policy is to
        // normalise — the points are accepted at the boundary, never rejected or mangled.
        let response = try await session.translate(TextUtil.stripNikud(text))
        return response.targetText
    }
}

@available(iOS 18.0, *)
enum AppleTranslationAvailability {
    static let hebrew = Locale.Language(identifier: "he")
    static let english = Locale.Language(identifier: "en")

    struct Report {
        let statusText: String
        let canUseInstalledPack: Bool
        let supportedLanguages: [String]
    }

    static func check() async -> Report {
        let availability = LanguageAvailability()
        let langs = await availability.supportedLanguages.map { $0.minimalIdentifier }
        let status = await availability.status(from: hebrew, to: english)
        let text: String
        var installed = false
        switch status {
        case .installed:
            text = "installed (he→en pack present — fully offline OK)"
            installed = true
        case .supported:
            text = "supported but pack NOT installed (needs one-time system download)"
        case .unsupported:
            text = "NOT supported (Apple on-device translation has no he→en)"
        @unknown default:
            text = "unknown"
        }
        return Report(statusText: text, canUseInstalledPack: installed, supportedLanguages: langs.sorted())
    }

    static func configuration() -> TranslationSession.Configuration {
        TranslationSession.Configuration(source: hebrew, target: english)
    }
}
