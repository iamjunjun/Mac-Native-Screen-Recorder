import Foundation
import AppKit
import ScreenCaptureKit
import CoreAudio

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
    @Published var isPaused = false
    @Published var isMicrophoneEnabled = false
    @Published var statusText = String.localized("ready_to_record")
    @Published var errorText: String?
    @Published var elapsedTime: TimeInterval = 0
    @Published var micWarningText: String?

    private let captureEngine = CaptureEngine()
    private var recordingAreaOverlay: NSWindow?
    private var recordingStartTime: Date?
    private var timerTask: Task<Void, Never>?
    private var pauseStartTime: Date?
    private var totalPausedDuration: TimeInterval = 0

    var isPermissionDenied: Bool {
        errorText?.contains("TCC") == true || errorText?.contains("权限") == true
        || errorText?.contains("permission") == true || errorText?.contains("denied") == true
    }

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
                    title: String.localized("display_title \($0.displayID)"),
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
                        name: $0.applicationName.isEmpty ? String.localized("unnamed_app") : $0.applicationName,
                        bundleIdentifier: $0.bundleIdentifier
                    )
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            // Audio process merging is deferred to mergeAudioProcesses()
            // to avoid CoreAudio assertion failures at startup.

            selectedDisplayID = selectedDisplayID ?? displays.first?.id
            selectedApplicationID = selectedApplicationID ?? applications.first?.id
            statusText = String.localized("content_refreshed")
            errorText = nil
        } catch {
            let nsError = error as NSError
            let rawInfo = "[\(nsError.domain) code=\(nsError.code)] \(nsError.localizedDescription)"
            if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" || nsError.code == -3801 ||
               nsError.localizedDescription.contains("not authorized") || nsError.localizedDescription.contains("denied") ||
               nsError.localizedDescription.contains("没有权限") || nsError.localizedDescription.contains("授权") || nsError.localizedDescription.contains("TCC") ||
               nsError.localizedDescription.contains("拒绝") {
                errorText = String(localized: "screen_recording_denied \(rawInfo)", bundle: .module)
            } else {
                errorText = readableError(error)
            }
            statusText = String.localized("failed_to_read_content")
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

    func checkMicrophoneHardware() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceID
        )

        if status != noErr || deviceID == kAudioObjectUnknown {
            micWarningText = String.localized("no_microphone_hardware")
            isMicrophoneEnabled = false
            return
        }

        // 检查设备名称，确认不是虚拟设备
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let nameStatus = AudioObjectGetPropertyData(
            deviceID,
            &nameAddress,
            0, nil,
            &nameSize,
            &name
        )

        if nameStatus == noErr, let cfName = name?.takeRetainedValue() {
            let deviceName = cfName as String
            // 检查是否是有效的输入设备
            if deviceName.isEmpty {
                micWarningText = String.localized("no_microphone_hardware")
                isMicrophoneEnabled = false
                return
            }
        }

        micWarningText = nil
    }

    func toggleMicrophone() {
        if isMicrophoneEnabled {
            isMicrophoneEnabled = false
            micWarningText = nil
        } else {
            checkMicrophoneHardware()
            if micWarningText == nil {
                isMicrophoneEnabled = true
            }
        }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String.localized("select")

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
            self.statusText = String.localized("area_selected \(Int(quartzRect.width)) \(Int(quartzRect.height))")
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
            errorText = String.localized("no_display_error")
            return
        }

        if audioMode == .selectedApplication && selectedApplicationID == nil {
            errorText = String.localized("select_app_for_audio")
            return
        }

        if captureMode == .area && selectedAreaRect == nil {
            errorText = String.localized("select_area_first")
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
                preferredCodec: preferredCodec,
                isMicrophoneEnabled: isMicrophoneEnabled
            )

            try await captureEngine.start(request: request)
            isRecording = true
            isPaused = false
            elapsedTime = 0
            totalPausedDuration = 0
            pauseStartTime = nil
            recordingStartTime = Date()
            startTimer()
            statusText = String.localized("recording_to \(outputURL.lastPathComponent)")
            errorText = nil

            if captureMode == .area, let areaRect = selectedAreaRect, let displayID = selectedDisplayID {
                recordingAreaOverlay = RecordingAreaOverlay.show(sourceRect: areaRect, displayID: displayID)
            }
        } catch {
            errorText = readableError(error)
            statusText = String.localized("failed_to_start")
        }
    }

    func stopRecording() async {
        guard isRecording else { return }

        recordingAreaOverlay?.orderOut(nil)
        recordingAreaOverlay = nil

        do {
            try await captureEngine.stop()
            isRecording = false
            isPaused = false
            stopTimer()
            statusText = String.localized("recording_saved \(outputURL.path)")
            errorText = nil
        } catch {
            isRecording = false
            isPaused = false
            stopTimer()
            errorText = readableError(error)
            statusText = String.localized("error_stopping")
        }
    }

    func pauseRecording() {
        guard isRecording, !isPaused else { return }
        isPaused = true
        pauseStartTime = Date()
        captureEngine.pause()
        statusText = String.localized("recording_paused")
    }

    func resumeRecording() {
        guard isRecording, isPaused else { return }
        if let pauseStart = pauseStartTime {
            totalPausedDuration += Date().timeIntervalSince(pauseStart)
        }
        pauseStartTime = nil
        isPaused = false
        captureEngine.resume()
        statusText = String.localized("recording_to \(outputURL.lastPathComponent)")
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

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                guard let self, let start = self.recordingStartTime else { break }
                await MainActor.run {
                    if !self.isPaused {
                        self.elapsedTime = Date().timeIntervalSince(start) - self.totalPausedDuration
                    }
                }
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
        recordingStartTime = nil
    }

    var formattedElapsedTime: String {
        let total = Int(elapsedTime)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    private func readableError(_ error: Error) -> String {
        if let captureError = error as? CaptureEngineError {
            return captureError.localizedDescription
        }

        return (error as NSError).localizedDescription
    }
}
