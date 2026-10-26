import SwiftUI

// MARK: - Settings

struct SettingsSheet: View {
    @EnvironmentObject var p: Pipeline
    @Environment(\.dismiss) private var dismiss
    @State private var showProbe = false
    @State private var probeText = ""
    @State private var showSamples = false
    @State private var reportURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section("Engine") {
                    Text(p.engineStatus).font(.footnote)
                    Text("STT: \(p.sttStatus)").font(.footnote)
                    if case .active(let proof) = p.modelsState {
                        Text("Model self-test: \(proof)").font(.footnote)
                    }
                    Button("Re-check availability") { Task { await p.prepare() } }
                }
                Section {
                    Picker("Voice", selection: $p.voiceIdentifier) {
                        ForEach(Speaker.englishVoices(), id: \.identifier) { v in
                            Text("\(v.name) [\(v.language)] — \(Speaker.qualityLabel(v))")
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
                } footer: {
                    Text("The interpreter speaks English with the system voice. \"Hear this voice\" plays one sentence.")
                }
                Section {
                    Picker("Mode", selection: $p.gateMode) {
                        ForEach(GateMode.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .accessibilityIdentifier("gateModePicker")
                } header: {
                    Text("Chunking — Hebrew sense gate")
                } footer: {
                    Text("How long the app waits for a sentence to make sense before translating and speaking it. Fast is snappier; Complete waits longer.")
                }
                Section("Diagnostics") {
                    // The row is always present: while the report is still being written it renders
                    // as a plain label, so it can never disappear from under the user or the audit.
                    if let reportURL {
                        ShareLink(item: reportURL) { Label("Send logs", systemImage: "square.and.arrow.up") }
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                            .accessibilityIdentifier("shareLogsSettings")
                    } else {
                        Label("Send logs", systemImage: "square.and.arrow.up")
                            .foregroundStyle(.secondary)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("shareLogsSettings")
                    }
                    Button("Run capability probe") {
                        Task {
                            probeText = await CapabilityProbe.run()
                            showProbe = true
                        }
                    }
                }
                Section {
                    Button("Reset settings", role: .destructive) { p.resetSettings() }
                        .accessibilityIdentifier("resetSettings")
                } footer: {
                    Text("Restores the default voice, rate and chunking mode.")
                }
                Section("Developer") {
                    Button("Generate voice samples for ALL English voices") {
                        p.runVoiceSampler()
                        showSamples = true
                    }
                    Text("Writes a 20-second sample per voice into the app's Documents folder. Not needed for normal use.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let progress = p.voiceSampleProgress {
                        Text(progress).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("Total offline. No network, no APIs. All processing happens on this iPhone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } }
            }
            .sheet(isPresented: $showProbe) { TextSheet(title: "Capability probe", text: probeText) }
            .sheet(isPresented: $showSamples) { VoiceSamplesSheet() }
            // The report is written when the sheet opens, so "Send logs" always shares a fresh file.
            .task { reportURL = p.writeLogFile() }
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
                    Section("Progress") { Text(progress) }
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
