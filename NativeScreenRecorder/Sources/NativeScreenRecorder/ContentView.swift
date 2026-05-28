import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: RecorderStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    captureSection
                    outputSection
                }
            }

            recordBar
        }
        .padding(20)
        .background(.regularMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("原生录屏")
                    .font(.system(size: 22, weight: .bold))
                Text("不影响当前声音播放")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task {
                    await store.refreshShareableContent()
                    store.mergeAudioProcesses()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(store.isRecording)
            .help("刷新设备与应用列表")
        }
    }

    // MARK: - Capture Section

    private var captureSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // 录制模式
                LabeledContent("录制模式") {
                    Picker("录制模式", selection: $store.captureMode) {
                        ForEach(CaptureMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                .disabled(store.isRecording)

                Divider()

                // 显示器
                LabeledContent("显示器") {
                    Picker("显示器", selection: $store.selectedDisplayID) {
                        ForEach(store.displays) { display in
                            Text(display.title).tag(Optional(display.id))
                        }
                    }
                    .labelsHidden()
                    .disabled(store.isRecording)
                }

                if store.captureMode == .area {
                    HStack(spacing: 8) {
                        Button {
                            store.startAreaSelection()
                        } label: {
                            Label("拖选区域", systemImage: "rectangle.dashed")
                        }
                        .disabled(store.isRecording)

                        if let rect = store.selectedAreaRect {
                            Text("已选: \(Int(rect.width)) × \(Int(rect.height))")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()

                // 声音来源
                LabeledContent("声音来源") {
                    Picker("声音来源", selection: $store.audioMode) {
                        ForEach(AudioCaptureMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                .disabled(store.isRecording)

                if store.audioMode == .selectedApplication {
                    LabeledContent("应用") {
                        Picker("应用", selection: $store.selectedApplicationID) {
                            ForEach(store.applications) { app in
                                Text(app.name).tag(Optional(app.id))
                            }
                        }
                        .labelsHidden()
                        .disabled(store.isRecording)
                    }
                }

                Divider()

                // 麦克风
                HStack(alignment: .firstTextBaseline) {
                    Toggle(isOn: $store.isMicrophoneEnabled) {
                        Text("麦克风")
                    }
                    .disabled(store.isRecording)

                    Text("建议佩戴耳机以避免回声")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
        } label: {
            Label("录制", systemImage: "rectangle.inset.filled.badge.record")
        }
    }

    // MARK: - Output Section

    private var outputSection: some View {
        HStack(alignment: .top, spacing: 12) {
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("视频编码", selection: $store.preferredCodec) {
                        ForEach(VideoCodec.allCases) { codec in
                            Text(codec.title).tag(codec)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(store.isRecording)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            } label: {
                Label("编码", systemImage: "gearshape")
            }

            GroupBox {
                HStack(spacing: 10) {
                    Text(store.outputURL.lastPathComponent)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        store.chooseOutputFolder()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .disabled(store.isRecording)
                    .help("选择保存位置")

                    Button {
                        store.openOutputFolder()
                    } label: {
                        Image(systemName: "folder.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("打开保存位置")
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            } label: {
                Label("存储", systemImage: "folder")
            }
        }
    }

    // MARK: - Record Bar

    private var recordBar: some View {
        VStack(spacing: 10) {
            if let errorText = store.errorText {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
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

            HStack(spacing: 16) {
                Button {
                    Task {
                        if store.isRecording {
                            await store.stopRecording()
                        } else {
                            await store.startRecording()
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: store.isRecording ? "stop.fill" : "circle.fill")
                            .font(.system(size: 12))
                        Text(store.isRecording ? "停止录制" : "开始录制")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .frame(width: 180, height: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(store.isRecording ? .red : .blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text(store.isRecording ? "录制中" : "就绪")
                        .font(.subheadline.weight(.medium))
                    Text(store.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}
