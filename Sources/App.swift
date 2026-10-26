import Foundation
import SwiftUI

@main
struct HEENApp: App {
    @StateObject private var pipeline = Pipeline()

    init() {
        // UI tests start from a known settings state. Nothing else passes this flag, and the
        // pipeline object is created lazily on first render, so this reset lands before it reads.
        if ProcessInfo.processInfo.arguments.contains("-HEENResetPrefs") { Prefs.reset() }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(pipeline)
        }
    }
}
