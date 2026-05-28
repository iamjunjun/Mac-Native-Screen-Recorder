import SwiftUI

@main
struct NativeScreenRecorderApp: App {
    @StateObject private var store = RecorderStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 720)
                .task {
                    await store.refreshShareableContent()
                    // Defer audio process scanning to avoid CoreAudio assertion at startup
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    store.mergeAudioProcesses()
                }
        }
        .defaultSize(width: 1040, height: 760)
        .windowResizability(.contentMinSize)
    }
}
