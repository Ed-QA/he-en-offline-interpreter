import SwiftUI
import Translation

struct ContentView: View {
    @EnvironmentObject var p: Pipeline
    @State private var showLog = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 10) {
            header
            if let err = p.lastError { errorBanner(err) }
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
    }

    /// Errors are shown inline — never as a modal dialog that blocks the screen.
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .font(.caption)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { p.lastError = nil } label: {
                Image(systemName: "xmark.circle.fill")
            }
        }
        .foregroundStyle(.white)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.85)))
    }

    /// One big status light. Green = ready and working. Nothing else to read.
    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(ledColor.opacity(0.22)).frame(width: 46, height: 46)
                Circle().fill(ledColor).frame(width: 26, height: 26)
                    .shadow(color: ledColor.opacity(0.9), radius: 8)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(ledTitle)
                    .font(.title3.bold())
                    .foregroundStyle(ledColor)
                Text(ledSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text(p.running ? "ON AIR" : "OFF")
                .font(.caption.bold())
                .foregroundStyle(p.running ? .green : .secondary)
        }
    }

    private var ledColor: Color {
        if p.lastError != nil { return .red }
        if case .failed = p.modelsState { return .red }
        switch p.status {
        case .error: return .red
        case .idle: return p.modelsState.isActive ? .green : .orange
        case .listening, .translating, .speaking: return .green
        }
    }

    private var ledTitle: String {
        if p.lastError != nil { return "ERROR" }
        if case .failed = p.modelsState { return "MODELS FAILED" }
        switch p.status {
        case .idle: return p.modelsState.isActive ? "READY" : "STARTING…"
        case .listening: return "LISTENING"
        case .translating: return "TRANSLATING"
        case .speaking: return "SPEAKING"
        case .error: return "ERROR"
        }
    }

    private var ledSubtitle: String {
        switch p.modelsState {
        case .loading: return "loading offline model…"
        case .active(let proof): return "models active ✓  (\(proof))"
        case .failed(let why): return "model problem: \(why)"
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
