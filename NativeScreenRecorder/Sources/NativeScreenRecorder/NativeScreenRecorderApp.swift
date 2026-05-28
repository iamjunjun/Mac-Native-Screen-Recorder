import SwiftUI

@main
struct NativeScreenRecorderApp: App {
    @StateObject private var store = RecorderStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(width: 560, height: 430)
                .task {
                    await store.refreshShareableContent()
                }
        }
        .windowResizability(.contentSize)
    }
}
