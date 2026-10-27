import SwiftUI

// MARK: - Settings

struct SettingsSheet: View {
    @EnvironmentObject var p: Pipeline
    @Environment(\.dismiss) private var dismiss
    @State private var reportURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                // Item 9: three blocks only — voice, chunking, and Send logs. Routing is iOS's job:
                // the row below only *shows* what the system is really using, and it follows the
                // system's own route-change notification. There is no app-side selector to go stale.
                Section {
                    // One switch for both translation and speech: the model, the voice and the
                    // speed all follow it, and each language remembers its own voice and speed.
                    Picker("Language", selection: $p.target) {
                        ForEach(TargetLanguage.allCases) { lang in
                            Text(lang.label).tag(lang)
                        }
                    }
                    .accessibilityIdentifier("languagePicker")
                    Picker("Microphone", selection: $p.micUID) {
                        Text("Automatic").tag(String?.none)
                        ForEach(AudioRoute.inputOptions(), id: \.uid) { port in
                            // Stored by name: a port uid changes on every reconnect, a name does not.
                            Text(port.portName).tag(String?.some(port.portName))
                        }
                    }
                    .accessibilityIdentifier("micPicker")
                    Picker("Output", selection: $p.outputChoice) {
                        ForEach(AudioRoute.outputOptions(), id: \.self) { choice in
                            Text(AudioRoute.label(choice)).tag(choice)
                        }
                    }
                    .accessibilityIdentifier("outputPicker")
                    Picker("Voice", selection: $p.voiceIdentifier) {
                        ForEach(Speaker.voices(for: p.target), id: \.identifier) { v in
                            Text("\(v.name) · \(v.language) · \(Speaker.qualityLabel(v))")
                                .tag(Optional(v.identifier))
                        }
                    }
                    .accessibilityIdentifier("voicePicker")
                    HStack {
                        Text("Rate")
                        Slider(value: $p.rate, in: Prefs.rateRange)
                            .accessibilityIdentifier("rateSlider")
                        Text(String(format: "%.2f", p.rate))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Button("Hear this voice") { p.speakSample() }
                        .accessibilityIdentifier("testVoice")
                } header: {
                    Text("Voice")
                }
                Section {
                    Picker("Mode", selection: $p.gateMode) {
                        ForEach(GateMode.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .accessibilityIdentifier("gateModePicker")
                } header: {
                    Text("Chunking")
                }
                Section {
                    // The row is always present: while the report is still being written it renders
                    // as a plain label, so it can never disappear from under the user or the audit.
                    if let reportURL {
                        ShareLink(item: reportURL) {
                            Label("Send logs", systemImage: "square.and.arrow.up")
                                // Primary colour: the button tint fails the contrast rule on this
                                // background (same fix as the log sheet's row).
                                .foregroundStyle(.primary)
                        }
                        .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                            .accessibilityIdentifier("shareLogsSettings")
                    } else {
                        Label("Send logs", systemImage: "square.and.arrow.up")
                            .foregroundStyle(.secondary)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("shareLogsSettings")
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } }
            }
            // The report is written when the sheet opens, so "Send logs" always shares a fresh file.
            .task {
                reportURL = p.writeLogFile()
                // Native routing: the displayed route comes from the session and is refreshed by
                // the system's route-change notification — no polling loop.
                p.observeAudioRoute()
            }
        }
    }
}

// MARK: - Voice samples report

struct VoiceSamplesSheet: View {
    @EnvironmentObject var p: Pipeline
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let progress = p.voiceSampleProgress {
                    Section("Progress") {
                        Text(progress)
                        if p.voiceSamplerRunning {
                            Button("Cancel", role: .destructive) { p.cancelVoiceSampler() }
                                .accessibilityIdentifier("cancelVoiceSampler")
                        }
                    }
                }
                if let report = p.voiceSampleReport {
                    Section("Verification (3 checks)") {
                        ForEach(Array(report.checks.enumerated()), id: \.offset) { _, check in
                            HStack {
                                Image(systemName: check.1 ? "checkmark.seal.fill" : "xmark.seal.fill")
                                    .foregroundStyle(check.1 ? .green : .red)
                                Text(check.0).font(.footnote)
                            }
                        }
                    }
                    Section("Samples (\(report.samples.count))") {
                        ForEach(Array(report.samples.enumerated()), id: \.offset) { _, s in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(s.voiceName) — \(s.language) (\(s.quality))")
                                    .font(.footnote.bold())
                                Text(String(format: "%.2fs • rms %.4f • %@",
                                            s.duration, s.rms, String(s.sha256.prefix(10))))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(s.fileName).font(.caption2).foregroundStyle(.secondary)
                                if let error = s.error {
                                    Text(error).font(.caption2).foregroundStyle(.red)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Voice samples")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    if let url = p.voiceSampleReport?.reportURL {
                        ShareLink(item: url) { Label("Send report", systemImage: "square.and.arrow.up") }
                    }
                }
            }
        }
    }
}
