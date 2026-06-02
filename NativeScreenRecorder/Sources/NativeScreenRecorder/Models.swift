import Foundation

enum AudioCaptureMode: String, CaseIterable, Identifiable {
    case none
    case globalSystem
    case selectedApplication

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none:             return .localized("off")
        case .globalSystem:     return .localized("global_system_audio")
        case .selectedApplication: return .localized("app_audio")
        }
    }

    var detail: String {
        switch self {
        case .none:             return .localized("no_system_audio")
        case .globalSystem:     return .localized("global_system_audio_detail")
        case .selectedApplication: return .localized("app_audio_detail")
        }
    }
}

enum CaptureMode: String, CaseIterable, Identifiable {
    case fullScreen
    case area

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullScreen: return .localized("full_screen")
        case .area:       return .localized("area_select")
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
