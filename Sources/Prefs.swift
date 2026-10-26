import Foundation

/// The few choices a user actually makes in Settings. Plain `UserDefaults`: no dependency, no
/// schema, and an unreadable value falls back to the default instead of failing.
enum Prefs {
    static let voiceKey = "heen.voiceIdentifier"
    static let rateKey = "heen.rate"
    static let gateKey = "heen.gateMode"

    static let defaultRate: Float = 0.5
    static let rateRange: ClosedRange<Float> = 0.35...0.65

    private static var store: UserDefaults { .standard }

    /// `nil` means "let iOS pick the best installed English voice".
    static var voiceIdentifier: String? {
        get { store.string(forKey: voiceKey) }
        set {
            if let newValue { store.set(newValue, forKey: voiceKey) }
            else { store.removeObject(forKey: voiceKey) }
        }
    }

    static var rate: Float {
        get {
            guard store.object(forKey: rateKey) != nil else { return defaultRate }
            return clamp(store.float(forKey: rateKey))
        }
        set { store.set(clamp(newValue), forKey: rateKey) }
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
    }

    static func clamp(_ value: Float) -> Float {
        min(max(value, rateRange.lowerBound), rateRange.upperBound)
    }
}
