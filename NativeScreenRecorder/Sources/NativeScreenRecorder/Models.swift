import Foundation

enum AudioCaptureMode: String, CaseIterable, Identifiable {
    case none
    case globalSystem
    case selectedApplication

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none:             return L.off
        case .globalSystem:     return L.globalSystemAudio
        case .selectedApplication: return L.appAudio
        }
    }

    var detail: String {
        switch self {
        case .none:             return L.noSystemAudio
        case .globalSystem:     return L.globalSystemAudioDetail
        case .selectedApplication: return L.appAudioDetail
        }
    }
}

enum CaptureMode: String, CaseIterable, Identifiable {
    case fullScreen
    case area

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullScreen: return L.fullScreen
        case .area:       return L.areaSelect
        }
    }
}

enum VideoCodec: String, CaseIterable, Identifiable {
    case h264
    case hevc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC (H.265)"
        }
    }
}

struct DisplayOption: Identifiable, Hashable {
    let id: UInt32
    let title: String
    let width: Int
    let height: Int

    var subtitle: String {
        "\(width) x \(height)"
    }
}

struct ApplicationOption: Identifiable, Hashable {
    let id: pid_t
    let name: String
    let bundleIdentifier: String

    var title: String {
        bundleIdentifier.isEmpty ? name : "\(name)  (\(bundleIdentifier))"
    }
}

struct RecordingRequest {
    let displayID: UInt32
    let audioMode: AudioCaptureMode
    let applicationProcessID: pid_t?
    let outputURL: URL
    let captureMode: CaptureMode
    let sourceRect: CGRect?
    let preferredCodec: VideoCodec
    let isMicrophoneEnabled: Bool
}
