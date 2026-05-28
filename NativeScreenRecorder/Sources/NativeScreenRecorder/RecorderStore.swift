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
    @Published var outputURL: URL = RecorderStore.defaultOutputURL()
    @Published var isRecording = false
    @Published var statusText = "准备录制"
    @Published var errorText: String?

    private let captureEngine = CaptureEngine()

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

        do {
            outputURL = outputURL.deletingLastPathComponent().appendingPathComponent(Self.defaultFileName())
            let request = RecordingRequest(
                displayID: displayID,
                audioMode: audioMode,
                applicationProcessID: selectedApplicationID,
                outputURL: outputURL
            )

            try await captureEngine.start(request: request)
            isRecording = true
            statusText = "正在录制到 \(outputURL.lastPathComponent)"
            errorText = nil
        } catch {
            errorText = readableError(error)
            statusText = "启动录制失败"
        }
    }

    func stopRecording() async {
        guard isRecording else { return }

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
