# NativeScreenRecorder

macOS 原生录屏应用。通过 ScreenCaptureKit + CoreAudio Process Tap 实现屏幕和音频录制，无需 BlackHole 等虚拟声卡。

## 技术栈

- Swift 6.0, SwiftUI, macOS 14.2+
- ScreenCaptureKit (屏幕帧 + sourceRect 区域裁剪)
- CoreAudio Process Tap (macOS 14.2+, 应用级音频捕获)
- AVAssetWriter (H.264/HEVC MP4 封装)
- Swift Package Manager 构建

## 构建与打包

```bash
# Debug 构建
swift build

# Release 构建（推荐分发用）
swift build -c release

# 打包 .app（调试版）
./Scripts/package_app.sh

# 手动打包 Release 版
swift build -c release
APP_DIR="./NativeScreenRecorder.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp .build/arm64-apple-macosx/release/NativeScreenRecorder "$APP_DIR/Contents/MacOS/"
cp App/Info.plist "$APP_DIR/Contents/"
cp App/AppIcon.icns "$APP_DIR/Contents/Resources/"
```

## 架构

```
Sources/NativeScreenRecorder/
├── NativeScreenRecorderApp.swift    # @main 入口，.task 中刷新内容 + 延迟合并音频进程
├── ContentView.swift                # SwiftUI 界面：录制模式、编码、保存、状态
├── RecorderStore.swift              # @MainActor ObservableObject，所有 UI 状态 + 录制控制
├── CaptureEngine.swift              # SCStream 管理，Retina 像素尺寸，sourceRect，编码配置
├── MovieFileWriter.swift            # AVAssetWriter MP4，H.264/HEVC 码率阶梯
├── Models.swift                     # AudioCaptureMode, CaptureMode, VideoCodec, RecordingRequest
├── ProcessTapAudioCapture.swift     # CoreAudio Process Tap，聚合设备，音频回调->CMSampleBuffer
├── CoreAudioHelpers.swift           # checkOSStatus, CoreAudioError, audioObjectPropertyAddress
├── AudioProcessDiscovery.swift      # kAudioHardwarePropertyProcessObjectList 发现音频进程
├── AreaSelectionOverlayView.swift   # 全屏透明蒙层，拖拽选区，mouseDown/Dragged/Up，ESC取消
└── RecordingAreaOverlay.swift       # 录制中虚线边框叠加层，sharingType=.none 排除录制
```

### 数据流

```
SCStream(display filter) ──screen frames──> CaptureEngine ──CMSampleBuffer──> MovieFileWriter
ProcessTapAudioCapture ──audio buffers──> CaptureEngine ──CMSampleBuffer──> MovieFileWriter
                                                        └── AVAssetWriter ──> .mp4
```

### 录制模式

- **全屏**: `configuration.width/height = mode.pixelWidth/pixelHeight`（CGDisplayCopyDisplayMode 取物理像素）
- **区域**: `configuration.sourceRect` (Quartz 坐标) + `configuration.width/height = 裁剪后像素尺寸`
- **声音**: 全局系统声音 / 指定应用声音 (ProcessTapAudioCapture)

## 关键设计决策与坑

### 1. Retina 显示器修复
`SCDisplay.width/height` 返回点值(1920x1080)，不是物理像素。必须用 `CGDisplayCopyDisplayMode(displayID).pixelWidth/pixelHeight` 获取真实像素。

### 2. 区域录制无变形
设置 `configuration.sourceRect` 时，`configuration.width/height` 必须同步设为**裁剪后像素尺寸**，否则 SCStream 会把小区域拉伸到全屏尺寸造成变形。

### 3. NSWindow 崩溃修复
`makeKeyAndOrderFront(nil)` + `close()` = `_NSWindowTransformAnimation` SIGSEGV。
原因：`makeKeyAndOrderFront` 触发 CoreAnimation Transform 动画，`close()` 提前销毁窗口，动画 dealloc 时 objc_release 野指针。
**修复**: `isReleasedWhenClosed = false` + 用 `orderOut(nil)` 代替 `close()`。如果不需要键盘事件，用 `orderFront(nil)` 代替 `makeKeyAndOrderFront`。

### 4. AudioProcessDiscovery 崩溃修复
泛型函数 `readProcessProperty<T>` 中使用 `unsafeBitCast(0, to: T.self)` 在 Swift 6 下触发 `_assertionFailure` SIGTRAP。
**修复**: 用具体类型的 `readPID()` / `readIsRunningOutput()` 代替泛型 + `unsafeBitCast`，并添加 `AudioObjectHasProperty` 预检查。

### 5. 启动时延迟音频扫描
`refreshShareableContent()` 只拉取 SCShareableContent（显示器 + 窗口应用）。
CoreAudio 进程列表(`discoverRunningAudioProcesses`) 延迟 500ms 在 `mergeAudioProcesses()` 中执行，避免启动时 CoreAudio 内部断言。

### 6. 编码
- 像素格式: `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` ('420v')
- `scalesToFit = false`（不做内部缩放）
- HEVC vs H.264 码率阶梯（按像素数分档），B-frames 开启

### 7. 录制区域虚线框
- 颜色: #CACACA
- 排除录制: `window.sharingType = .none`

## 版本

- **v2.0**: 系统音频录制功能（ProcessTapAudioCapture）
- **v2.1** (当前): 区域录制、HEVC 编码、浏览器音频发现、崩溃修复
