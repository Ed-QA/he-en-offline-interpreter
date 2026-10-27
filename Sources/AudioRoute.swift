import Foundation
import AVFoundation

/// Item 10: the two places sound can come from and go to — the phone itself, or the earplugs.
/// Every choice is checked against what the system actually offers right now, so a selector can
/// be greyed out when the earplugs are not connected instead of silently doing nothing.
enum AudioEndpoint: String, CaseIterable, Identifiable {
    case phone
    case earbuds

    var id: String { rawValue }

    var label: String {
        switch self {
        case .phone: return "Phone"
        case .earbuds: return "Earplugs"
        }
    }
}

enum AudioRoute {

    /// Ports that count as "earplugs" for input and output.
    private static let inputPorts: Set<AVAudioSession.Port> = [
        .headsetMic, .bluetoothHFP, .bluetoothLE, .lineIn, .usbAudio, .carAudio,
    ]
    private static let outputPorts: Set<AVAudioSession.Port> = [
        .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio, .carAudio,
    ]

    static func isAvailable(_ endpoint: AudioEndpoint, input: Bool) -> Bool {
        let session = AVAudioSession.sharedInstance()
        switch endpoint {
        case .phone:
            // The built-in mic and speaker are always there.
            return true
        case .earbuds:
            if input {
                let wired = session.availableInputs?.contains { inputPorts.contains($0.portType) } ?? false
                let routed = session.currentRoute.inputs.contains { inputPorts.contains($0.portType) }
                return wired || routed
            }
            let routed = session.currentRoute.outputs.contains { outputPorts.contains($0.portType) }
            let possible = session.availableInputs?.contains { inputPorts.contains($0.portType) } ?? false
            return routed || possible
        }
    }

    /// Routes the microphone: `setPreferredInput` picks the earplugs' mic, `nil` goes back to the
    /// phone's own microphone.
    static func applyInput(_ endpoint: AudioEndpoint) {
        let session = AVAudioSession.sharedInstance()
        switch endpoint {
        case .phone:
            try? session.setPreferredInput(nil)
        case .earbuds:
            guard let port = session.availableInputs?.first(where: { inputPorts.contains($0.portType) })
            else { return }
            try? session.setPreferredInput(port)
        }
    }

    /// Routes the output: the phone plays through its own speaker, the earplugs take the audio
    /// through whatever is connected.
    static func applyOutput(_ endpoint: AudioEndpoint) {
        let session = AVAudioSession.sharedInstance()
        switch endpoint {
        case .phone:
            try? session.overrideOutputAudioPort(.speaker)
        case .earbuds:
            try? session.overrideOutputAudioPort(.none)
        }
    }
}
