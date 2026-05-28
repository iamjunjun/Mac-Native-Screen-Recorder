import Foundation

enum AudioCaptureMode: String, CaseIterable, Identifiable {
    case globalSystem
    case selectedApplication

    var id: String { rawValue }

    var title: String {
        switch self {
        case .globalSystem:
            return "全局系统声音"
        case .selectedApplication:
            return "指定应用声音"
        }
    }

    var detail: String {
        switch self {
        case .globalSystem:
            return "录制整台 Mac 正在播放的系统音频，不改变当前扬声器或耳机。"
        case .selectedApplication:
            return "只捕获所选应用的窗口内容和音频，适合录浏览器、播放器或会议应用。"
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
}
