import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: RecorderStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            settingsPanel
            statusPanel

            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("Native Screen Recorder")
                    .font(.system(size: 22, weight: .semibold))
                Text("原生录屏，不影响当前声音播放。")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await store.refreshShareableContent() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(store.isRecording)
        }
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("录制范围") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("显示器", selection: $store.selectedDisplayID) {
                        ForEach(store.displays) { display in
                            Text("\(display.title)  \(display.subtitle)")
                                .tag(Optional(display.id))
                        }
                    }
                    .disabled(store.isRecording)

                    Picker("声音来源", selection: $store.audioMode) {
                        ForEach(AudioCaptureMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(store.isRecording)

                    if store.audioMode == .selectedApplication {
                        Picker("应用", selection: $store.selectedApplicationID) {
                            ForEach(store.applications) { app in
                                Text(app.title).tag(Optional(app.id))
                            }
                        }
                        .disabled(store.isRecording)
                    }
                }
                .padding(.vertical, 8)
            }

            GroupBox("保存") {
                HStack(spacing: 12) {
                    Text(store.outputURL.deletingLastPathComponent().path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        store.chooseOutputFolder()
                    } label: {
                        Label("选择文件夹", systemImage: "folder")
                    }
                    .disabled(store.isRecording)
                }
                .padding(.vertical, 8)
            }
        }
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    Task {
                        if store.isRecording {
                            await store.stopRecording()
                        } else {
                            await store.startRecording()
                        }
                    }
                } label: {
                    Label(store.isRecording ? "停止" : "开始录制", systemImage: store.isRecording ? "stop.fill" : "record.circle")
                        .frame(width: 116)
                }
                .buttonStyle(.borderedProminent)
                .tint(store.isRecording ? .red : .accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(store.isRecording ? "录制中" : "待命")
                        .font(.headline)
                    Text(store.statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 14) {
                InfoRow(label: "声音", value: store.audioMode.title)
                InfoRow(label: "文件", value: store.outputURL.lastPathComponent)
            }

            if let errorText = store.errorText {
                VStack(alignment: .leading, spacing: 8) {
                    Text(errorText)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)

                    if store.isPermissionDenied {
                        Button("打开系统设置") {
                            store.openScreenRecordingPrefs()
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}
