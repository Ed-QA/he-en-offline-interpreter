import SwiftUI
import Translation
import UIKit

struct ContentView: View {
    @EnvironmentObject var p: Pipeline
    @Environment(\.colorScheme) private var colorScheme
    @State private var showLog = false
    @State private var showSettings = false
    /// The status light follows Dynamic Type (a fixed 46/26 pt dot next to XL text read as a speck).
    @ScaledMetric(relativeTo: .title2) private var ledOuter: CGFloat = 46
    @ScaledMetric(relativeTo: .title2) private var ledInner: CGFloat = 26

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
        .sheet(isPresented: $showLog) { LogSheet().presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .sensoryFeedback(.impact(weight: .medium), trigger: p.running)
        .task { await p.prepare() }
    }

    /// Errors are shown inline — never as a modal dialog that blocks the screen.
    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                // No line limit: a truncated error with nowhere else to read it is a dead end.
                Text(message)
                    .font(Theme.captionFont)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { p.lastError = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .accessibilityLabel("Dismiss")
            }
            if message.localizedCaseInsensitiveContains("microphone") {
                // A denied microphone was a dead end: the only fix lives in the system app.
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(Theme.captionFont.bold())
                .frame(minHeight: 44)
                .accessibilityIdentifier("openSettings")
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
                // Scaled with Dynamic Type: a fixed 46 pt dot next to XL text read as a speck.
                Circle().fill(ledColor.opacity(0.22)).frame(width: ledOuter, height: ledOuter)
                Circle().fill(ledColor).frame(width: ledInner, height: ledInner)
                    .shadow(color: ledColor.opacity(0.9), radius: 8)
            }
            Text(ledTitle)
                .font(Theme.statusFont)
                .foregroundStyle(ledColor)
                .accessibilityIdentifier("statusTitle")
            if isStarting {
                // A cold start takes 10-30 s: something has to move, or it looks hung.
                ProgressView().controlSize(.small)
            }
            Spacer()
        }
    }

    /// Models still loading / engine not up yet.
    private var isStarting: Bool { p.status == .idle && !p.modelsState.isActive }

    private var ledColor: Color {
        if p.lastError != nil { return .red }
        if case .failed = p.modelsState { return .red }
        switch p.status {
        case .error: return .red
        case .idle: return p.modelsState.isActive ? Self.ok(colorScheme) : Self.wait(colorScheme)
        case .listening, .translating, .speaking: return Self.ok(colorScheme)
        }
    }

    /// The system green/orange sat at ~2:1 on `systemGroupedBackground` in light mode — below
    /// both the 4.5:1 body bar and the 3:1 large-text bar. These two adapt per colour scheme.
    private static func ok(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.30, green: 0.85, blue: 0.45)
                        : Color(red: 0.00, green: 0.42, blue: 0.20)
    }

    private static func wait(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 1.00, green: 0.72, blue: 0.30)
                        : Color(red: 0.58, green: 0.31, blue: 0.00)
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
                if p.hebrewLive.isEmpty {
                    hint("Speak Hebrew — the words appear here", id: "hebrewText")
                        .environment(\.layoutDirection, .leftToRight)
                } else {
                    Text(p.hebrewLive)
                        .font(Theme.panelFont)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("hebrewText")
                }
            }
            .defaultScrollAnchor(.bottom)   // the newest words stay in view while speaking
            .frame(maxHeight: .infinity)
        }
        .padding(8)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
        .environment(\.layoutDirection, .rightToLeft)
        .accessibilityIdentifier("hebrewPanel")
    }

    /// The empty panels used to show a bare "…": at large text that is a huge ellipsis in an
    /// empty card, which reads as a broken screen. One short hint instead, and it keeps the
    /// panel's text identifier so the layout and audit checks still find the element.
    private func hint(_ text: String, id: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform").font(.footnote)
            Text(text)
                .font(Theme.captionFont)
                .accessibilityIdentifier(id)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 6)
    }

    private var englishPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView {
                if p.englishText.isEmpty {
                    hint("The English translation appears here", id: "englishText")
                } else {
                    Text(p.englishText)
                        .font(Theme.panelFont)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("englishText")
                }
            }
            .defaultScrollAnchor(.bottom)   // the newest words stay in view while speaking
            .frame(maxHeight: .infinity)
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
                    .symbolEffect(.pulse, options: .repeating, isActive: p.running)
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
                // `tertiarySystemGroupedBackground` is almost white in light mode, so the chips
                // read as floating glyphs next to the solid mic circle. A card fill plus a
                // hairline separator is visible in both schemes.
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.secondarySystemGroupedBackground))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(.separator), lineWidth: 1)
                        )
                )
        }
        .accessibilityLabel(label)
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
