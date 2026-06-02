import AVFoundation
import CoreAudio
import Foundation
import ScreenCaptureKit

enum CaptureEngineError: LocalizedError {
    case noDisplay
    case noApplication
    case alreadyRecording
    case notRecording
    case streamStopped(Error?)
    case processTapUnavailable
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return String.localized("no_display_found")
        case .noApplication:
            return String.localized("app_not_found")
        case .alreadyRecording:
            return String.localized("already_recording")
        case .notRecording:
            return String.localized("not_recording")
        case .streamStopped(let error):
            return error?.localizedDescription ?? String.localized("stream_stopped")
        case .processTapUnavailable:
            return String.localized("process_tap_unavailable")
        case .microphonePermissionDenied:
            return String.localized("mic_permission_denied")
        }
    }
}

final class CaptureEngine: NSObject, @unchecked Sendable {
    private let sampleQueue = DispatchQueue(label: "NativeScreenRecorder.ScreenCaptureSamples")
    private var stream: SCStream?
    private var writer: MovieFileWriter?
    private var processTap: ProcessTapAudioCapture?
    private var isRecording = false
    private var isPaused = false
    private var pauseStartTime: CMTime?
    // Layer 3: Adaptive frame rate — skip frames when screen is static
    private var lastVideoTime: CMTime = .zero
    private var minFrameInterval: Double = 1.0 / 30.0
    private var skippedFrames: Int = 0

    func start(request: RecordingRequest) async throws {
        guard !isRecording else { throw CaptureEngineError.alreadyRecording }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == request.displayID }) ?? content.displays.first else {
            throw CaptureEngineError.noDisplay
        }

        // Build content filter — always capture all windows
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let displayID = display.displayID
        guard let mode = CGDisplayCopyDisplayMode(displayID) else {
            throw CaptureEngineError.noDisplay
        }
        let pixelWidth = mode.pixelWidth
        let pixelHeight = mode.pixelHeight

        // Configure stream
        let configuration = SCStreamConfiguration()
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 3
        configuration.showsCursor = true
        configuration.excludesCurrentProcessAudio = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = false
        if #available(macOS 14.0, *) {
            configuration.captureDynamicRange = SCCaptureDynamicRange(rawValue: 0)!
        }

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

        // Audio mode routing
        let enableMic = request.isMicrophoneEnabled
        let useSCStreamAudio: Bool
        var tapCapture: ProcessTapAudioCapture?

        switch request.audioMode {
        case .none:
            useSCStreamAudio = false
        case .globalSystem:
            useSCStreamAudio = true
        case .selectedApplication:
            guard let pid = request.applicationProcessID,
                  content.applications.first(where: { $0.processID == pid }) != nil else {
                throw CaptureEngineError.noApplication
            }
            let audioPIDs = AudioProcessDiscovery.discoverAudioPIDs(forApplicationPID: pid)
            let pids = audioPIDs.isEmpty ? [pid] : audioPIDs
            let capture = ProcessTapAudioCapture(target: .processes(pids: pids))
            _ = try capture.prepare()
            tapCapture = capture
            useSCStreamAudio = false
        }

        if enableMic {
            let granted = await requestMicrophonePermission()
            guard granted else { throw CaptureEngineError.microphonePermissionDenied }
        }

        // Only enable SCStream audio for globalSystem mode
        if useSCStreamAudio {
            configuration.capturesAudio = true
        }
        if enableMic {
            configuration.captureMicrophone = true
        }

        // Audio formats for MovieFileWriter
        var sysASBD: AudioStreamBasicDescription?
        if useSCStreamAudio || tapCapture != nil {
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

        // Wire up ProcessTap audio → writer
        if let tap = tapCapture {
            tap.onSampleBuffer = { [weak self] sampleBuffer in
                self?.writer?.append(sampleBuffer, to: .systemAudio)
            }
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if useSCStreamAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        if enableMic {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
        }

        self.writer = writer
        self.stream = stream
        self.processTap = tapCapture

        do {
            try await stream.startCapture()
            try tapCapture?.start()
            isRecording = true
        } catch {
            tapCapture?.stop()
            self.writer = nil
            self.stream = nil
            self.processTap = nil
            throw error
        }
    }

    func stop() async throws {
        guard isRecording, let stream else { throw CaptureEngineError.notRecording }

        processTap?.stop()
        processTap = nil

        try await stream.stopCapture()
        self.stream = nil
        isRecording = false
        isPaused = false

        let writer = self.writer
        self.writer = nil
        try await writer?.finish()
    }

    func pause() {
        guard isRecording, !isPaused else { return }
        isPaused = true
        pauseStartTime = CMClockGetTime(CMClockGetHostTimeClock())
        processTap?.pause()
    }

    func resume() {
        guard isRecording, isPaused else { return }
        if let pauseStart = pauseStartTime {
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            let pauseDuration = CMTimeGetSeconds(CMTimeSubtract(now, pauseStart))
            writer?.addPauseDuration(pauseDuration)
        }
        pauseStartTime = nil
        isPaused = false
        processTap?.resume()
    }
}

// MARK: - SCStreamOutput

extension CaptureEngine: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard !isPaused else { return }

        switch outputType {
        case .screen:
            guard sampleBuffer.isCompleteScreenFrame else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            // Layer 3: Adaptive frame rate — skip frames when screen is static
            if lastVideoTime.isValid {
                let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, lastVideoTime))
                if elapsed < minFrameInterval {
                    skippedFrames += 1
                    // Static for 1 second → drop to 15fps
                    if skippedFrames > 30 && minFrameInterval < 1.0 / 15.0 {
                        minFrameInterval = 1.0 / 15.0
                    }
                    return
                }
            }
            // Content is dynamic — restore 30fps immediately
            if skippedFrames > 0 {
                minFrameInterval = 1.0 / 30.0
            }
            skippedFrames = 0
            lastVideoTime = pts
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
        processTap?.stop()
        processTap = nil
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
