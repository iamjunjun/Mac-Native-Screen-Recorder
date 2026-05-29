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
            return "找不到要录制的显示器。"
        case .noApplication:
            return "找不到要录制的应用，它可能已经退出或没有可捕获窗口。"
        case .alreadyRecording:
            return "当前已经在录制。"
        case .notRecording:
            return "当前没有正在进行的录制。"
        case .streamStopped(let error):
            return error?.localizedDescription ?? "录制流已停止。"
        case .processTapUnavailable:
            return "Core Audio Process Tap 需要 macOS 14.2 或更新版本。"
        case .microphonePermissionDenied:
            return "麦克风权限未授权，请在系统设置 → 隐私与安全性 → 麦克风中允许本应用。"
        }
    }
}

final class CaptureEngine: NSObject, @unchecked Sendable {
    private let sampleQueue = DispatchQueue(label: "NativeScreenRecorder.ScreenCaptureSamples")
    private var stream: SCStream?
    private var audioCapture: ProcessTapAudioCapture?
    private var audioMixer: AudioMixer?
    private var micEngine: AVAudioEngine?
    private var writer: MovieFileWriter?
    private var isRecording = false
    private var lastSystemAudioTime: CMTime = .zero
    private var machTimebase = mach_timebase_info()

    func start(request: RecordingRequest) async throws {
        guard !isRecording else { throw CaptureEngineError.alreadyRecording }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == request.displayID }) ?? content.displays.first else {
            throw CaptureEngineError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let tapTarget: ProcessTapTarget?
        switch request.audioMode {
        case .none:
            tapTarget = nil
        case .globalSystem:
            tapTarget = .global(excludingCurrentProcess: true)
        case .selectedApplication:
            guard let pid = request.applicationProcessID else {
                throw CaptureEngineError.noApplication
            }
            let audioPIDs = AudioProcessDiscovery.discoverAudioPIDs(forApplicationPID: pid)
            let pids = audioPIDs.isEmpty ? [pid] : audioPIDs
            tapTarget = .processes(pids: pids)
        }

        let displayID = display.displayID
        guard let mode = CGDisplayCopyDisplayMode(displayID) else {
            throw CaptureEngineError.noDisplay
        }
        let pixelWidth = mode.pixelWidth
        let pixelHeight = mode.pixelHeight

        let configuration = SCStreamConfiguration()
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 6
        configuration.showsCursor = true
        configuration.capturesAudio = false
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

        var audioFormat: AudioStreamBasicDescription?
        var audioCapture: ProcessTapAudioCapture?
        let mixer = AudioMixer()

        if request.audioMode != .none, let target = tapTarget {
            let capture = ProcessTapAudioCapture(target: target)
            audioFormat = try capture.prepare()
            audioCapture = capture
        }

        if request.isMicrophoneEnabled {
            let micGranted = await requestMicrophonePermission()
            guard micGranted else {
                throw CaptureEngineError.microphonePermissionDenied
            }
            try startMicrophoneCapture(mixer: mixer, audioFormat: audioFormat)
        }

        let writer = try MovieFileWriter(
            outputURL: request.outputURL,
            width: writerWidth,
            height: writerHeight,
            audioFormat: audioFormat,
            videoCodec: request.preferredCodec
        )

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)

        self.writer = writer
        self.stream = stream
        self.audioCapture = audioCapture
        self.audioMixer = request.isMicrophoneEnabled ? mixer : nil

        if let capture = audioCapture {
            capture.onSampleBuffer = { [weak self] sampleBuffer in
                guard let self else { return }
                self.lastSystemAudioTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let output = self.audioMixer?.mix(system: sampleBuffer) ?? sampleBuffer
                self.writer?.append(output, mediaType: .audio)
            }
        }

        do {
            try await stream.startCapture()
            try audioCapture?.start()
            isRecording = true
        } catch {
            audioCapture?.stop()
            self.writer = nil
            self.stream = nil
            self.audioCapture = nil
            throw error
        }
    }

    func stop() async throws {
        guard isRecording, let stream else { throw CaptureEngineError.notRecording }

        audioCapture?.stop()
        audioCapture = nil
        audioMixer = nil
        micEngine?.stop()
        micEngine = nil
        try await stream.stopCapture()
        self.stream = nil
        isRecording = false

        let writer = self.writer
        self.writer = nil
        try await writer?.finish()
    }
}

extension CaptureEngine: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        switch outputType {
        case .screen:
            guard sampleBuffer.isCompleteScreenFrame else { return }
            writer?.append(sampleBuffer, mediaType: .video)
        case .audio:
            break
        case .microphone:
            break
        @unknown default:
            break
        }
    }
}

extension CaptureEngine: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isRecording = false
        self.stream = nil
    }
}

// MARK: - Microphone via AVAudioEngine

extension CaptureEngine {
    private func requestMicrophonePermission() async -> Bool {
        if #available(macOS 14.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        }
        return true
    }

    private func isSystemAudioActive() -> Bool {
        if machTimebase.denom == 0 { mach_timebase_info(&machTimebase) }
        let now = mach_absolute_time()
        let nowNanos = now * UInt64(machTimebase.numer) / UInt64(machTimebase.denom)
        let lastSecs = CMTimeGetSeconds(lastSystemAudioTime)
        if lastSecs.isNaN || lastSecs <= 0 { return false }
        let lastNanos = UInt64(lastSecs * 1_000_000_000)
        let elapsed = nowNanos > lastNanos ? nowNanos - lastNanos : 0
        return elapsed < 200_000_000  // within 200ms
    }

    private func startMicrophoneCapture(mixer: AudioMixer, audioFormat: AudioStreamBasicDescription?) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Use mic native format; AudioMixer handles mono→stereo expansion
        let micFormat = inputNode.outputFormat(forBus: 0)

        // Build an ASBD from micFormat so AudioMixer can fall back to it in mic-only mode
        var micASBD = AudioStreamBasicDescription()
        micASBD.mSampleRate = micFormat.sampleRate
        micASBD.mFormatID = kAudioFormatLinearPCM
        micASBD.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        micASBD.mBytesPerPacket = UInt32(Int(micFormat.channelCount) * MemoryLayout<Float>.size)
        micASBD.mFramesPerPacket = 1
        micASBD.mBytesPerFrame = UInt32(Int(micFormat.channelCount) * MemoryLayout<Float>.size)
        micASBD.mChannelsPerFrame = UInt32(micFormat.channelCount)
        micASBD.mBitsPerChannel = 32
        mixer.setMicFormat(micASBD)

        // Also set system format when available (for mixed mode)
        if let fmt = audioFormat {
            mixer.setSystemFormat(fmt)
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: micFormat) { [weak self] micBuffer, audioTime in
            guard let self else { return }
            mixer.enqueueMic(pcmBuffer: micBuffer, hostTime: audioTime.hostTime)

            // Dispatch off the realtime audio thread — CMSampleBuffer creation
            // and AVAssetWriter append must not happen on a realtime thread.
            self.sampleQueue.async { [weak self] in
                guard let self else { return }
                if !self.isSystemAudioActive() {
                    if let micSB = mixer.makeMicOnlyCMSampleBuffer() {
                        self.writer?.append(micSB, mediaType: .audio)
                    }
                }
            }
        }

        try engine.start()
        micEngine = engine
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
