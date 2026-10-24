import Foundation
import AVFoundation
import Speech
import UIKit

/// On-device capability probe: answers what this exact iPhone can do, offline.
enum CapabilityProbe {

    static func run() async -> String {
        var lines: [String] = []
        lines.append("CAPABILITY PROBE — \(Date())")
        lines.append("Device: \(deviceModel())  iOS: \(UIDevice.current.systemVersion)")
        lines.append("")

        // 1) Speech recognition (legacy API — the on-device Hebrew model)
        lines.append("— SPEECH (SFSpeechRecognizer) —")
        let auth = SFSpeechRecognizer.authorizationStatus()
        lines.append("Authorization: \(authText(auth))")
        let he = SFSpeechRecognizer(locale: Locale(identifier: "he-IL"))
        lines.append("he-IL recognizer available: \(he?.isAvailable == true)")
        lines.append("he-IL supports ON-DEVICE recognition: \(he?.supportsOnDeviceRecognition == true)")
        let all = SFSpeechRecognizer.supportedLocales().map { $0.identifier }.sorted()
        lines.append("Supported locales: \(all.count); he-IL present: \(all.contains("he-IL"))")
        lines.append("")

        // 2) New iOS 26 transcription API (if present)
        lines.append("— SPEECH (SpeechTranscriber, iOS 26+) —")
        if #available(iOS 26.0, *) {
            let supported = await SpeechTranscriber.supportedLocales
            let installed = await SpeechTranscriber.installedLocales
            lines.append("SpeechTranscriber supported locales: \(supported.count)")
            lines.append("SpeechTranscriber installed locales: \(installed.count)")
            let heSupported = supported.contains { $0.identifier.lowercased().hasPrefix("he") }
            let heInstalled = installed.contains { $0.identifier.lowercased().hasPrefix("he") }
            lines.append("Hebrew supported: \(heSupported); Hebrew installed: \(heInstalled)")
        } else {
            lines.append("Not available on this iOS version")
        }
        lines.append("")

        // 3) Apple on-device translation
        lines.append("— TRANSLATION (Apple on-device) —")
        if #available(iOS 18.0, *) {
            let report = await AppleTranslationAvailability.check()
            lines.append("he → en: \(report.statusText)")
            lines.append("supportedLanguages (\(report.supportedLanguages.count)): \(report.supportedLanguages.joined(separator: ", "))")
            let hasHe = report.supportedLanguages.contains { $0.lowercased().hasPrefix("he") }
            lines.append("Hebrew listed as translation language: \(hasHe)")
        } else {
            lines.append("Not available on this iOS version")
        }
        lines.append("")

        // 4) TTS voices
        lines.append("— TTS (native iOS voices) —")
        let voices = Speaker.englishVoices()
        lines.append("English voices installed: \(voices.count)")
        for v in voices {
            lines.append("  \(v.name) [\(v.language)] \(Speaker.qualityLabel(v))")
        }
        lines.append("")

        // 5) Audio route
        lines.append("— AUDIO ROUTE —")
        let session = AVAudioSession.sharedInstance()
        lines.append("Category: \(session.category.rawValue), mode: \(session.mode.rawValue)")
        for out in session.currentRoute.outputs { lines.append("Output: \(out.portType.rawValue) — \(out.portName)") }
        for inp in session.currentRoute.inputs { lines.append("Input: \(inp.portType.rawValue) — \(inp.portName)") }
        lines.append("")

        let text = lines.joined(separator: "\n")
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? text.write(to: dir.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)
        }
        return text
    }

    private static func authText(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    static func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { acc, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            acc.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier
    }
}
