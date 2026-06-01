import AVFoundation
import Foundation
import ScreenCaptureKit

enum CaptureEngineError: LocalizedError {
    case noDisplay
    case noApplication
    case alreadyRecording
    case notRecording
    case streamStopped(Error?)
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "找不到要录制的显示器。"
        case .noApplication:
            return "找不到要录制的应用，它可能已经退出或没有可捕获窗口。"
        case .alreadyRecording:
            return "当前已经在录制。"
        case .notRecording:
            return "当前没有正在进行的录制。"
        case .streamStopped(let error):
            return error?.localizedDescription ?? "录制流已停止。"
        case .microphonePermissionDenied:
            return "麦克风权限未授权，请在系统设置 → 隐私与安全性 → 麦克风中允许本应用。"
        }
    }
}

final class CaptureEngine: NSObject, @unchecked Sendable {
    private let sampleQueue = DispatchQueue(label: "NativeScreenRecorder.ScreenCaptureSamples")
    private var stream: SCStream?
    private var writer: MovieFileWriter?
    private var isRecording = false

    func start(request: RecordingRequest) async throws {
        guard !isRecording else { throw CaptureEngineError.alreadyRecording }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == request.displayID }) ?? content.displays.first else {
            throw CaptureEngineError.noDisplay
        }

        // Build content filter
        let filter: SCContentFilter
        switch request.audioMode {
        case .none, .globalSystem:
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        case .selectedApplication:
            guard let pid = request.applicationProcessID,
                  let app = content.applications.first(where: { $0.processID == pid }) else {
                throw CaptureEngineError.noApplication
            }
            filter = SCContentFilter(display: display, excludingApplications: [app], exceptingWindows: [])
        }

        let displayID = display.displayID
        guard let mode = CGDisplayCopyDisplayMode(displayID) else {
            throw CaptureEngineError.noDisplay
        }
        let pixelWidth = mode.pixelWidth
        let pixelHeight = mode.pixelHeight

        // Configure stream
        let configuration = SCStreamConfiguration()
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 6
        configuration.showsCursor = true
        configuration.excludesCurrentProcessAudio = true
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.scalesToFit = false

        let pointScale = CGFloat(pixelWidth) / CGFloat(display.width)
        let writerWidth: Int
        let writerHeight: Int
        if request.captureMode == .area, let sourceRect = request.sourceRect {
            writerWidth = Int(sourceRect.width * pointScale)
            writerHeight = Int(sourceRect.height * pointScale)
            configuration.sourceRect = sourceRect
            configuration.width = writerWidth
            configuration.height = writerHeight
        } else {
            writerWidth = pixelWidth
            writerHeight = pixelHeight
            configuration.width = pixelWidth
            configuration.height = pixelHeight
        }

        // Audio setup
        let enableSystemAudio = request.audioMode != .none
        let enableMic = request.isMicrophoneEnabled

        if enableMic {
            let granted = await requestMicrophonePermission()
            guard granted else { throw CaptureEngineError.microphonePermissionDenied }
        }

        if enableSystemAudio {
            configuration.capturesAudio = true
        }
        if enableMic {
            configuration.captureMicrophone = true
        }

        // Audio formats for MovieFileWriter
        var sysASBD: AudioStreamBasicDescription?
        if enableSystemAudio {
            var asbd = AudioStreamBasicDescription()
            asbd.mSampleRate = 48000
            asbd.mFormatID = kAudioFormatLinearPCM
            asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
            asbd.mBytesPerPacket = 8
            asbd.mFramesPerPacket = 1
            asbd.mBytesPerFrame = 8
            asbd.mChannelsPerFrame = 2
            asbd.mBitsPerChannel = 32
            sysASBD = asbd
        }

        var micASBD: AudioStreamBasicDescription?
        if enableMic {
            // SCStream mic uses device native format (typically 48kHz mono)
            var asbd = AudioStreamBasicDescription()
            asbd.mSampleRate = 48000
            asbd.mFormatID = kAudioFormatLinearPCM
            asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
            asbd.mBytesPerPacket = 4
            asbd.mFramesPerPacket = 1
            asbd.mBytesPerFrame = 4
            asbd.mChannelsPerFrame = 1
            asbd.mBitsPerChannel = 32
            micASBD = asbd
        }

        let writer = try MovieFileWriter(
            outputURL: request.outputURL,
            width: writerWidth, height: writerHeight,
            systemAudioFormat: sysASBD,
            microphoneFormat: micASBD,
            videoCodec: request.preferredCodec
        )

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if enableSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        if enableMic {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
        }

        self.writer = writer
        self.stream = stream

        do {
            try await stream.startCapture()
            isRecording = true
        } catch {
            self.writer = nil
            self.stream = nil
            throw error
        }
    }

    func stop() async throws {
        guard isRecording, let stream else { throw CaptureEngineError.notRecording }

        try await stream.stopCapture()
        self.stream = nil
        isRecording = false

        let writer = self.writer
        self.writer = nil
        try await writer?.finish()
    }
}

// MARK: - SCStreamOutput

extension CaptureEngine: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        switch outputType {
        case .screen:
            guard sampleBuffer.isCompleteScreenFrame else { return }
            writer?.append(sampleBuffer, mediaType: .video)
        case .audio:
            writer?.append(sampleBuffer, to: .systemAudio)
        case .microphone:
            writer?.append(sampleBuffer, to: .microphone)
        @unknown default:
            break
        }
    }
}

// MARK: - SCStreamDelegate

extension CaptureEngine: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isRecording = false
        self.stream = nil
    }
}

// MARK: - Helpers

extension CaptureEngine {
    private func requestMicrophonePermission() async -> Bool {
        if #available(macOS 14.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        }
        return true
    }
}

private extension CMSampleBuffer {
    var isCompleteScreenFrame: Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRawValue = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue) else {
            return true
        }

        return status == .complete
    }
}
