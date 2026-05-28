import AVFoundation
import Foundation

final class MovieFileWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private var didStartSession = false
    private var didFinish = false

    init(outputURL: URL, width: Int, height: Int, audioFormat: AudioStreamBasicDescription) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(width * height * 4, 6_000_000),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Int(audioFormat.mSampleRate),
            AVNumberOfChannelsKey: Int(audioFormat.mChannelsPerFrame),
            AVEncoderBitRateKey: 192_000
        ]

        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true

        if writer.canAdd(videoInput) {
            writer.add(videoInput)
        }

        if writer.canAdd(audioInput) {
            writer.add(audioInput)
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer, mediaType: AVMediaType) {
        guard !didFinish else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        if !didStartSession {
            guard mediaType == .video else { return }
            let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: startTime)
            didStartSession = true
        }

        switch mediaType {
        case .video:
            guard videoInput.isReadyForMoreMediaData else { return }
            _ = videoInput.append(sampleBuffer)
        case .audio:
            guard audioInput.isReadyForMoreMediaData else { return }
            _ = audioInput.append(sampleBuffer)
        default:
            break
        }
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { continuation in
            guard !didFinish else {
                continuation.resume()
                return
            }

            didFinish = true
            videoInput.markAsFinished()
            audioInput.markAsFinished()

            guard didStartSession else {
                writer.cancelWriting()
                continuation.resume()
                return
            }

            writer.finishWriting {
                if let error = self.writer.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
