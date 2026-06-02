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
    private var pixelTransferSession: VTPixelTransferSession?
    private var outputBufferPool: CVPixelBufferPool?
    private var cachedFormatDescription: CMVideoFormatDescription?
    private var accumulatedPauseDuration: Double = 0

    init(outputURL: URL, width: Int, height: Int,
         systemAudioFormat: AudioStreamBasicDescription? = nil,
         microphoneFormat: AudioStreamBasicDescription? = nil,
         videoCodec: VideoCodec = .hevc) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let (codecType, profileLevel): (AVVideoCodecType, String) = {
            switch videoCodec {
            case .h264:
                return (.h264, AVVideoProfileLevelH264HighAutoLevel)
            case .hevc:
                return (.hevc, kVTProfileLevel_HEVC_Main_AutoLevel as String)
            }
        }()

        // Layer 1: Constant Quality (CQ) mode
        let compressionProps: [String: Any] = [
            AVVideoMaxKeyFrameIntervalKey: 60,
            AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
            AVVideoProfileLevelKey: profileLevel,
            AVVideoAllowFrameReorderingKey: false,
            AVVideoQualityKey: 0.85
        ]

        // Output: Rec.709 color space, full range
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoPixelAspectRatioKey: [
                AVVideoPixelAspectRatioHorizontalSpacingKey: 1,
                AVVideoPixelAspectRatioVerticalSpacingKey: 1
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: compressionProps
        ]

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        // Color calibration: Display P3 BGRA → Rec.709 BGRA (GPU-accelerated, IOSurface-backed)
        var session: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
        if status == noErr, let session {
            VTSessionSetProperty(session, key: "EnableGPUAcceleratedTransfer" as CFString, value: kCFBooleanTrue)
            VTSessionSetProperty(session, key: "DestinationColorPrimaries" as CFString, value: AVVideoColorPrimaries_ITU_R_709_2 as CFTypeRef)
            VTSessionSetProperty(session, key: "DestinationTransferFunction" as CFString, value: AVVideoTransferFunction_ITU_R_709_2 as CFTypeRef)
            VTSessionSetProperty(session, key: "DestinationYCbCrMatrix" as CFString, value: AVVideoYCbCrMatrix_ITU_R_709_2 as CFTypeRef)
            self.pixelTransferSession = session
        }

        // IOSurface-backed pool — zero-copy between GPU transfer and hardware encoder
        var pool: CVPixelBufferPool?
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, poolAttrs as CFDictionary, &pool)
        self.outputBufferPool = pool

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

    func addPauseDuration(_ duration: Double) {
        accumulatedPauseDuration += duration
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

        // Apply pause time offset
        let adjustedBuffer = applyPauseOffset(to: sampleBuffer)

        switch mediaType {
        case .video:
            guard videoInput.isReadyForMoreMediaData else { return }
            if let session = pixelTransferSession,
               let pool = outputBufferPool,
               let inputPixelBuffer = CMSampleBufferGetImageBuffer(adjustedBuffer) {
                var outputPixelBuffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputPixelBuffer)
                if let output = outputPixelBuffer {
                    // GPU: Display P3 → Rec.709, stays in IOSurface (zero-copy)
                    VTPixelTransferSessionTransferImage(session, from: inputPixelBuffer, to: output)
                    if cachedFormatDescription == nil {
                        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: output, formatDescriptionOut: &cachedFormatDescription)
                    }
                    if let desc = cachedFormatDescription {
                        var timing = CMSampleTimingInfo(
                            duration: CMSampleBufferGetDuration(adjustedBuffer),
                            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(adjustedBuffer),
                            decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(adjustedBuffer)
                        )
                        var converted: CMSampleBuffer?
                        CMSampleBufferCreateReadyWithImageBuffer(
                            allocator: kCFAllocatorDefault,
                            imageBuffer: output,
                            formatDescription: desc,
                            sampleTiming: &timing,
                            sampleBufferOut: &converted
                        )
                        if let converted {
                            _ = videoInput.append(converted)
                            return
                        }
                    }
                }
            }
            _ = videoInput.append(adjustedBuffer)
        case .audio:
            guard let input = systemAudioInput, input.isReadyForMoreMediaData else { return }
            _ = input.append(adjustedBuffer)
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

        // Apply pause time offset
        let adjustedBuffer = applyPauseOffset(to: sampleBuffer)

        let input: AVAssetWriterInput?
        switch track {
        case .systemAudio:  input = systemAudioInput
        case .microphone:   input = microphoneInput
        }

        guard let input, input.isReadyForMoreMediaData else { return }
        _ = input.append(adjustedBuffer)
    }

    private func applyPauseOffset(to sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        guard accumulatedPauseDuration > 0 else { return sampleBuffer }

        let offset = CMTime(seconds: accumulatedPauseDuration, preferredTimescale: 1_000_000_000)
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), offset),
            decodeTimeStamp: CMTimeSubtract(CMSampleBufferGetDecodeTimeStamp(sampleBuffer), offset)
        )

        var adjusted: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &adjusted
        )

        return adjusted ?? sampleBuffer
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
