import SwiftUI

// MARK: - Settings

struct SettingsSheet: View {
    @EnvironmentObject var p: Pipeline
    @Environment(\.dismiss) private var dismiss
    @State private var showProbe = false
    @State private var probeText = ""
    @State private var showSamples = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Engine") {
                    Text(p.engineStatus).font(.footnote)
                    Text("STT: \(p.sttStatus)").font(.footnote)
                    Button("Re-check availability") { Task { await p.prepare() } }
                }
                Section("Voice") {
                    Picker("Voice", selection: $p.voiceIdentifier) {
                        ForEach(Speaker.englishVoices(), id: \.identifier) { v in
                            Text("\(v.name) [\(v.language)] — \(Speaker.qualityLabel(v))")
                                .tag(Optional(v.identifier))
                        }
                    }
                    HStack {
                        Text("Rate")
                        Slider(value: $p.rate, in: 0.35...0.65)
                    }
                }
                Section("Chunking — Hebrew sense gate") {
                    Picker("Mode", selection: $p.gateMode) {
                        ForEach(GateMode.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                }
                Section("Voice samples — 20 seconds each") {
                    Button("Generate samples for ALL English voices") {
                        p.runVoiceSampler()
                        showSamples = true
                    }
                    if let progress = p.voiceSampleProgress {
                        Text(progress).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Diagnostics") {
                    Button("Run capability probe") {
                        Task {
                            probeText = await CapabilityProbe.run()
                            showProbe = true
                        }
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
