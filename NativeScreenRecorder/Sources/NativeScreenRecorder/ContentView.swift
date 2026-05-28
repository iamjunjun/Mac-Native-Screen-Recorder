import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: RecorderStore
    private let controlHeight: CGFloat = 44
    private let panelHeight: CGFloat = 310
    private let panelGap: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            heroControls

            GeometryReader { proxy in
                let columnWidth = (proxy.size.width - panelGap) / 2
                HStack(alignment: .top, spacing: panelGap) {
                    capturePanel
                        .frame(width: columnWidth, height: panelHeight)

                    VStack(spacing: 18) {
                        codecPanel
                            .frame(height: 126)
                        storagePanel
                            .frame(height: panelHeight - 126 - 18)
                    }
                    .frame(width: columnWidth, height: panelHeight)
                }
            }
            .frame(height: panelHeight)

            recordBar
            Spacer(minLength: 0)
        }
        .padding(28)
        .background(appBackground)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("原生录屏")
                    .font(.system(size: 30, weight: .bold))
                Text("不影响当前声音播放")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task {
                    await store.refreshShareableContent()
                    store.mergeAudioProcesses()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.36, green: 0.66, blue: 1.00),
                                    Color(red: 0.18, green: 0.46, blue: 0.92)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)
                        .shadow(color: Color(red: 0.18, green: 0.46, blue: 0.92).opacity(0.28), radius: 14, y: 7)
                    Circle()
                        .stroke(.white.opacity(0.62), lineWidth: 1)
                        .frame(width: 44, height: 44)
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.borderless)
            .disabled(store.isRecording)
            .help("刷新设备与应用列表")
        }
    }

    private var heroControls: some View {
        HStack(spacing: 0) {
            HeroModeButton(
                title: "全屏",
                systemImage: "desktopcomputer",
                tint: .cyan,
                isSelected: store.captureMode == .fullScreen
            ) {
                store.captureMode = .fullScreen
            }
            .disabled(store.isRecording)

            Spacer(minLength: 20)

            HeroModeButton(
                title: "自定义区域",
                systemImage: "crop",
                tint: .purple,
                isSelected: store.captureMode == .area
            ) {
                store.captureMode = .area
                store.startAreaSelection()
            }
            .disabled(store.isRecording)

            Spacer(minLength: 24)

            Divider()
                .frame(height: 76)
                .opacity(0.35)

            Spacer(minLength: 24)

            Button {
                Task {
                    if store.isRecording {
                        await store.stopRecording()
                    } else {
                        await store.startRecording()
                    }
                }
            } label: {
                VStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(.white.opacity(0.55))
                            .frame(width: 112, height: 112)
                            .shadow(color: .red.opacity(store.isRecording ? 0.36 : 0.28), radius: 34, y: 14)
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: store.isRecording
                                        ? [Color.red.opacity(0.95), Color.red.opacity(0.55), Color.white.opacity(0.25)]
                                        : [Color.red.opacity(0.82), Color.red.opacity(0.42), Color.white.opacity(0.22)],
                                    center: .center,
                                    startRadius: 8,
                                    endRadius: 58
                                )
                            )
                            .frame(width: 82, height: 82)
                        Circle()
                            .stroke(.white.opacity(0.75), lineWidth: 1)
                            .frame(width: 112, height: 112)
                    }

                    Text(store.isRecording ? "停止录制" : "开始录制")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 24)

            Divider()
                .frame(height: 76)
                .opacity(0.35)

            Spacer(minLength: 24)

            HeroToggleButton(
                title: "麦克风",
                systemImage: "mic",
                tint: .gray,
                isOn: $store.isMicrophoneEnabled
            )
            .disabled(store.isRecording)

            Spacer(minLength: 20)

            HeroToggleButton(
                title: "系统声音",
                systemImage: "video.fill",
                tint: .orange,
                isOn: Binding(
                    get: { store.audioMode == .globalSystem },
                    set: { isOn in
                        store.audioMode = isOn ? .globalSystem : .selectedApplication
                    }
                )
            )
            .disabled(store.isRecording)
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: 34, shadowRadius: 26)
    }

    private var capturePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingsRow("录制模式") {
                segmentedCaptureMode
            }

            panelDivider

            if store.captureMode == .area {
                settingsRow("拖选区域") {
                    HStack(spacing: 12) {
                        Button {
                            store.startAreaSelection()
                        } label: {
                            Image(systemName: "crop")
                                .font(.system(size: 22, weight: .semibold))
                                .frame(width: 42, height: 34)
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isRecording)

                        Text(selectedAreaText)
                            .font(.caption)
                            .foregroundStyle(store.selectedAreaRect == nil ? .tertiary : .secondary)
                    }
                }
            } else {
                settingsRow("显示器") {
                    Menu {
                        ForEach(store.displays) { display in
                            Button(display.title) {
                                store.selectedDisplayID = display.id
                            }
                        }
                    } label: {
                        selectionField(selectedDisplayTitle, showsChevron: true)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isRecording)
                }
            }

            panelDivider

            settingsRow("声音来源") {
                segmentedAudioMode
            }

            settingsRow("应用") {
                if store.audioMode == .selectedApplication {
                    Menu {
                        ForEach(store.applications) { app in
                            Button(app.name) {
                                store.selectedApplicationID = app.id
                            }
                        }
                    } label: {
                        selectionField(selectedApplicationTitle, showsChevron: true)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isRecording)
                } else {
                    selectionField("全局", showsChevron: false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 18, shadowRadius: 16)
    }

    private var codecPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            panelTitle("编码", systemImage: "cpu")

            Picker("视频编码", selection: $store.preferredCodec) {
                ForEach(VideoCodec.allCases) { codec in
                    Text(codec.title).tag(codec)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(height: controlHeight)
            .disabled(store.isRecording)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 18, shadowRadius: 16)
    }

    private var storagePanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            panelTitle("存储", systemImage: "folder")

            HStack(spacing: 12) {
                Text(store.outputURL.lastPathComponent)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 14)
                    .frame(height: controlHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(.white.opacity(0.42))
                    )

                Button {
                    store.chooseOutputFolder()
                } label: {
                    Image(systemName: "folder")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.borderless)
                .disabled(store.isRecording)
                .help("选择保存位置")

                Button {
                    store.openOutputFolder()
                } label: {
                    Image(systemName: "folder.fill")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.borderless)
                .help("打开保存位置")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 18, shadowRadius: 16)
    }

    private var recordBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errorText = store.errorText {
                HStack(spacing: 8) {
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

            HStack {
                HStack(spacing: 10) {
                    Circle()
                        .fill(store.isRecording ? .red : .green)
                        .frame(width: 8, height: 8)

                    Text(store.isRecording ? "录制中" : "就绪")
                        .font(.subheadline.weight(.medium))

                    Text(store.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if store.isMicrophoneEnabled {
                    Text("建议佩戴耳机以避免回声")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var selectedAreaText: String {
        guard let rect = store.selectedAreaRect else {
            return "点击图标拖选录制区域"
        }
        return "已选区域：\(Int(rect.width)) × \(Int(rect.height))"
    }

    private var selectedDisplayTitle: String {
        guard let id = store.selectedDisplayID,
              let display = store.displays.first(where: { $0.id == id }) else {
            return "选择显示器"
        }
        return display.title
    }

    private var selectedApplicationTitle: String {
        guard let id = store.selectedApplicationID,
              let app = store.applications.first(where: { $0.id == id }) else {
            return "选择应用"
        }
        return app.name
    }

    private var segmentedCaptureMode: some View {
        HStack(spacing: 6) {
            pillButton("全屏", isSelected: store.captureMode == .fullScreen) {
                store.captureMode = .fullScreen
            }
            pillButton("区域选择", isSelected: store.captureMode == .area) {
                store.captureMode = .area
                store.startAreaSelection()
            }
        }
        .frame(maxWidth: .infinity)
        .disabled(store.isRecording)
    }

    private var segmentedAudioMode: some View {
        HStack(spacing: 8) {
            pillButton("全局系统声音", systemImage: "waveform", isSelected: store.audioMode == .globalSystem) {
                store.audioMode = .globalSystem
            }
            pillButton("指定应用声音", systemImage: "scope", isSelected: store.audioMode == .selectedApplication) {
                store.audioMode = .selectedApplication
            }
        }
        .frame(maxWidth: .infinity)
        .disabled(store.isRecording)
    }

    private func settingsRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 18) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 94, alignment: .leading)
            content()
        }
        .padding(.horizontal, 22)
        .frame(height: 76)
    }

    private func selectionField(_ title: String, showsChevron: Bool) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            if showsChevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: controlHeight)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.42))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.38), lineWidth: 1)
        )
    }

    private var panelDivider: some View {
        Divider()
            .padding(.leading, 22)
            .opacity(0.45)
    }

    private func panelTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 15, weight: .semibold))
    }

    private func pillButton(_ title: String, systemImage: String? = nil, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(isSelected ? Color(red: 0.18, green: 0.43, blue: 0.92) : .secondary)
            .frame(maxWidth: .infinity)
            .frame(height: controlHeight)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color(red: 0.35, green: 0.58, blue: 0.98).opacity(0.24) : .white.opacity(0.24))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color(red: 0.28, green: 0.55, blue: 0.98).opacity(0.72) : .white.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var appBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.90, green: 0.97, blue: 1.00),
                    Color(red: 0.94, green: 0.97, blue: 1.00),
                    Color(red: 0.98, green: 0.98, blue: 1.00)
                ],
                startPoint: .topTrailing,
                endPoint: .bottomLeading
            )
            RadialGradient(
                colors: [Color.cyan.opacity(0.18), .clear],
                center: .topTrailing,
                startRadius: 120,
                endRadius: 520
            )
            RadialGradient(
                colors: [Color.pink.opacity(0.10), .clear],
                center: .bottomLeading,
                startRadius: 120,
                endRadius: 500
            )
        }
        .ignoresSafeArea()
    }
}

private struct HeroModeButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.18))
                        .frame(width: 64, height: 64)
                        .shadow(color: tint.opacity(0.42), radius: 16, y: 8)
                    Circle()
                        .fill(.white.opacity(0.32))
                        .frame(width: 52, height: 52)
                    Image(systemName: systemImage)
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: tint.opacity(0.7), radius: 8)
                }

                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)

                Circle()
                    .fill(isSelected ? Color(red: 0.10, green: 0.50, blue: 0.95) : .secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
            }
            .frame(width: 82)
        }
        .buttonStyle(.plain)
    }
}

private struct HeroToggleButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    @Binding var isOn: Bool

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.32))
                    .frame(width: 58, height: 58)
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(tint)
                    .shadow(color: tint.opacity(0.28), radius: 8)
            }

            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .scaleEffect(0.72)
                .frame(width: 42, height: 22)
        }
        .frame(width: 74)
    }
}

private extension View {
    func glassCard(cornerRadius: CGFloat, shadowRadius: CGFloat) -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.48), lineWidth: 1)
            )
            .shadow(color: Color(red: 0.30, green: 0.48, blue: 0.70).opacity(0.14), radius: shadowRadius, y: 14)
    }
}
