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
├── ContentView.swift                # SwiftUI 界面，Modern 风格，毛玻璃背景，图标化分区
├── RecorderStore.swift              # @MainActor ObservableObject，所有 UI 状态 + 录制控制
├── CaptureEngine.swift              # SCStream 管理 + AVAudioEngine 麦克风 + AudioMixer 集成
├── AudioMixer.swift                 # PCM 音频混合器，系统音频+麦克风混音，tanh 软削波
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
AVAudioEngine(mic tap) ──PCM buffer──> AudioMixer ──CMSampleBuffer──> MovieFileWriter
                                              ↑ system audio CMSampleBuffer
                                              └── AVAssetWriter ──> .mp4
```

- 系统音频通过 ProcessTap 回调驱动写入
- 麦克风通过 AVAudioEngine inputNode installTap 捕获，memcpy 到 AudioMixer 预分配缓冲区
- AudioMixer.mix(system:) 混音后输出；当系统音频静默时，makeMicOnlyCMSampleBuffer() 单独输出麦克风

### 录制模式

- **全屏**: `configuration.width/height = mode.pixelWidth/pixelHeight`（CGDisplayCopyDisplayMode 取物理像素）
- **区域**: `configuration.sourceRect` (Quartz 坐标) + `configuration.width/height = 裁剪后像素尺寸`
- **声音**: 全局系统声音 / 指定应用声音 (ProcessTapAudioCapture)
- **麦克风**: 开关控制，与系统音频混音为单条音轨

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

### 8. AudioMixer 线程安全与 AVAudioPCMBuffer 生命周期
`AVAudioPCMBuffer` 仅在 tap 回调内有效，回调返回后底层内存被释放。不能直接存储引用。
**修复**: `enqueueMic` 在 realtime 线程上立即将 float samples 拷贝到预分配的 `UnsafeMutablePointer<Float>` 缓冲区。
后续 `makeMicOnlyCMSampleBuffer()` 和 `mix(system:)` 在锁内将数据再拷贝为 `[Float]`，防止 `enqueueMic` 并发 realloc 导致 use-after-free。

### 9. mach_timebase 除以零崩溃
`mach_timebase_info()` 返回全零结构体（denom=0）。在 Swift debug 模式下，`UInt64` 除以零触发 `_assertionFailure` → SIGTRAP。
**修复**: 先检查 `if machTimebase.denom == 0 { mach_timebase_info(&machTimebase) }`，再计算 `nanos = now * numer / denom`。

### 10. 麦克风采样率不匹配
`makeMicOnlyCMSampleBuffer` 曾以系统音频采样率（如 48000Hz）输出麦克风数据，但 Mac 内置麦可能是 44100Hz，导致音调偏移（变声）。
**修复**: 存储 `micSampleRate`，输出时使用麦克风实际采样率。

### 11. 麦克风回声问题
录制时如果同时用扬声器播放系统声音，麦克风会录到扬声器输出的声音，造成回声。
**建议**: UI 中提示用户佩戴耳机。

### 12. 浏览器多进程音频发现
Chrome/Edge 等浏览器将音频放在子进程中，Safari 的 WebKit.GPU 是 XPC 服务（不在主应用 bundle 内）。
`AudioProcessDiscovery.discoverAudioPIDs(forApplicationPID:)` 先用 bundle 路径前缀匹配（Chrome 类），再用进程名模糊匹配（Safari 类）。

### 13. [未解决] 混合录制时音频失真（闷音）
**现象**: 同时开启麦克风和系统声音录制，单独录任一路均正常。但一旦系统开始播放音频，整个录制输出出现明显失真/闷音。

**可能原因**:
1. **PCM→AAC 编码器兼容性**: `makeCMSampleBuffer` 创建的交错 Float32 PCM 格式与 AVAssetWriter AAC 编码器的期望格式不完全匹配。
2. **数字削波**: Process Tap 捕获的系统音频信号可能在 0dBFS 附近，乘以 0.6 后叠加 0.4×麦克风信号，组合后持续触发限幅器，产生可闻失真。
3. **时间域对齐**: 系统音频（Process Tap IOProc）和麦克风（AVAudioEngine tap）虽然都用 `mach_absolute_time()` 时基，但两路到达 AAC 编码器的时间可能存在微秒级错位。
4. **AVAssetWriterInput 格式漂移**: 每次 `mix()` 输出一个新的 CMSampleBuffer（全新 FormatDescription），编码器可能频繁重建内部状态。

**建议排查方向**:
- 移除硬限幅器，改用浮点原生值输出，在后期处理中调节电平
- 验证 Process Tap 原始 ASBD 的 `mFormatFlags`，确保 `makeCMSampleBuffer` 输出完全匹配
- 尝试直接修改原始 CMSampleBuffer 的 mMutableData 而非创建新 buffer
- 改用 `AVAudioMixer` 或 `AVMutableAudioMix` 等 AVFoundation 原生混音接口

## 版本

- **v2.0**: 系统音频录制功能（ProcessTapAudioCapture）
- **v2.1**: 区域录制、HEVC 编码、浏览器音频发现、崩溃修复
- **v2.2**: 麦克风混音录制（AudioMixer），支持系统音频+麦克风混合输出
- **v2.3**: UI 重新设计，Modern 风格，毛玻璃背景，图标化分区，窗口可调大小
- **v2.4**: UI 继续优化 — hero 控制栏、玻璃面板、新布局
- **v2.5**: 修复混音采样率对齐误差 + 麦克风单独录制崩溃问题
- **v2.5.1**: 修复混音循环内采样率转换误差 — 改用简单递增索引
- **v2.5.2**: 修复混音增益过高导致系统音频压制麦克风 — 改用加法混合替代 tanhf
- **v2.5.4** (当前):
  - 修复 srcCh 声道选择取到右声道（srcCh = min(ch-1, out-1) → 始终取 0）
  - 修复 mix() 输出格式不统一（有/无混音时交替两种格式）
  - 混音增益调整 + 硬限幅保护
  - **未解决**: 混合录制失真的问题仍需排查
