import SwiftUI

@main
struct HEENApp: App {
    @StateObject private var pipeline = Pipeline()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(pipeline)
        }
    }
}
