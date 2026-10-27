import Foundation

/// The language the app translates into and speaks. English and Ukrainian both ship with the app,
/// and each one keeps its own voice and speed, so switching back and forth restores exactly what
/// was chosen for that language.
enum TargetLanguage: String, CaseIterable, Identifiable {
    case en
    case uk

    var id: String { rawValue }

    var label: String { self == .en ? "English" : "Українська" }

    /// Prefix used for the voice lookup and for the Apple translation pair.
    var code: String { self == .en ? "en" : "uk" }
}

/// The few choices a user actually makes in Settings. Plain `UserDefaults`: no dependency, no
/// schema, and an unreadable value falls back to the default instead of failing.
enum Prefs {
    static let voiceKey = "heen.voiceIdentifier"
    static let rateKey = "heen.rate"
    static let gateKey = "heen.gateMode"
    static let targetKey = "heen.target"
    static let voiceKeyUK = "heen.voice.uk"
    static let rateKeyUK = "heen.rate.uk"
    static let micKey = "heen.micUID"
    static let outputKey = "heen.outputChoice"

    /// The microphone the user picked (a port uid); `nil` means "let iOS choose".
    static var micUID: String? {
        get { store.string(forKey: micKey) }
        set {
            if let newValue { store.set(newValue, forKey: micKey) }
            else { store.removeObject(forKey: micKey) }
        }
    }

    /// The output the user picked, stored as text so it survives a launch.
    static var outputChoice: AudioRoute.Output {
        get {
            guard let raw = store.string(forKey: outputKey) else { return .system }
            if raw == "speaker" { return .speaker }
            if raw.hasPrefix("connected:") {
                return .connected(String(raw.dropFirst("connected:".count)))
            }
            return .system
        }
        set {
            switch newValue {
            case .system: store.set("system", forKey: outputKey)
            case .speaker: store.set("speaker", forKey: outputKey)
            case .connected(let uid): store.set("connected:\(uid)", forKey: outputKey)
            }
        }
    }

    private static func voiceKey(for language: TargetLanguage) -> String {
        language == .en ? voiceKey : voiceKeyUK
    }

    private static func rateKey(for language: TargetLanguage) -> String {
        language == .en ? rateKey : rateKeyUK
    }

    /// Which language the app is set to. `nil`-safe: an unknown stored value means English.
    static var target: TargetLanguage {
        get { store.string(forKey: targetKey).flatMap(TargetLanguage.init(rawValue:)) ?? .en }
        set { store.set(newValue.rawValue, forKey: targetKey) }
    }

    /// `nil` means "let iOS pick the best installed voice for that language".
    static func voice(for language: TargetLanguage) -> String? {
        store.string(forKey: voiceKey(for: language))
    }

    static func setVoice(_ identifier: String?, for language: TargetLanguage) {
        let key = voiceKey(for: language)
        if let identifier { store.set(identifier, forKey: key) } else { store.removeObject(forKey: key) }
    }

    static func rate(for language: TargetLanguage) -> Float {
        let key = rateKey(for: language)
        guard store.object(forKey: key) != nil else { return defaultRate }
        return clamp(store.float(forKey: key))
    }

    static func setRate(_ value: Float, for language: TargetLanguage) {
        store.set(clamp(value), forKey: rateKey(for: language))
    }

    static let defaultRate: Float = 0.5
    static let rateRange: ClosedRange<Float> = 0.35...0.65

    private static var store: UserDefaults { .standard }

    /// English convenience: the original single-language accessors now delegate to the
    /// language-aware ones, so English keeps its own voice and speed.
    static var voiceIdentifier: String? {
        get { voice(for: .en) }
        set { setVoice(newValue, for: .en) }
    }

    static var rate: Float {
        get { rate(for: .en) }
        set { setRate(newValue, for: .en) }
    }

    static var gateMode: GateMode {
        get { store.string(forKey: gateKey).flatMap(GateMode.init(rawValue:)) ?? .balanced }
        set { store.set(newValue.rawValue, forKey: gateKey) }
    }

    /// Back to factory defaults: no keys stored, so a fresh install and a reset behave the same.
    static func reset() {
        store.removeObject(forKey: voiceKey)
        store.removeObject(forKey: rateKey)
        store.removeObject(forKey: gateKey)
        store.removeObject(forKey: targetKey)
        store.removeObject(forKey: voiceKeyUK)
        store.removeObject(forKey: rateKeyUK)
    }

    static func clamp(_ value: Float) -> Float {
        min(max(value, rateRange.lowerBound), rateRange.upperBound)
    }
}
