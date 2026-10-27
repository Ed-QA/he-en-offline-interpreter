import Foundation
import AVFoundation

/// The two audio choices, kept separate: which microphone to listen on, and where the translation
/// comes out. Both lists are built from what iOS reports right now — never a fixed phone/earplugs
/// pair — and each choice maps to exactly one documented `AVAudioSession` call.
enum AudioRoute {

    /// Where the translation comes out. `system` is the native default and the only setting in
    /// which earbuds behave exactly as iOS wants them to.
    enum Output: Hashable {
        case system             // overrideOutputAudioPort(.none)    — iOS decides (earbuds win)
        case speaker            // overrideOutputAudioPort(.speaker) — the phone's own speaker
        case connected(String)  // an output that is in the route right now (port uid)
    }

    // MARK: - What iOS offers right now

    /// The microphones the system reports: built-in, wired headset, Bluetooth, USB, CarPlay…
    static func inputOptions() -> [AVAudioSessionPortDescription] {
        AVAudioSession.sharedInstance().availableInputs ?? []
    }

    /// Automatic, the phone speaker, and every output that is actually connected at this moment.
    static func outputOptions() -> [Output] {
        var options: [Output] = [.system, .speaker]
        for port in AVAudioSession.sharedInstance().currentRoute.outputs
        where port.portType != .builtInSpeaker && port.portType != .builtInReceiver {
            options.append(.connected(port.uid))
        }
        return options
    }

    static func label(_ output: Output) -> String {
        switch output {
        case .system: return "Automatic"
        case .speaker: return "Phone speaker"
        case .connected(let uid):
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
            return outputs.first { $0.uid == uid }?.portName ?? "Connected device"
        }
    }

    // MARK: - Applying a choice (documented APIs only)

    /// `nil` hands the microphone choice back to iOS.
    static func applyInput(_ uid: String?) {
        let session = AVAudioSession.sharedInstance()
        guard let uid else {
            try? session.setPreferredInput(nil)
            return
        }
        guard let port = session.availableInputs?.first(where: { $0.uid == uid }) else { return }
        try? session.setPreferredInput(port)
    }

    static func applyOutput(_ output: Output) {
        let session = AVAudioSession.sharedInstance()
        switch output {
        case .system, .connected:
            // Hand routing back to iOS: it uses the connected earbuds, and the phone when there
            // are none. This is what makes earbuds work — forcing `.speaker` never did.
            try? session.overrideOutputAudioPort(.none)
        case .speaker:
            try? session.overrideOutputAudioPort(.speaker)
        }
    }

    /// Applies both saved choices — used when the audio session (re)starts, because a preference
    /// can only be set while the session is active.
    static func applySaved() {
        applyInput(Prefs.micUID)
        applyOutput(Prefs.outputChoice)
    }

    // MARK: - Reporting

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
}


