import AVFoundation
import Foundation
import VideoToolbox

enum AudioTrack {
    case systemAudio
    case microphone
}

final class MovieFileWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var didStartSession = false
    private var didFinish = false

    init(outputURL: URL, width: Int, height: Int,
         systemAudioFormat: AudioStreamBasicDescription? = nil,
         microphoneFormat: AudioStreamBasicDescription? = nil,
         videoCodec: VideoCodec = .hevc) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let pixelCount = width * height
        let (codecType, profileLevel, bitRate): (AVVideoCodecType, String, Int) = {
            switch videoCodec {
            case .h264:
                let bitRate: Int
                if pixelCount <= 1280 * 720       { bitRate =  3_000_000 }
                else if pixelCount <= 1920 * 1080 { bitRate =  6_000_000 }
                else if pixelCount <= 2560 * 1440 { bitRate = 12_000_000 }
                else                              { bitRate = 25_000_000 }
                return (.h264, AVVideoProfileLevelH264HighAutoLevel, bitRate)
            case .hevc:
                let bitRate: Int
                if pixelCount <= 1280 * 720       { bitRate =  2_000_000 }
                else if pixelCount <= 1920 * 1080 { bitRate =  4_000_000 }
                else if pixelCount <= 2560 * 1440 { bitRate =  7_000_000 }
                else                              { bitRate = 15_000_000 }
                return (.hevc, kVTProfileLevel_HEVC_Main_AutoLevel as String, bitRate)
            }
        }()

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoProfileLevelKey: profileLevel,
                AVVideoAllowFrameReorderingKey: true
            ]
        ]

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        // System audio track
        if let fmt = systemAudioFormat {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Int(fmt.mSampleRate),
                AVNumberOfChannelsKey: Int(fmt.mChannelsPerFrame),
                AVEncoderBitRateKey: 192_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) { writer.add(input) }
            systemAudioInput = input
        }

        // Microphone track
        if let fmt = microphoneFormat {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Int(fmt.mSampleRate),
                AVNumberOfChannelsKey: Int(fmt.mChannelsPerFrame),
                AVEncoderBitRateKey: 128_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) { writer.add(input) }
            microphoneInput = input
        }

        if writer.canAdd(videoInput) {
            writer.add(videoInput)
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer, mediaType: AVMediaType) {
        guard !didFinish else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        if !didStartSession {
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
            guard let input = systemAudioInput, input.isReadyForMoreMediaData else { return }
            _ = input.append(sampleBuffer)
        default:
            break
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer, to track: AudioTrack) {
        guard !didFinish else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        if !didStartSession {
            let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: startTime)
            didStartSession = true
        }

        let input: AVAssetWriterInput?
        switch track {
        case .systemAudio:  input = systemAudioInput
        case .microphone:   input = microphoneInput
        }

        guard let input, input.isReadyForMoreMediaData else { return }
        _ = input.append(sampleBuffer)
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { continuation in
            guard !didFinish else {
                continuation.resume()
                return
            }

            didFinish = true
            videoInput.markAsFinished()
            systemAudioInput?.markAsFinished()
            microphoneInput?.markAsFinished()

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
