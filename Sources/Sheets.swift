import SwiftUI

// MARK: - Full log (Close + native Share → Messages / Mail as .txt)

struct LogSheet: View {
    @EnvironmentObject var p: Pipeline
    @Environment(\.dismiss) private var dismiss
    @State private var logURL: URL?
    @State private var trace = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Send logs is a full-height row of its own: as a toolbar item it reported a 36 pt
                // accessibility frame, below the 44 pt tap-target rule (ShareLogsUITests asserts
                // that directly). The label is primary-coloured because the button tint fails the
                // audit's contrast rule on this background.
                if let logURL {
                    ShareLink(item: logURL) {
                        Label("Send logs", systemImage: "square.and.arrow.up")
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("shareLogs")
                    .padding(.horizontal, 16)
                    Divider()
                }
                if p.log.isEmpty {
                    // Item 4: this screen must never look empty. Before the first sentence is
                    // emitted it shows the live on-device trace instead of a blank list.
                    ScrollView {
                        Text(trace.isEmpty ? "…" : trace)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .accessibilityIdentifier("logTrace")
                    }
                } else {
                    List(p.log) { e in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(DateFormatter.logStamp.string(from: e.date))
                                .font(Theme.captionFont)
                                .foregroundStyle(.secondary)
                            Text(e.hebrew)
                                .font(Theme.panelFont)
                                .environment(\.layoutDirection, .rightToLeft)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(e.english.isEmpty ? "…" : e.english)
                                .font(Theme.panelFont.bold())
                            if e.forced {
                                Text("incomplete chunk (forced by latency cap)")
                                    .font(Theme.captionFont)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Log (\(p.log.count))")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Label("Close", systemImage: "xmark") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Send logs is a list row now (see the first Section): toolbar items report a
                    // 36 pt accessibility frame, under the 44 pt tap-target rule.
                    EmptyView()
                }
            }
            .onAppear {
                trace = Pipeline.traceTail()
                logURL = p.writeLogFile()
            }
        }
    }
}

// MARK: - Generic text sheet with Share

struct TextSheet: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var url: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let url {
                        ShareLink(item: url) { Label("Send", systemImage: "square.and.arrow.up") }
                    }
                }
            }
            .onAppear {
                let name = title.replacingOccurrences(of: " ", with: "_") + ".txt"
                let u = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try? text.write(to: u, atomically: true, encoding: .utf8)
                url = u
            }
        }
    }
}
