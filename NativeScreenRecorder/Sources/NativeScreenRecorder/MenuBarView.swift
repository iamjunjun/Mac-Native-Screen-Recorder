import SwiftUI

struct MenuBarView: View {
    @ObservedObject var store: RecorderStore

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Circle()
                    .fill(store.isRecording ? .red : .green)
                    .frame(width: 8, height: 8)
                Text(store.isRecording ? L.recording : L.ready)
                    .font(.headline)
            }
            .padding(.bottom, 4)

            if store.isRecording {
                Text(store.formattedElapsedTime)
                    .font(.system(.body, design: .monospaced))
                    .padding(.bottom, 4)
            }

            Divider()

            Button {
                Task {
                    if store.isRecording {
                        await store.stopRecording()
                    } else {
                        await store.startRecording()
                    }
                }
            } label: {
                HStack {
                    Image(systemName: store.isRecording ? "stop.fill" : "record.circle")
                    Text(store.isRecording ? L.stopRecording : L.startRecording)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(Color.clear)
            .contentShape(Rectangle())
            .keyboardShortcut("r", modifiers: .command)

            Divider()

            Button {
                openMainWindow()
            } label: {
                HStack {
                    Image(systemName: "macwindow")
                    Text(L.openMainWindow)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(Color.clear)
            .contentShape(Rectangle())
            .keyboardShortcut("o", modifiers: .command)

            Divider()

            Button {
                NSApp.terminate(nil)
            } label: {
                HStack {
                    Image(systemName: "power")
                    Text(L.quit)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(Color.clear)
            .contentShape(Rectangle())
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(12)
        .frame(width: 220)
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            if window.className.contains("SwiftUI") || window.title.contains("NativeScreenRecorder") {
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
    }
}
