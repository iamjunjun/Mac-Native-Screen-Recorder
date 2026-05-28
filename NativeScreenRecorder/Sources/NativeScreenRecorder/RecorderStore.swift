import Foundation
import AppKit
import ScreenCaptureKit

@MainActor
final class RecorderStore: ObservableObject {
    @Published var displays: [DisplayOption] = []
    @Published var applications: [ApplicationOption] = []
    @Published var selectedDisplayID: UInt32?
    @Published var selectedApplicationID: pid_t?
    @Published var audioMode: AudioCaptureMode = .globalSystem
    @Published var captureMode: CaptureMode = .fullScreen
    @Published var preferredCodec: VideoCodec = .hevc
    @Published var selectedAreaRect: CGRect? = nil
    @Published var outputURL: URL = RecorderStore.defaultOutputURL()
    @Published var isRecording = false
    @Published var statusText = "准备录制"
    @Published var errorText: String?

    private let captureEngine = CaptureEngine()
    private var recordingAreaOverlay: NSWindow?

    var isPermissionDenied: Bool { errorText?.contains("TCC") == true || errorText?.contains("权限") == true }

    func openScreenRecordingPrefs() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshShareableContent() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            displays = content.displays.map {
                DisplayOption(
                    id: $0.displayID,
                    title: "显示器 \($0.displayID)",
                    width: $0.width,
                    height: $0.height
                )
            }

            applications = content.applications
                .filter { app in
                    app.processID > 0 && app.processID != ProcessInfo.processInfo.processIdentifier
                }
                .map {
                    ApplicationOption(
                        id: $0.processID,
                        name: $0.applicationName.isEmpty ? "未命名应用" : $0.applicationName,
                        bundleIdentifier: $0.bundleIdentifier
                    )
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            // Audio process merging is deferred to mergeAudioProcesses()
            // to avoid CoreAudio assertion failures at startup.

            selectedDisplayID = selectedDisplayID ?? displays.first?.id
            selectedApplicationID = selectedApplicationID ?? applications.first?.id
            statusText = "已刷新可录制内容"
            errorText = nil
        } catch {
            let nsError = error as NSError
            let rawInfo = "[\(nsError.domain) code=\(nsError.code)] \(nsError.localizedDescription)"
            if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" || nsError.code == -3801 ||
               nsError.localizedDescription.contains("not authorized") || nsError.localizedDescription.contains("denied") ||
               nsError.localizedDescription.contains("没有权限") || nsError.localizedDescription.contains("授权") || nsError.localizedDescription.contains("TCC") ||
               nsError.localizedDescription.contains("拒绝") {
                errorText = "屏幕录制权限未授权（TCC 拒绝）。\n请在系统设置 → 隐私与安全性 → 屏幕录制中允许本应用，然后重新打开应用。\n\n调试信息：\(rawInfo)"
            } else {
                errorText = readableError(error)
            }
            statusText = "无法读取可录制内容"
        }
    }

    func mergeAudioProcesses() {
        var allAppOptions = applications
        var seenPIDs = Set(applications.map(\.id))
        let audioProcesses = AudioProcessDiscovery.discoverRunningAudioProcesses()
        for proc in audioProcesses {
            guard !seenPIDs.contains(proc.pid) else { continue }
            seenPIDs.insert(proc.pid)
            allAppOptions.append(ApplicationOption(
                id: proc.pid,
                name: proc.name,
                bundleIdentifier: proc.bundleIdentifier
            ))
        }
        applications = allAppOptions.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"

        if panel.runModal() == .OK, let folder = panel.url {
            outputURL = folder.appendingPathComponent(Self.defaultFileName())
        }
    }

    func openOutputFolder() {
        NSWorkspace.shared.open(outputURL.deletingLastPathComponent())
    }

    func startAreaSelection() {
        guard let displayID = selectedDisplayID else { return }
        let screens = NSScreen.screens
        guard let screen = screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == displayID
        }) else { return }

        let window = AreaSelectionOverlayWindow.create(on: screen)
        guard let overlayView = window.contentView as? AreaSelectionOverlayView else { return }

        NSApp.keyWindow?.miniaturize(nil)

        overlayView.onSelectionComplete = { [weak self, weak window] appKitRect in
            window?.orderOut(nil)
            NSApp.keyWindow?.deminiaturize(nil)
            guard let self else { return }
            let quartzRect = AreaSelectionOverlayView.convertToQuartzSourceRect(
                appKitRect: appKitRect, displayID: displayID
            )
            self.selectedAreaRect = quartzRect
            self.captureMode = .area
            self.statusText = "已选择区域：\(Int(quartzRect.width)) × \(Int(quartzRect.height))"
        }

        overlayView.onCancel = { [weak self, weak window] in
            window?.orderOut(nil)
            NSApp.keyWindow?.deminiaturize(nil)
            self?.captureMode = .fullScreen
            self?.selectedAreaRect = nil
        }
    }

    func startRecording() async {
        guard !isRecording else { return }
        guard let displayID = selectedDisplayID else {
            errorText = "没有可用显示器。请先点刷新。"
            return
        }

        if audioMode == .selectedApplication && selectedApplicationID == nil {
            errorText = "请选择要录制声音的应用。"
            return
        }

        if captureMode == .area && selectedAreaRect == nil {
            errorText = "请先拖选录制区域。"
            return
        }

        do {
            outputURL = outputURL.deletingLastPathComponent().appendingPathComponent(Self.defaultFileName())
            let request = RecordingRequest(
                displayID: displayID,
                audioMode: audioMode,
                applicationProcessID: selectedApplicationID,
                outputURL: outputURL,
                captureMode: captureMode,
                sourceRect: captureMode == .area ? selectedAreaRect : nil,
                preferredCodec: preferredCodec
            )

            try await captureEngine.start(request: request)
            isRecording = true
            statusText = "正在录制到 \(outputURL.lastPathComponent)"
            errorText = nil

            if captureMode == .area, let areaRect = selectedAreaRect, let displayID = selectedDisplayID {
                recordingAreaOverlay = RecordingAreaOverlay.show(sourceRect: areaRect, displayID: displayID)
            }
        } catch {
            errorText = readableError(error)
            statusText = "启动录制失败"
        }
    }

    func stopRecording() async {
        guard isRecording else { return }

        recordingAreaOverlay?.orderOut(nil)
        recordingAreaOverlay = nil

        do {
            try await captureEngine.stop()
            isRecording = false
            statusText = "录制完成：\(outputURL.path)"
            errorText = nil
        } catch {
            isRecording = false
            errorText = readableError(error)
            statusText = "停止录制时出错"
        }
    }

    private static func defaultOutputURL() -> URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(defaultFileName())
    }

    private static func defaultFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return "NativeScreenRecorder-\(formatter.string(from: Date())).mp4"
    }

    private func readableError(_ error: Error) -> String {
        if let captureError = error as? CaptureEngineError {
            return captureError.localizedDescription
        }

        return (error as NSError).localizedDescription
    }
}
