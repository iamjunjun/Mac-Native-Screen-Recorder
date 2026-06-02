import SwiftUI

struct MenuBarView: View {
    @ObservedObject var store: RecorderStore

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Circle()
                    .fill(store.isPaused ? .yellow : (store.isRecording ? .red : .green))
                    .frame(width: 8, height: 8)
                Text(store.isPaused ? "paused" : (store.isRecording ? "recording" : "ready"), bundle: .module)
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
                    Text(store.isRecording ? "stop_recording" : "start_recording", bundle: .module)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(Color.clear)
            .contentShape(Rectangle())
            .keyboardShortcut("r", modifiers: .command)

            if store.isRecording {
                Divider()

                Button {
                    if store.isPaused {
                        store.resumeRecording()
                    } else {
                        store.pauseRecording()
                    }
                } label: {
                    HStack {
                        Image(systemName: store.isPaused ? "play.fill" : "pause.fill")
                        Text(store.isPaused ? "resume_recording" : "pause_recording", bundle: .module)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(Color.clear)
                .contentShape(Rectangle())
                .keyboardShortcut("p", modifiers: .command)
            }

            Divider()

            Button {
                openMainWindow()
            } label: {
                HStack {
                    Image(systemName: "macwindow")
                    Text("open_main_window", bundle: .module)
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
                    Text("quit", bundle: .module)
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
