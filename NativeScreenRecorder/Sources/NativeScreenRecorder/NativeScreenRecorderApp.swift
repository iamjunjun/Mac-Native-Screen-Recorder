import SwiftUI

@main
struct NativeScreenRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
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
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            MenuBarView(store: store)
        } label: {
            Image(systemName: store.isRecording ? "record.circle.fill" : "record.circle")
                .foregroundStyle(store.isRecording ? .red : .primary)
        }
        .menuBarExtraStyle(.menu)
    }
}
