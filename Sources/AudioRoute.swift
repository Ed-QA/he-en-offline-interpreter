import Foundation
import AVFoundation

/// Audio routing is left to iOS — the system already sends sound to the earbuds when they are
/// connected and back to the phone when they are not, and it tells the app when that changes.
/// This type therefore only *reports* what the system chose and follows the system's own
/// route-change notification. No invented availability heuristics, no polling, no guessing.
enum AudioRoute {

    /// The route iOS is using right now, straight from the session.
    static func summary() -> String {
        let session = AVAudioSession.sharedInstance()
        let input = session.currentRoute.inputs.first?.portName ?? "—"
        let output = session.currentRoute.outputs.first?.portName ?? "—"
        return "\(input) → \(output)"
    }

    /// True when the system is playing through something other than the phone itself.
    static func isExternal() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver
        }
    }

    /// The system's own notification — the UI follows this instead of polling a timer.
    static func observe(_ handler: @escaping () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                               object: nil, queue: .main) { _ in handler() }
    }

    static func stopObserving(_ token: NSObjectProtocol) {
        NotificationCenter.default.removeObserver(token)
    }

    /// Documented API for "play through the phone's speaker". The system still overrides it the
    /// moment the user plugs earbuds in, which is exactly the native behaviour.
    static func usePhoneSpeaker() {
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
    }

    /// Hand routing back to the system (the native default).
    static func followSystem() {
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
    }
}

