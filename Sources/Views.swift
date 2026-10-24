import SwiftUI
import Translation

struct ContentView: View {
    @EnvironmentObject var p: Pipeline
    @State private var showLog = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 10) {
            header
            hebrewPanel
            englishPanel
            controls
        }
        .padding(12)
        .background(Color(.systemGroupedBackground))
        .modifier(TranslationAnchor())
        .sheet(isPresented: $showLog) { LogSheet() }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .task { await p.prepare() }
        .alert("Error", isPresented: Binding(
            get: { p.lastError != nil },
            set: { if !$0 { p.lastError = nil } }
        )) {
            Button("OK") { p.lastError = nil }
        } message: {
            Text(p.lastError ?? "")
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            HStack {
                Circle()
                    .fill(color(for: p.status))
                    .frame(width: 10, height: 10)
                Text(p.status.rawValue)
                    .font(.headline)
                Spacer()
                Text(p.running ? "ON AIR" : "OFF")
                    .font(.caption.bold())
                    .foregroundStyle(p.running ? .green : .secondary)
            }
            Text(p.engineStatus)
                .font(.caption2)
                .foregroundStyle(p.engineReady ? .green : .orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("STT: \(p.sttStatus)  •  gate: \(p.lastGateReason.isEmpty ? "—" : p.lastGateReason)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var hebrewPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("עברית — מה שנאמר")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(p.hebrewLive.isEmpty ? "…" : p.hebrewLive)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .textSelection(.enabled)
            }
            .frame(height: 110)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
        .environment(\.layoutDirection, .rightToLeft)
    }

    private var englishPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("English — translation")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(p.englishText.isEmpty ? "…" : p.englishText)
                    .font(.title3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button {
                if p.running { p.stop() } else { p.start() }
            } label: {
                Image(systemName: p.running ? "stop.fill" : "mic.fill")
                    .font(.system(size: 30, weight: .bold))
                    .frame(width: 78, height: 78)
                    .background(Circle().fill(p.running ? Color.red : Color.accentColor))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    smallButton("arrow.uturn.left", "Repeat") { p.repeatLast() }
                    smallButton("list.bullet.rectangle", "Full log") { showLog = true }
                }
                HStack(spacing: 10) {
                    Button {
                        // Reserved for the next phase: earbud-mic English → Hebrew via phone speaker.
                    } label: {
                        Label("ENG→HEB", systemImage: "lock.fill")
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemGroupedBackground)))
                            .foregroundStyle(.secondary)
                    }
                    .disabled(true)
                    smallButton("gearshape", "Settings") { showSettings = true }
                }
            }
            Spacer()
        }
    }

    private func smallButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemGroupedBackground)))
        }
    }

    private func color(for status: Pipeline.Status) -> Color {
        switch status {
        case .idle: return .gray
        case .listening: return .green
        case .translating: return .orange
        case .speaking: return .blue
        case .error: return .red
        }
    }
}

/// Anchors an Apple TranslationSession to a live view (iOS 18+).
struct TranslationAnchor: ViewModifier {
    @EnvironmentObject var p: Pipeline

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.translationTask(p.translationConfiguration) { session in
                await MainActor.run { p.attachTranslationSession(session) }
            }
        } else {
            content
        }
    }
}
