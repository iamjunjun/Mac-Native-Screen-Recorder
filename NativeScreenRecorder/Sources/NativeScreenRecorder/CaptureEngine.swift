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
        }
    }
}

final class CaptureEngine: NSObject, @unchecked Sendable {
    private let sampleQueue = DispatchQueue(label: "NativeScreenRecorder.ScreenCaptureSamples")
    private var stream: SCStream?
    private var audioCapture: ProcessTapAudioCapture?
    private var writer: MovieFileWriter?
    private var isRecording = false

    func start(request: RecordingRequest) async throws {
        guard !isRecording else { throw CaptureEngineError.alreadyRecording }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == request.displayID }) ?? content.displays.first else {
            throw CaptureEngineError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let tapTarget: ProcessTapTarget
        switch request.audioMode {
        case .globalSystem:
            tapTarget = .global(excludingCurrentProcess: true)
        case .selectedApplication:
            guard let pid = request.applicationProcessID,
                  let app = content.applications.first(where: { $0.processID == pid }) else {
                throw CaptureEngineError.noApplication
            }
            tapTarget = .process(pid: app.processID)
        }

        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 6
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.excludesCurrentProcessAudio = true

        let audioCapture = ProcessTapAudioCapture(target: tapTarget)
        let audioFormat = try audioCapture.prepare()

        let writer = try MovieFileWriter(
            outputURL: request.outputURL,
            width: display.width,
            height: display.height,
            audioFormat: audioFormat
        )

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)

        self.writer = writer
        self.stream = stream
        self.audioCapture = audioCapture

        audioCapture.onSampleBuffer = { [weak self] sampleBuffer in
            guard let self else { return }
            self.writer?.append(sampleBuffer, mediaType: .audio)
        }

        do {
            try await stream.startCapture()
            try audioCapture.start()
            isRecording = true
        } catch {
            audioCapture.stop()
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
