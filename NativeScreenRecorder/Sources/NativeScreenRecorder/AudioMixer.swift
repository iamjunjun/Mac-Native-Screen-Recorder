@preconcurrency import AVFoundation
import CoreMedia
import os

final class AudioMixer: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var systemFormat: AudioStreamBasicDescription?
    private var micFormat: AudioStreamBasicDescription?
    private var machTimebase = mach_timebase_info()

    // Time-stamped mic chunks for time-aligned mixing
    private struct MicChunk {
        let samples: [Float]  // interleaved
        let frameCount: Int
        let channelCount: Int
        let hostTime: UInt64  // mach_absolute_time of first sample
        let sampleRate: Float64
    }
    private var micChunks: [MicChunk] = []
    private var nextMicOnlyIndex = 0

    deinit {}

    func setSystemFormat(_ format: AudioStreamBasicDescription) {
        lock.withLock { systemFormat = format }
    }

    func setMicFormat(_ format: AudioStreamBasicDescription) {
        lock.withLock { micFormat = format }
    }

    /// Must be called on the realtime audio thread (AVAudioEngine tap callback).
    /// Copies mic float samples immediately — the buffer is invalid after return.
    /// `hostTime` is the mach_absolute_time of the first sample (from AVAudioTime.hostTime).
    func enqueueMic(pcmBuffer: AVAudioPCMBuffer, hostTime: UInt64) {
        let frames = Int(pcmBuffer.frameLength)
        let channels = Int(pcmBuffer.format.channelCount)
        let count = frames * channels
        guard count > 0, let src = pcmBuffer.floatChannelData else { return }

        let samples: [Float] = { () -> [Float] in
            var s = [Float](repeating: 0, count: count)
            for ch in 0..<channels {
                let channelData = src[ch]
                for f in 0..<frames {
                    s[f * channels + ch] = channelData[f]
                }
            }
            return s
        }()

        lock.withLock {
            micChunks.append(MicChunk(
                samples: samples,
                frameCount: frames,
                channelCount: channels,
                hostTime: hostTime,
                sampleRate: pcmBuffer.format.sampleRate
            ))
            trimOldChunks()
        }
    }

    private func trimOldChunks() {
        if machTimebase.denom == 0 { mach_timebase_info(&machTimebase) }
        let numer = UInt64(machTimebase.numer)
        let denom = UInt64(machTimebase.denom)
        let now = mach_absolute_time()
        let nowNanos = Int64(now * numer / denom)
        let maxAge: Int64 = 5_000_000_000  // 5 seconds

        var removed = 0
        while let first = micChunks.first {
            let firstNanos = Int64(first.hostTime * numer / denom)
            if nowNanos - firstNanos > maxAge {
                micChunks.removeFirst()
                removed += 1
            } else {
                break
            }
        }
        nextMicOnlyIndex = max(0, nextMicOnlyIndex - removed)
    }

    /// Generate a CMSampleBuffer from mic-only audio (system = silence).
    /// Consumes chunks sequentially. Skips chunks older than 500ms — those
    /// were from a period when system audio was active and were already mixed.
    func makeMicOnlyCMSampleBuffer() -> CMSampleBuffer? {
        // Fall back to micFormat when systemFormat is not set (mic-only mode)
        let (fmt, hasFormat) = lock.withLock { (systemFormat ?? micFormat, systemFormat != nil || micFormat != nil) }
        guard hasFormat, let fmt = fmt else { return nil }
        let outCh = Int(fmt.mChannelsPerFrame)

        if machTimebase.denom == 0 { mach_timebase_info(&machTimebase) }
        let numer = UInt64(machTimebase.numer)
        let denom = UInt64(machTimebase.denom)
        let now = mach_absolute_time()
        let nowNanos = Int64(now * numer / denom)
        let maxAge: Int64 = 500_000_000  // 500ms — skip chunks from mix period

        let snapshot: (samples: [Float], frames: Int, hostTime: UInt64, sampleRate: Float64)?
        snapshot = lock.withLock {
            while nextMicOnlyIndex < micChunks.count {
                let chunk = micChunks[nextMicOnlyIndex]
                nextMicOnlyIndex += 1
                let chunkNanos = Int64(chunk.hostTime * numer / denom)
                guard chunk.frameCount > 0 else { continue }
                // Skip chunks that are too old (already mixed into system audio)
                if nowNanos - chunkNanos > maxAge { continue }
                // Skip chunks from more than 2s in the future (clock skew guard)
                if chunkNanos - nowNanos > 2_000_000_000 { continue }

                let outCount = chunk.frameCount * outCh
                var out = [Float](repeating: 0, count: outCount)
                let srcCh = min(chunk.channelCount - 1, outCh - 1)
                for f in 0..<chunk.frameCount {
                    for ch in 0..<outCh {
                        out[f * outCh + ch] = chunk.samples[f * chunk.channelCount + srcCh]
                    }
                }
                return (out, chunk.frameCount, chunk.hostTime, chunk.sampleRate)
            }
            return nil
        }

        guard let (samples, frames, hostTime, sampleRate) = snapshot else { return nil }

        let nanos = hostTime * UInt64(numer) / UInt64(denom)
        let ts = CMTime(value: CMTimeValue(nanos), timescale: 1_000_000_000)

        return makeCMSampleBuffer(
            samples: samples, frames: frames, channels: outCh,
            sampleRate: sampleRate, timing: ts
        )
    }

    /// Mix system audio with time-aligned mic audio.
    /// Each mic chunk has a hostTime; we find chunks that overlap in time
    /// with the system buffer and mix at the correct sample offsets.
    func mix(system sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        guard let sysASBD = asbd(of: sampleBuffer) else { return sampleBuffer }
        let sysFrames = Int(CMSampleBufferGetNumSamples(sampleBuffer))
        let sysCh = Int(sysASBD.mChannelsPerFrame)
        let sysSR = sysASBD.mSampleRate

        guard var sysSamples = readFloatSamples(sampleBuffer, asbd: sysASBD) else { return sampleBuffer }

        if machTimebase.denom == 0 { mach_timebase_info(&machTimebase) }
        let numer = UInt64(machTimebase.numer)
        let denom = UInt64(machTimebase.denom)

        let sysPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let sysStartNanos = Int64(CMTimeConvertScale(sysPTS, timescale: 1_000_000_000, method: .roundAwayFromZero).value)
        let sysEndNanos = sysStartNanos + Int64(Double(sysFrames) / sysSR * 1_000_000_000)

        let chunks = lock.withLock { micChunks }

        for chunk in chunks {
            let chunkStartNanos = Int64(chunk.hostTime * numer / denom)
            let chunkEndNanos = chunkStartNanos + Int64(Double(chunk.frameCount) / chunk.sampleRate * 1_000_000_000)

            let overlapStart = max(sysStartNanos, chunkStartNanos)
            let overlapEnd = min(sysEndNanos, chunkEndNanos)
            guard overlapStart < overlapEnd else { continue }

            // Frame offsets within each buffer for the overlap region
            let micStartFrame = Int(Double(overlapStart - chunkStartNanos) / 1_000_000_000 * chunk.sampleRate + 0.5)
            let sysStartFrame = Int(Double(overlapStart - sysStartNanos) / 1_000_000_000 * sysSR + 0.5)
            let mixFrames = Int(Double(overlapEnd - overlapStart) / 1_000_000_000 * sysSR + 0.5)

            guard sysStartFrame >= 0, sysStartFrame < sysFrames else { continue }
            guard micStartFrame >= 0, micStartFrame < chunk.frameCount else { continue }

            let srcCh = min(chunk.channelCount - 1, sysCh - 1)
            for f in 0..<mixFrames {
                let sysF = sysStartFrame + f
                guard sysF < sysFrames else { break }
                let micF = micStartFrame + Int(Double(f) * chunk.sampleRate / sysSR + 0.5)
                guard micF < chunk.frameCount else { break }

                let micSample = chunk.samples[micF * chunk.channelCount + srcCh]
                for ch in 0..<sysCh {
                    let outIdx = sysF * sysCh + ch
                    sysSamples[outIdx] = tanhf(sysSamples[outIdx] + micSample)
                }
            }
        }

        return makeCMSampleBuffer(
            samples: sysSamples, frames: sysFrames, channels: sysCh,
            sampleRate: sysSR, timing: sysPTS
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
