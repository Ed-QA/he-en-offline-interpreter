import SwiftUI

// MARK: - Full log (Close + native Share → Messages / Mail as .txt)

struct LogSheet: View {
    @EnvironmentObject var p: Pipeline
    @Environment(\.dismiss) private var dismiss
    @State private var logURL: URL?

    var body: some View {
        NavigationStack {
            List(p.log) { e in
                VStack(alignment: .leading, spacing: 4) {
                    Text(DateFormatter.logStamp.string(from: e.date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(e.hebrew)
                        .font(.body)
                        .environment(\.layoutDirection, .rightToLeft)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text(e.english.isEmpty ? "…" : e.english)
                        .font(.body.bold())
                    if e.forced {
                        Text("incomplete chunk (forced by latency cap)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Full log (\(p.log.count))")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Label("Close", systemImage: "xmark") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let logURL {
                        ShareLink(item: logURL) { Label("Send", systemImage: "square.and.arrow.up") }
                    }
                }
            }
            .onAppear { logURL = p.writeLogFile() }
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
