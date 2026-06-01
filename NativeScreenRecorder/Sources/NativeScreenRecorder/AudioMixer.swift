@preconcurrency import AVFoundation
import CoreMedia
import os

private let df = DateFormatter()
private func debugLog(_ message: String) {
    df.dateFormat = "HH:mm:ss.SSS"
    let ts = df.string(from: Date())
    fputs("\(ts) AudioMixer: \(message)\n", stderr)
}

final class AudioMixer: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var systemFormat: AudioStreamBasicDescription?
    private var micFormat: AudioStreamBasicDescription?

    // Mic audio chunks — FIFO queue consumed by mix() and makeMicOnlyCMSampleBuffer.
    // hostTime is only used for mic-only PTS generation (mach_absolute_time domain).
    private struct MicChunk {
        let samples: [Float]
        let frameCount: Int
        let channelCount: Int
        let sampleRate: Float64
        let hostTime: UInt64  // mach_absolute_time of first sample
    }
    private var micChunks: [MicChunk] = []

    // Read cursor across all paths (shared between mix and mic-only).
    // Rebases to offset within first remaining chunk after trimming.
    private var consumedMicFrames: Int = 0

    deinit {}

    func setSystemFormat(_ format: AudioStreamBasicDescription) {
        lock.withLock { systemFormat = format }
    }

    func setMicFormat(_ format: AudioStreamBasicDescription) {
        lock.withLock { micFormat = format }
    }

    // MARK: - Enqueue (realtime audio thread)

    func enqueueMic(pcmBuffer: AVAudioPCMBuffer, hostTime: UInt64) {
        let frames = Int(pcmBuffer.frameLength)
        let channels = Int(pcmBuffer.format.channelCount)
        let count = frames * channels
        guard count > 0, let src = pcmBuffer.floatChannelData else { return }

        let samples: [Float] = {
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
                sampleRate: pcmBuffer.format.sampleRate,
                hostTime: hostTime
            ))
            debugLog("enqueueMic: frames=\(frames) channels=\(channels) chunkCount=\(micChunks.count)")
        }
    }

    // MARK: - Mic-only path

    func makeMicOnlyCMSampleBuffer() -> CMSampleBuffer? {
        let hasFormat = lock.withLock { systemFormat != nil || micFormat != nil }
        guard hasFormat else { return nil }
        // Always output mono (1 channel) — matches MovieFileWriter's AAC fallback.
        let outCh = 1

        if machTimebase.denom == 0 { mach_timebase_info(&machTimebase) }
        let numer = UInt64(machTimebase.numer)
        let denom = UInt64(machTimebase.denom)

        let snapshot: (samples: [Float], frames: Int, sampleRate: Float64, hostTime: UInt64)?
        snapshot = lock.withLock {
            var remaining = consumedMicFrames
            for chunk in micChunks {
                if remaining < chunk.frameCount {
                    let startFrame = remaining
                    let availFrames = chunk.frameCount - startFrame
                    let outCount = availFrames * outCh
                    var out = [Float](repeating: 0, count: outCount)
                    let srcCh = 0  // always use first mic channel (primary)
                    for f in 0..<availFrames {
                        for ch in 0..<outCh {
                            let micVal = chunk.samples[(startFrame + f) * chunk.channelCount + srcCh]
                            out[f * outCh + ch] = micVal
                        }
                    }
                    return (out, availFrames, chunk.sampleRate, chunk.hostTime)
                }
                remaining -= chunk.frameCount
            }
            return nil
        }

        guard let (samples, frames, sampleRate, hostTime) = snapshot else {
            debugLog("makeMicOnlyCMSampleBuffer: returning nil")
            return nil
        }

        // Use hostTime (mach_absolute_time domain) for PTS to match
        // video and system audio timestamps — AVAssetWriter requires
        // all buffer PTS >= session start time.
        let nanos = hostTime * numer / denom
        let ts = CMTime(value: CMTimeValue(nanos), timescale: 1_000_000_000)

        lock.withLock {
            consumedMicFrames += frames
            trimConsumedChunks()
        }

        debugLog("makeMicOnlyCMSampleBuffer: returning frames=\(frames) pts=\(nanos)")

        return makeCMSampleBuffer(
            samples: samples, frames: frames, channels: outCh,
            sampleRate: sampleRate, timing: ts
        )
    }

    // MARK: - Mix path (system audio + mic)

    func mix(system sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        guard let sysASBD = asbd(of: sampleBuffer) else { return sampleBuffer }
        let sysFrames = Int(CMSampleBufferGetNumSamples(sampleBuffer))
        let sysCh = Int(sysASBD.mChannelsPerFrame)
        let sysSR = sysASBD.mSampleRate

        guard var sysSamples = readFloatSamples(sampleBuffer, asbd: sysASBD) else { return sampleBuffer }

        let (mixPlan, totalMicFramesConsumed) = lock.withLock { () -> ([(chunkIdx: Int, startFrame: Int, mixSysFrames: Int, srRatio: Double, chunk: MicChunk)]?, Int) in
            var remaining = consumedMicFrames
            var chunkIdx = 0
            var plan: [(Int, Int, Int, Double, MicChunk)] = []
            var totalConsumed = 0
            var neededSysFrames = sysFrames

            while neededSysFrames > 0 && chunkIdx < micChunks.count {
                let chunk = micChunks[chunkIdx]
                let availMicFrames = chunk.frameCount - max(0, remaining)

                if availMicFrames <= 0 {
                    remaining -= chunk.frameCount
                    chunkIdx += 1
                    continue
                }

                let startFrame = max(0, remaining)
                let srRatio = Double(chunk.sampleRate) / sysSR

                let chunkSysFrames = Int(Double(availMicFrames) / srRatio)
                let take = min(chunkSysFrames, neededSysFrames)
                if take <= 0 { break }

                plan.append((chunkIdx, startFrame, take, srRatio, chunk))
                let micConsumed = Int(Double(take) * srRatio + 0.5)
                totalConsumed += micConsumed
                neededSysFrames -= take

                remaining += micConsumed
                if remaining >= chunk.frameCount {
                    remaining -= chunk.frameCount
                    chunkIdx += 1
                }
            }

            if plan.isEmpty { return (nil, 0) }

            let newConsumed = consumedMicFrames + totalConsumed
            consumedMicFrames = newConsumed

            return (plan, newConsumed)
        }

        let sysPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if let plan = mixPlan {
            debugLog("mix: sysFrames=\(sysFrames) sysSR=\(sysSR) micConsumedFrames=\(totalMicFramesConsumed) planItems=\(plan.count)")

            var sysOffset = 0
            for (_, startFrame, mixSysFrames, srRatio, chunk) in plan {
                let srcCh = 0  // always use first mic channel (primary)
                for f in 0..<mixSysFrames {
                    let sysF = sysOffset + f
                    guard sysF < sysFrames else { break }
                    let micF = startFrame + Int(Double(f) * srRatio + 0.5)
                    guard micF >= 0, micF < chunk.frameCount else { continue }

                    let micSample = chunk.samples[micF * chunk.channelCount + srcCh]
                    for ch in 0..<sysCh {
                        let outIdx = sysF * sysCh + ch
                        // Reduce system slightly and add mic. Keep total gain ≤ 1.0
                        // and clamp to [-1, 1] to prevent digital clipping.
                        let mixed = sysSamples[outIdx] * 0.6 + micSample * 0.4
                        sysSamples[outIdx] = max(-1.0, min(1.0, mixed))
                    }
                }
                sysOffset += mixSysFrames
            }
            lock.withLock { trimConsumedChunks() }
        } else {
            debugLog("mix: no mic data available for this sys buffer")
        }

        // Always output through makeCMSampleBuffer for a consistent format.
        // Returning the original buffer (which may have different format flags)
        // causes AVAssetWriter to reinitialize the AAC encoder, creating glitches.
        return makeCMSampleBuffer(
            samples: sysSamples, frames: sysFrames, channels: sysCh,
            sampleRate: sysSR, timing: sysPTS
        ) ?? sampleBuffer
    }

    // MARK: - Chunk cleanup

    private func trimConsumedChunks() {
        var remaining = consumedMicFrames
        while let first = micChunks.first {
            if remaining >= first.frameCount {
                remaining -= first.frameCount
                micChunks.removeFirst()
            } else {
                break
            }
        }
        consumedMicFrames = remaining
    }

    // MARK: - Helpers

    private var machTimebase = mach_timebase_info()

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
