@preconcurrency import AVFoundation
import CoreMedia
import os

final class AudioMixer: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var systemFormat: AudioStreamBasicDescription?
    private var machTimebase = mach_timebase_info()

    // Copied mic data — AVAudioPCMBuffer is transient (freed after tap callback),
    // so we copy the float samples immediately within the realtime callback.
    // Stored in interleaved layout: [f0ch0, f0ch1, f1ch0, f1ch1, ...]
    private var micData: UnsafeMutablePointer<Float>?
    private var micCapacity = 0
    private var micFrameCount = 0
    private var micChannelCount = 0
    private var micSampleRate: Float64 = 0

    deinit {
        if let p = micData { free(p) }
    }

    func setSystemFormat(_ format: AudioStreamBasicDescription) {
        lock.withLock { systemFormat = format }
    }

    /// Must be called on the realtime audio thread (AVAudioEngine tap callback).
    /// Copies the mic float samples immediately — the buffer is invalid after return.
    func enqueueMic(pcmBuffer: AVAudioPCMBuffer) {
        let frames = Int(pcmBuffer.frameLength)
        let channels = Int(pcmBuffer.format.channelCount)
        let needed = frames * channels

        lock.withLock {
            if needed > micCapacity {
                if let p = micData { free(p) }
                micData = .allocate(capacity: needed)
                micCapacity = needed
            }
            if let dst = micData, let src = pcmBuffer.floatChannelData {
                // Convert planar (non-interleaved) to interleaved
                for ch in 0..<channels {
                    let channelData = src[ch]
                    for f in 0..<frames {
                        dst[f * channels + ch] = channelData[f]
                    }
                }
            }
            micFrameCount = frames
            micChannelCount = channels
            micSampleRate = pcmBuffer.format.sampleRate
        }
    }

    /// Generate a CMSampleBuffer from mic-only audio (system = silence).
    /// Used when system audio is not playing to still capture microphone.
    func makeMicOnlyCMSampleBuffer() -> CMSampleBuffer? {
        // Copy mic data inside lock to prevent use-after-free if enqueueMic
        // reallocates the buffer concurrently on the realtime thread.
        let snapshot: (frames: Int, micCh: Int, data: [Float], outCh: Int, micSR: Float64)?
        snapshot = lock.withLock {
            guard micFrameCount > 0, let fmt = systemFormat, let md = micData else { return nil }
            let count = micFrameCount * micChannelCount
            return (micFrameCount, micChannelCount, Array(UnsafeBufferPointer(start: md, count: count)), Int(fmt.mChannelsPerFrame), micSampleRate)
        }
        guard let (frames, micCh, data, outCh, micSR) = snapshot else { return nil }
        let outCount = frames * outCh
        var samples = [Float](repeating: 0, count: outCount)

        for f in 0..<frames {
            let srcCh = min(0, micCh - 1)
            for ch in 0..<outCh {
                samples[f * outCh + ch] = data[f * micCh + srcCh]
            }
        }

        if machTimebase.denom == 0 { mach_timebase_info(&machTimebase) }
        let now = mach_absolute_time()
        let nanos = now * UInt64(machTimebase.numer) / UInt64(machTimebase.denom)
        let ts = CMTime(value: CMTimeValue(nanos), timescale: 1_000_000_000)

        return makeCMSampleBuffer(
            samples: samples, frames: frames, channels: outCh,
            sampleRate: micSR, timing: ts
        )
    }

    func mix(system sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        // Copy mic data inside lock to prevent use-after-free.
        let snapshot: (frames: Int, channels: Int, data: [Float])?
        snapshot = lock.withLock {
            guard micFrameCount > 0, let md = micData else { return nil }
            let count = micFrameCount * micChannelCount
            return (micFrameCount, micChannelCount, Array(UnsafeBufferPointer(start: md, count: count)))
        }
        guard let (frames, channels, micSamples) = snapshot else { return sampleBuffer }

        guard let sysASBD = asbd(of: sampleBuffer) else { return sampleBuffer }

        let sysFrames = Int(CMSampleBufferGetNumSamples(sampleBuffer))
        let sysCh = Int(sysASBD.mChannelsPerFrame)

        guard var sysSamples = readFloatSamples(sampleBuffer, asbd: sysASBD) else { return sampleBuffer }

        let outFrames = max(sysFrames, frames)
        let outCh = sysCh
        let outCount = outFrames * outCh

        if sysSamples.count < outCount {
            sysSamples.append(contentsOf: [Float](repeating: 0, count: outCount - sysSamples.count))
        }

        // Mix: mic (mono → stereo) + system, with tanh soft clipping
        for f in 0..<min(frames, outFrames) {
            let srcCh = min(0, channels - 1)
            for ch in 0..<outCh {
                let outIdx = f * outCh + ch
                let micSample = micSamples[f * channels + srcCh]
                sysSamples[outIdx] = tanhf(sysSamples[outIdx] + micSample)
            }
        }

        return makeCMSampleBuffer(
            samples: sysSamples,
            frames: outFrames,
            channels: outCh,
            sampleRate: sysASBD.mSampleRate,
            timing: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        ) ?? sampleBuffer
    }

    // MARK: - Helpers

    private func asbd(of sb: CMSampleBuffer) -> AudioStreamBasicDescription? {
        guard let fd = CMSampleBufferGetFormatDescription(sb) else { return nil }
        return CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee
    }

    private func readFloatSamples(_ sb: CMSampleBuffer, asbd: AudioStreamBasicDescription) -> [Float]? {
        let frameCount = Int(CMSampleBufferGetNumSamples(sb))
        let chCount = Int(asbd.mChannelsPerFrame)
        let totalCount = frameCount * chCount
        guard totalCount > 0 else { return nil }

        var sizeNeeded: Int = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: nil
        )

        let abl = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: sizeNeeded)
        defer { abl.deallocate() }

        var bb: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: abl,
            bufferListSize: sizeNeeded, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, blockBufferOut: &bb
        ) == noErr else { return nil }

        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        var result = [Float](repeating: 0, count: totalCount)

        if isNonInterleaved {
            for ch in 0..<chCount {
                let bufPtr = withUnsafePointer(to: &abl.pointee.mBuffers) { base in
                    UnsafeMutableRawPointer(mutating: base)
                        .advanced(by: ch * MemoryLayout<AudioBuffer>.stride)
                        .assumingMemoryBound(to: AudioBuffer.self)
                }
                guard let data = bufPtr.pointee.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for f in 0..<frameCount {
                    result[f * chCount + ch] = data[f]
                }
            }
        } else {
            guard let data = abl.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self) else { return nil }
            for i in 0..<totalCount {
                result[i] = data[i]
            }
        }

        return result
    }

    private func makeCMSampleBuffer(
        samples: [Float], frames: Int, channels: Int, sampleRate: Float64, timing: CMTime
    ) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = sampleRate
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        asbd.mBytesPerPacket = UInt32(channels * MemoryLayout<Float>.size)
        asbd.mFramesPerPacket = 1
        asbd.mBytesPerFrame = UInt32(channels * MemoryLayout<Float>.size)
        asbd.mChannelsPerFrame = UInt32(channels)
        asbd.mBitsPerChannel = 32

        var fd: CMFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &fd
        )
        guard let fd else { return nil }

        let byteCount = samples.count * MemoryLayout<Float>.size
        var bb: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0,
            dataLength: byteCount, flags: 0, blockBufferOut: &bb
        ) == noErr, let bb else { return nil }

        samples.withUnsafeBytes { ptr in
            _ = CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!, blockBuffer: bb,
                offsetIntoDestination: 0, dataLength: byteCount
            )
        }

        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: bb,
            formatDescription: fd, sampleCount: frames,
            presentationTimeStamp: timing, packetDescriptions: nil,
            sampleBufferOut: &sb
        )
        return sb
    }
}
