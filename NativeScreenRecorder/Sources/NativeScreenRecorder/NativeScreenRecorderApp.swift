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
                    // Defer audio process scanning to avoid CoreAudio assertion at startup
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    store.mergeAudioProcesses()
                }
        }
        .windowResizability(.contentSize)
    }
}
