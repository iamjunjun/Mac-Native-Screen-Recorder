import CoreAudio
import Foundation

func audioObjectPropertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: element
    )
}

func checkOSStatus(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
        throw CoreAudioError.operationFailed(operation, status)
    }
}

enum CoreAudioError: LocalizedError {
    case operationFailed(String, OSStatus)
    case processObjectNotFound(pid_t)
    case tapUIDUnavailable
    case invalidAudioFormat

    var errorDescription: String? {
        switch self {
        case .operationFailed(let operation, let status):
            return "\(operation) 失败，CoreAudio 状态码：\(status)。"
        case .processObjectNotFound(let pid):
            return "找不到进程 \(pid) 对应的 CoreAudio 对象。请确认该应用正在播放或已经初始化音频。"
        case .tapUIDUnavailable:
            return "无法读取 Process Tap 的 UID。"
        case .invalidAudioFormat:
            return "Process Tap 返回了无法写入的音频格式。"
        }
    }
}
