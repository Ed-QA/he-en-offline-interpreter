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
                .font(Theme.captionFont)
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

    /// One big status light. Green = ready and working. No prose on the main screen:
    /// the only text allowed here is the status word itself and a real problem message.
    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(ledColor.opacity(0.22)).frame(width: 46, height: 46)
                Circle().fill(ledColor).frame(width: 26, height: 26)
                    .shadow(color: ledColor.opacity(0.9), radius: 8)
            }
            Text(ledTitle)
                .font(Theme.statusFont)
                .foregroundStyle(ledColor)
                .accessibilityIdentifier("statusTitle")
            Spacer()
            if let problem = ledProblem {
                Text(problem)
                    .font(Theme.captionFont)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(3)
                    .accessibilityIdentifier("statusProblem")
            }
        }
    }

    /// Only ever returns text when something is actually wrong — everything else lives in
    /// Settings, where the model proof and diagnostics belong.
    private var ledProblem: String? {
        if let err = p.lastError { return err }
        if case .failed(let why) = p.modelsState { return why }
        return nil
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

    private var hebrewPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView {
                Text(p.hebrewLive.isEmpty ? "…" : p.hebrewLive)
                    .font(Theme.panelFont)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("hebrewText")
            }
            .frame(height: 110)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
        .environment(\.layoutDirection, .rightToLeft)
        .accessibilityIdentifier("hebrewPanel")
    }

    private var englishPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView {
                Text(p.englishText.isEmpty ? "…" : p.englishText)
                    .font(Theme.panelFont)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("englishText")
            }
        }
        .padding(8)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
        .accessibilityIdentifier("englishPanel")
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
            .accessibilityIdentifier("mainToggle")
            .accessibilityLabel(p.running ? "Stop listening" : "Start listening")

            HStack(spacing: 10) {
                iconButton("arrow.uturn.left", "Repeat last sentence") { p.repeatLast() }
                iconButton("list.bullet.rectangle", "Log") { showLog = true }
                iconButton("gearshape", "Settings") { showSettings = true }
            }
            Spacer()
        }
    }

    /// Icon-only control: no static prose on the main screen, but still reachable for VoiceOver.
    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 46, height: 46)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.tertiarySystemGroupedBackground)))
        }
        .accessibilityLabel(label)
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

/// Single source of truth for typography so the screens cannot drift apart again.
enum Theme {
    static let statusFont = Font.title2.bold()
    static let panelFont = Font.body
    static let captionFont = Font.caption
    static let corner: CGFloat = 12
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
