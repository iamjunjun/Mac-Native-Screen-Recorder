import Foundation

enum Language: String {
    case chinese = "zh"
    case english = "en"
}

enum L {
    /// Current language: compile-time ENGLISH flag → English, otherwise Chinese
    static let language: Language = {
        #if ENGLISH
        return .english
        #else
        return .chinese
        #endif
    }()

    // MARK: - Header
    static var appTitle: String { language == .english ? "Native Screen Recorder" : "原生录屏" }
    static var subtitle: String { language == .english ? "No impact on current audio playback" : "不影响当前声音播放" }
    static var refreshTooltip: String { language == .english ? "Refresh devices and applications" : "刷新设备与应用列表" }

    // MARK: - Hero Controls
    static var fullScreen: String { language == .english ? "Full Screen" : "全屏" }
    static var customArea: String { language == .english ? "Custom Area" : "自定义区域" }
    static var startRecording: String { language == .english ? "Start Recording" : "开始录制" }
    static var stopRecording: String { language == .english ? "Stop Recording" : "停止录制" }
    static var microphone: String { language == .english ? "Microphone" : "麦克风" }
    static var systemAudio: String { language == .english ? "System Audio" : "系统声音" }

    // MARK: - Settings Panel
    static var captureMode: String { language == .english ? "Capture Mode" : "录制模式" }
    static var selectArea: String { language == .english ? "Select Area" : "拖选区域" }
    static var display: String { language == .english ? "Display" : "显示器" }
    static var audioSource: String { language == .english ? "Audio Source" : "声音来源" }
    static var application: String { language == .english ? "Application" : "应用" }
    static var global: String { language == .english ? "Global" : "全局" }
    static var areaSelect: String { language == .english ? "Area Select" : "区域选择" }
    static var globalSystemAudio: String { language == .english ? "System Audio" : "全局系统声音" }
    static var appAudio: String { language == .english ? "App Audio" : "指定应用声音" }

    // MARK: - Codec & Storage Panels
    static var encoding: String { language == .english ? "Encoding" : "编码" }
    static var videoCodec: String { language == .english ? "Video Codec" : "视频编码" }
    static var storage: String { language == .english ? "Storage" : "存储" }
    static var chooseSaveLocation: String { language == .english ? "Choose save location" : "选择保存位置" }
    static var openSaveLocation: String { language == .english ? "Open save location" : "打开保存位置" }

    // MARK: - Status
    static var recording: String { language == .english ? "Recording" : "录制中" }
    static var ready: String { language == .english ? "Ready" : "就绪" }
    static var readyToRecord: String { language == .english ? "Ready to record" : "准备录制" }
    static var contentRefreshed: String { language == .english ? "Content refreshed" : "已刷新可录制内容" }
    static var failedToReadContent: String { language == .english ? "Failed to read capturable content" : "无法读取可录制内容" }
    static var recordingTo: String { language == .english ? "Recording to %@" : "正在录制到 %@" }
    static var failedToStart: String { language == .english ? "Failed to start recording" : "启动录制失败" }
    static var recordingSaved: String { language == .english ? "Recording saved: %@" : "录制完成：%@" }
    static var errorStopping: String { language == .english ? "Error stopping recording" : "停止录制时出错" }

    // MARK: - Area Selection
    static var clickToSelectArea: String { language == .english ? "Click and drag to select area" : "点击图标拖选录制区域" }
    static var selectedArea: String { language == .english ? "Selected: %d × %d" : "已选区域：%d × %d" }
    static var areaSelected: String { language == .english ? "Area selected: %d × %d" : "已选择区域：%d × %d" }

    // MARK: - Display & App Selection
    static func displayTitle(_ id: UInt32) -> String {
        language == .english ? "Display \(id)" : "显示器 \(id)"
    }
    static var unnamedApp: String { language == .english ? "Untitled App" : "未命名应用" }
    static var selectDisplay: String { language == .english ? "Select Display" : "选择显示器" }
    static var selectApplication: String { language == .english ? "Select Application" : "选择应用" }
    static var select: String { language == .english ? "Select" : "选择" }
    static var openSystemSettings: String { language == .english ? "Open System Settings" : "打开系统设置" }

    // MARK: - Permission Errors
    static var screenRecordingDenied: String {
        language == .english
            ? "Screen recording permission denied (TCC).\nPlease allow this app in System Settings → Privacy & Security → Screen Recording, then relaunch.\n\nDebug info: %@"
            : "屏幕录制权限未授权（TCC 拒绝）。\n请在系统设置 → 隐私与安全性 → 屏幕录制中允许本应用，然后重新打开应用。\n\n调试信息：%@"
    }
    static var noDisplayError: String { language == .english ? "No display available. Please refresh first." : "没有可用显示器。请先点刷新。" }
    static var selectAppForAudio: String { language == .english ? "Please select an application for audio capture." : "请选择要录制声音的应用。" }
    static var selectAreaFirst: String { language == .english ? "Please select a recording area first." : "请先拖选录制区域。" }

    // MARK: - CaptureEngine Errors
    static var noDisplayFound: String { language == .english ? "No display found for recording." : "找不到要录制的显示器。" }
    static var appNotFound: String { language == .english ? "Application not found. It may have quit or has no capturable windows." : "找不到要录制的应用，它可能已经退出或没有可捕获窗口。" }
    static var alreadyRecording: String { language == .english ? "Recording is already in progress." : "当前已经在录制。" }
    static var notRecording: String { language == .english ? "No active recording." : "当前没有正在进行的录制。" }
    static var streamStopped: String { language == .english ? "Recording stream stopped." : "录制流已停止。" }
    static var processTapUnavailable: String { language == .english ? "Core Audio Process Tap requires macOS 14.2 or later." : "Core Audio Process Tap 需要 macOS 14.2 或更新版本。" }
    static var micPermissionDenied: String { language == .english ? "Microphone permission denied. Please allow this app in System Settings → Privacy & Security → Microphone." : "麦克风权限未授权，请在系统设置 → 隐私与安全性 → 麦克风中允许本应用。" }

    // MARK: - CoreAudio Errors
    static var operationFailed: String { language == .english ? "%@ failed. CoreAudio status: %d." : "%@ 失败，CoreAudio 状态码：%d。" }
    static var processObjectNotFound: String { language == .english ? "CoreAudio object not found for process %d. Make sure the app is playing audio." : "找不到进程 %d 对应的 CoreAudio 对象。请确认该应用正在播放或已经初始化音频。" }
    static var tapUIDUnavailable: String { language == .english ? "Unable to read Process Tap UID." : "无法读取 Process Tap 的 UID。" }
    static var invalidAudioFormat: String { language == .english ? "Process Tap returned an unsupported audio format." : "Process Tap 返回了无法写入的音频格式。" }

    // MARK: - Models
    static var off: String { language == .english ? "Off" : "关闭" }
    static var noSystemAudio: String { language == .english ? "No system audio recording." : "不录制系统音频。" }
    static var globalSystemAudioDetail: String { language == .english ? "Record all system audio without affecting current output." : "录制整台 Mac 正在播放的系统音频，不改变当前扬声器或耳机。" }
    static var appAudioDetail: String { language == .english ? "Capture only the selected app's windows and audio. Ideal for browsers, players, or meeting apps." : "只捕获所选应用的窗口内容和音频，适合录浏览器、播放器或会议应用。" }
}
