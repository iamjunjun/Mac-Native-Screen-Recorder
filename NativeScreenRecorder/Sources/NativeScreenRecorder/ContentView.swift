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
                            .frame(height: (panelHeight - 18) / 2)
                        storagePanel
                            .frame(height: (panelHeight - 18) / 2)
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
                Text(verbatim: NSLocalizedString("app_title", bundle: .module, comment: ""))
                    .font(.system(size: 30, weight: .bold))
                Text(verbatim: NSLocalizedString("subtitle", bundle: .module, comment: ""))
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
            .help(Text("refresh_tooltip", bundle: .module))
        }
    }

    private var heroControls: some View {
        ZStack {
            // 背景内容：图标、文字、开关
            VStack(spacing: 16) {
                // 第一行：图标
                HStack(spacing: 0) {
                    HeroIcon(systemImage: "desktopcomputer", tint: .cyan, size: 64)
                        .frame(maxWidth: .infinity)

                    HeroIcon(systemImage: "crop", tint: .purple, size: 64)
                        .frame(maxWidth: .infinity)

                    // 中间留空给录制按钮
                    Spacer().frame(maxWidth: .infinity)

                    HeroIcon(systemImage: "mic", tint: .gray, size: 58)
                        .frame(maxWidth: .infinity)

                    HeroIcon(systemImage: "video.fill", tint: .orange, size: 58)
                        .frame(maxWidth: .infinity)
                }

                // 第二行：文字
                HStack(spacing: 0) {
                    Text(String.localized("full_screen"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)

                    Text(String.localized("custom_area"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)

                    Spacer().frame(maxWidth: .infinity)

                    Text(String.localized("microphone"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)

                    Text(String.localized("system_audio"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }

                // 第三行：状态指示和开关
                HStack(spacing: 0) {
                    Circle()
                        .fill(store.captureMode == .fullScreen ? Color(red: 0.10, green: 0.50, blue: 0.95) : .secondary.opacity(0.35))
                        .frame(width: 7, height: 7)
                        .frame(maxWidth: .infinity)

                    Circle()
                        .fill(store.captureMode == .area ? Color(red: 0.10, green: 0.50, blue: 0.95) : .secondary.opacity(0.35))
                        .frame(width: 7, height: 7)
                        .frame(maxWidth: .infinity)

                    Spacer().frame(maxWidth: .infinity)

                    Toggle("", isOn: Binding(
                        get: { store.isMicrophoneEnabled },
                        set: { _ in store.toggleMicrophone() }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .scaleEffect(0.72)
                    .frame(width: 42, height: 22)
                    .frame(maxWidth: .infinity)

                    Toggle("", isOn: Binding(
                        get: { store.audioMode != .none },
                        set: { isOn in
                            store.audioMode = isOn ? .globalSystem : .none
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .scaleEffect(0.72)
                    .frame(width: 42, height: 22)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 22)

            // 录制按钮（居中覆盖）
            Button {
                Task {
                    if store.isRecording {
                        await store.stopRecording()
                    } else {
                        await store.startRecording()
                    }
                }
            } label: {
                ZStack {
                    // Outer white ring — fades out when recording
                    Circle()
                        .fill(.white.opacity(0.55))
                        .frame(width: 112, height: 112)
                        .shadow(color: .red.opacity(0.28), radius: 34, y: 14)
                        .opacity(store.isRecording ? 0 : 1)
                        .animation(.easeInOut(duration: 0.3), value: store.isRecording)

                    Circle()
                        .stroke(.white.opacity(0.75), lineWidth: 1)
                        .frame(width: 112, height: 112)
                        .opacity(store.isRecording ? 0 : 1)
                        .animation(.easeInOut(duration: 0.3), value: store.isRecording)

                    // Inner red shape — morphs from circle to capsule, always centered
                    RedRecordShape(isRecording: store.isRecording)
                        .shadow(color: .red.opacity(0.42), radius: 16, y: 8)

                    // Elapsed time overlay
                    if store.isRecording {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(.white)
                                .frame(width: 8, height: 8)
                            Text(store.formattedElapsedTime)
                                .font(.system(size: 18, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white)
                        }
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.3), value: store.isRecording)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: 18, shadowRadius: 26)
    }

    private var capturePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingsRow(String.localized("capture_mode")) {
                segmentedCaptureMode
            }

            panelDivider

            if store.captureMode == .area {
                settingsRow(String.localized("select_area")) {
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
                settingsRow(String.localized("display")) {
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

            settingsRow(String.localized("audio_source")) {
                segmentedAudioMode
            }

            settingsRow(String.localized("application")) {
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
                    selectionField(String.localized("global"), showsChevron: false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 18, shadowRadius: 16)
    }

    private var codecPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            panelTitle(String.localized("encoding"), systemImage: "cpu")

            HStack(spacing: 6) {
                ForEach(VideoCodec.allCases) { codec in
                    pillButton(codec.title, isSelected: store.preferredCodec == codec) {
                        store.preferredCodec = codec
                    }
                }
            }
            .frame(height: controlHeight)
            .disabled(store.isRecording)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 18, shadowRadius: 16)
    }

    private var storagePanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            panelTitle(String.localized("storage"), systemImage: "folder")

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
                .help(Text("choose_save_location", bundle: .module))

                Button {
                    store.openOutputFolder()
                } label: {
                    Image(systemName: "folder.fill")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.borderless)
                .help(Text("open_save_location", bundle: .module))
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
                        Button(String.localized("open_system_settings")) {
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

                    Text(store.isRecording ? "recording" : "ready", bundle: .module)
                        .font(.subheadline.weight(.medium))

                    Text(store.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if let micWarning = store.micWarningText {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.slash.fill")
                            .foregroundStyle(.orange)
                        Text(micWarning)
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var selectedAreaText: String {
        guard let rect = store.selectedAreaRect else {
            return String.localized("click_to_select_area")
        }
        return String.localized("selected_area \(Int(rect.width)) \(Int(rect.height))")
    }

    private var selectedDisplayTitle: String {
        guard let id = store.selectedDisplayID,
              let display = store.displays.first(where: { $0.id == id }) else {
            return String.localized("select_display")
        }
        return display.title
    }

    private var selectedApplicationTitle: String {
        guard let id = store.selectedApplicationID,
              let app = store.applications.first(where: { $0.id == id }) else {
            return String.localized("select_application")
        }
        return app.name
    }

    private var segmentedCaptureMode: some View {
        HStack(spacing: 6) {
            pillButton(String.localized("full_screen"), systemImage: "desktopcomputer", isSelected: store.captureMode == .fullScreen) {
                store.captureMode = .fullScreen
            }
            pillButton(String.localized("area_select"), systemImage: "crop", isSelected: store.captureMode == .area) {
                store.captureMode = .area
                store.startAreaSelection()
            }
        }
        .frame(maxWidth: .infinity)
        .disabled(store.isRecording)
    }

    private var segmentedAudioMode: some View {
        HStack(spacing: 8) {
            pillButton(String.localized("global_system_audio"), systemImage: "waveform", isSelected: store.audioMode == .globalSystem) {
                store.audioMode = .globalSystem
            }
            pillButton(String.localized("app_audio"), systemImage: "scope", isSelected: store.audioMode == .selectedApplication) {
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

private struct HeroIcon: View {
    let systemImage: String
    let tint: Color
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.18))
                .frame(width: size, height: size)
                .shadow(color: tint.opacity(0.42), radius: 16, y: 8)
            Circle()
                .fill(.white.opacity(0.32))
                .frame(width: size * 0.82, height: size * 0.82)
            Image(systemName: systemImage)
                .font(.system(size: size * 0.39, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: tint.opacity(0.7), radius: 8)
        }
    }
}

private struct HeroModeButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let isSelected: Bool
    let width: CGFloat
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Circle()
                    .fill(isSelected ? Color(red: 0.10, green: 0.50, blue: 0.95) : .secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
            }
            .frame(width: width)
        }
        .buttonStyle(.plain)
    }
}

private struct HeroToggleButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    @Binding var isOn: Bool
    let width: CGFloat

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
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .scaleEffect(0.72)
                .frame(width: 42, height: 22)
        }
        .frame(width: width)
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

/// Red recording button shape that morphs from circle to capsule, expanding from center.
private struct RedRecordShape: View {
    let isRecording: Bool

    private var shapeWidth: CGFloat { isRecording ? 180 : 82 }
    private var shapeHeight: CGFloat { isRecording ? 56 : 82 }
    private var cornerRadius: CGFloat { isRecording ? 28 : 41 }

    var body: some View {
        GeometryReader { geo in
            let containerCenter = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let originX = containerCenter.x - shapeWidth / 2
            let originY = containerCenter.y - shapeHeight / 2

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    isRecording
                        ? AnyShapeStyle(Color.red)
                        : AnyShapeStyle(
                            RadialGradient(
                                colors: [Color.red.opacity(0.82), Color.red.opacity(0.42), Color.white.opacity(0.22)],
                                center: .center,
                                startRadius: 8,
                                endRadius: 41
                            )
                        )
                )
                .frame(width: shapeWidth, height: shapeHeight)
                .offset(x: originX, y: originY)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.white.opacity(isRecording ? 0.75 : 0), lineWidth: 1)
                        .frame(width: shapeWidth, height: shapeHeight)
                        .offset(x: originX, y: originY)
                )
        }
        .animation(.easeInOut(duration: 0.35), value: isRecording)
    }
}
