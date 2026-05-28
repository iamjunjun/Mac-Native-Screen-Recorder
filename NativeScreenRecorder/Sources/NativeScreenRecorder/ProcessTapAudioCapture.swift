import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

enum ProcessTapTarget: Sendable {
    case global(excludingCurrentProcess: Bool)
    case process(pid: pid_t)
}

final class ProcessTapAudioCapture: @unchecked Sendable {
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    private let target: ProcessTapTarget
    private let queue = DispatchQueue(label: "NativeScreenRecorder.ProcessTapAudio")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var formatDescription: CMFormatDescription?
    private var audioFormat = AudioStreamBasicDescription()
    private var machTimebase = mach_timebase_info()
    private var isPrepared = false

    init(target: ProcessTapTarget) {
        self.target = target
    }

    deinit {
        stop()
    }

    func prepare() throws -> AudioStreamBasicDescription {
        guard !isPrepared else { return audioFormat }

        if #available(macOS 14.2, *) {
            let tapDescription = try makeTapDescription()
            tapDescription.name = "Native Screen Recorder Audio Tap"
            tapDescription.isPrivate = false
            tapDescription.muteBehavior = CATapMuteBehavior.unmuted

            try checkOSStatus(AudioHardwareCreateProcessTap(tapDescription, &tapID), "创建 Process Tap")
            audioFormat = try readTapFormat(tapID: tapID)
            formatDescription = try makeFormatDescription(audioFormat)
            aggregateDeviceID = try createAggregateDevice(containingTap: tapID)
            try createIOProc()
            isPrepared = true
            return audioFormat
        } else {
            throw CaptureEngineError.processTapUnavailable
        }
    }

    func start() throws {
        if !isPrepared {
            _ = try prepare()
        }

        mach_timebase_info(&machTimebase)

        guard let ioProcID else { return }
        try checkOSStatus(AudioDeviceStart(aggregateDeviceID, ioProcID), "启动 Process Tap 输入")
    }

    func stop() {
        if let ioProcID {
            _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }

        if aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) {
                _ = AudioHardwareDestroyProcessTap(tapID)
            }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        isPrepared = false
    }

    @available(macOS 14.2, *)
    private func makeTapDescription() throws -> CATapDescription {
        switch target {
        case .global(let excludingCurrentProcess):
            let currentProcess = try? processObjectID(for: ProcessInfo.processInfo.processIdentifier)
            let excluded = excludingCurrentProcess ? Array([currentProcess].compactMap { $0 }) : []
            return CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        case .process(let pid):
            let processObjectID = try processObjectID(for: pid)
            return CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        }
    }

    private func processObjectID(for pid: pid_t) throws -> AudioObjectID {
        var address = audioObjectPropertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifierPID = pid
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = withUnsafePointer(to: &qualifierPID) { pidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPointer,
                &size,
                &processObjectID
            )
        }

        try checkOSStatus(status, "转换进程 ID")
        guard processObjectID != kAudioObjectUnknown else {
            throw CoreAudioError.processObjectNotFound(pid)
        }
        return processObjectID
    }

    private func readTapFormat(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = audioObjectPropertyAddress(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try checkOSStatus(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "读取 Tap 音频格式")

        guard format.mSampleRate > 0, format.mChannelsPerFrame > 0 else {
            throw CoreAudioError.invalidAudioFormat
        }

        return format
    }

    private func readTapUID(tapID: AudioObjectID) throws -> String {
        var address = audioObjectPropertyAddress(kAudioTapPropertyUID)
        var cfUID: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { ptr in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, ptr)
        }
        try checkOSStatus(status, "读取 Tap UID")
        guard let uid = cfUID?.takeUnretainedValue() as String?, !uid.isEmpty else {
            throw CoreAudioError.tapUIDUnavailable
        }
        return uid
    }

    private func createAggregateDevice(containingTap tapID: AudioObjectID) throws -> AudioObjectID {
        let tapUID = try readTapUID(tapID: tapID)
        let systemOutputID = try readDefaultSystemOutputDevice()
        let systemOutputUID = try readDeviceUID(deviceID: systemOutputID)
        let aggregateUID = "NativeScreenRecorder.Aggregate.\(UUID().uuidString)"

        let description: [String: Any] = [
            String(kAudioAggregateDeviceNameKey): "Native Screen Recorder Audio",
            String(kAudioAggregateDeviceUIDKey): aggregateUID,
            String(kAudioAggregateDeviceMainSubDeviceKey): systemOutputUID,
            String(kAudioAggregateDeviceIsPrivateKey): true,
            String(kAudioAggregateDeviceIsStackedKey): false,
            String(kAudioAggregateDeviceTapAutoStartKey): true,
            String(kAudioAggregateDeviceSubDeviceListKey): [
                [String(kAudioSubDeviceUIDKey): systemOutputUID]
            ],
            String(kAudioAggregateDeviceTapListKey): [
                [
                    String(kAudioSubTapDriftCompensationKey): true,
                    String(kAudioSubTapUIDKey): tapUID
                ]
            ]
        ]

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        try checkOSStatus(AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID), "创建临时 Aggregate Device")
        return deviceID
    }

    private func readDefaultSystemOutputDevice() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try checkOSStatus(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID),
            "读取默认系统输出设备"
        )
        return deviceID
    }

    private func readDeviceUID(deviceID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        try checkOSStatus(status, "读取设备 UID")
        guard let uid = cfUID?.takeUnretainedValue() as String?, !uid.isEmpty else {
            throw CoreAudioError.tapUIDUnavailable
        }
        return uid
    }

    private func createIOProc() throws {
        var createdIOProcID: AudioDeviceIOProcID?
        let block: AudioDeviceIOBlock = { [weak self] _, inputData, inputTime, _, _ in
            guard let self, let sampleBuffer = self.makeSampleBuffer(from: inputData, inputTime: inputTime) else { return }
            self.onSampleBuffer?(sampleBuffer)
        }

        try checkOSStatus(
            AudioDeviceCreateIOProcIDWithBlock(&createdIOProcID, aggregateDeviceID, queue, block),
            "创建音频读取回调"
        )

        ioProcID = createdIOProcID
    }

    private func makeSampleBuffer(
        from inputData: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>
    ) -> CMSampleBuffer? {
        guard let formatDescription else { return nil }

        let bytesPerFrame = max(Int(audioFormat.mBytesPerFrame), 1)
        let byteCount = Int(inputData.pointee.mBuffers.mDataByteSize)
        let frameCount = byteCount / bytesPerFrame
        guard frameCount > 0, let audioBytes = inputData.pointee.mBuffers.mData else { return nil }

        let now = mach_absolute_time()
        let absoluteNanos = now * UInt64(machTimebase.numer) / UInt64(machTimebase.denom)
        let presentationTimeStamp = CMTime(value: CMTimeValue(absoluteNanos), timescale: 1_000_000_000)

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == noErr, let blockBuffer else { return nil }

        let replaceStatus = CMBlockBufferReplaceDataBytes(
            with: audioBytes,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: byteCount
        )
        guard replaceStatus == noErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            presentationTimeStamp: presentationTimeStamp,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let sampleBuffer else { return nil }
        return sampleBuffer
    }

    private func makeFormatDescription(_ format: AudioStreamBasicDescription) throws -> CMFormatDescription {
        var mutableFormat = format
        var description: CMFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &mutableFormat,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        try checkOSStatus(status, "创建音频格式描述")

        guard let description else { throw CoreAudioError.invalidAudioFormat }
        return description
    }
}
