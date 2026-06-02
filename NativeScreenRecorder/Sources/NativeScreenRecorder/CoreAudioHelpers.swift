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
            return String.localized("operation_failed \(operation) \(status)")
        case .processObjectNotFound(let pid):
            return String.localized("process_object_not_found \(pid)")
        case .tapUIDUnavailable:
            return String.localized("tap_uid_unavailable")
        case .invalidAudioFormat:
            return String.localized("invalid_audio_format")
        }
    }
}
