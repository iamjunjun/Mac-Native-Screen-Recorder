# NativeScreenRecorder

macOS 原生录屏应用。通过 ScreenCaptureKit 三轨架构实现屏幕和音频录制，无需 BlackHole 等虚拟声卡。

## 技术栈

- Swift 6.0, SwiftUI, macOS 15.0+
- ScreenCaptureKit (屏幕帧 + 系统音频 + 麦克风，三轨独立采集)
- AVAssetWriter (H.264/HEVC + 双 AAC 音频轨道)
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
├── RecorderStore.swift              # @MainActor ObservableObject，所有 UI 状态 + 录制控制 + 计时器
├── CaptureEngine.swift              # SCStream 画面+麦克风 + ProcessTapAudioCapture 指定应用音频
├── ProcessTapAudioCapture.swift     # Core Audio Process Tap，按 PID 捕获指定应用音频
├── MovieFileWriter.swift            # AVAssetWriter MP4，VTPixelTransferSession 色彩转换，双音频轨道
├── Models.swift                     # AudioCaptureMode, CaptureMode, VideoCodec, RecordingRequest
├── CoreAudioHelpers.swift           # checkOSStatus, CoreAudioError, audioObjectPropertyAddress
├── AudioProcessDiscovery.swift      # kAudioHardwarePropertyProcessObjectList 发现音频进程
├── AreaSelectionOverlayView.swift   # 全屏透明蒙层，拖拽选区，mouseDown/Dragged/Up，ESC取消
└── RecordingAreaOverlay.swift       # 录制中虚线边框叠加层，sharingType=.none 排除录制
```

### 数据流

**全局系统声音模式（globalSystem）**：
```
SCStream ── .screen ──→ CMSampleBuffer ──→ MovieFileWriter (video track)
         ── .audio ──→ CMSampleBuffer ──→ MovieFileWriter (systemAudio track)
         ── .mic   ──→ CMSampleBuffer ──→ MovieFileWriter (microphone track)
```

**指定应用声音模式（selectedApplication）**：
```
SCStream ── .screen ──→ CMSampleBuffer ──→ MovieFileWriter (video track)
         ── .mic   ──→ CMSampleBuffer ──→ MovieFileWriter (microphone track)
ProcessTapAudioCapture ──→ CMSampleBuffer ──→ MovieFileWriter (systemAudio track)
```

- 全局模式：SCStream 三轨独立采集，双 AAC 独立编码
- 指定应用模式：SCStream 负责画面+麦克风，ProcessTapAudioCapture（Core Audio Process Tap）单独捕获指定应用音频
- 两路音频各自独立 AAC 编码，AVAssetWriter 自动同步，不做任何混合

### 录制模式

- **全屏**: `configuration.width/height = mode.pixelWidth/pixelHeight`（CGDisplayCopyDisplayMode 取物理像素）
- **区域**: `configuration.sourceRect` (Quartz 坐标) + `configuration.width/height = 裁剪后像素尺寸`
- **声音**: 全局系统声音 (SCStream `.audio`) / 指定应用声音 (ProcessTapAudioCapture)
- **麦克风**: 开关控制，SCStream `.microphone` 独立轨道

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
- SCStream 像素格式: `kCVPixelFormatType_32BGRA`（保留原始 full range 数据）
- VTPixelTransferSession: Display P3 → Rec.709 色彩空间转换（macOS 屏幕原生 P3 广色域，视频标准用 Rec.709）
- 编码器输出: BGRA + Rec.709 色彩属性 + full range 元数据
- `scalesToFit = false`（不做内部缩放）
- HEVC vs H.264 码率阶梯（按像素数分档），B-frames 开启
- 双 AAC 音频轨道：系统音频 192kbps / 麦克风 128kbps

### 7. 录制区域虚线框
- 颜色: #CACACA
- 排除录制: `window.sharingType = .none`

### 8. 浏览器多进程音频发现
Chrome/Edge 等浏览器将音频放在子进程中，Safari 的 WebKit.GPU 是 XPC 服务（不在主应用 bundle 内）。
`AudioProcessDiscovery.discoverAudioPIDs(forApplicationPID:)` 先用 bundle 路径前缀匹配（Chrome 类），再用进程名模糊匹配（Safari 类）。

### 9. 三轨分离架构（v2.6.0）
**背景**: 之前使用 AudioMixer 手动混合系统音频和麦克风到单条音轨，导致格式描述不一致、AAC 编码器状态重置、混合时失真（闷音）。尝试过 AVAudioEngine 混音方案，但 `engine.connect()` 在格式不兼容时抛出无法被 Swift 捕获的 NSException。

**方案**: 彻底移除手动混音，使用 SCStream 原生三轨输出（`.screen`/`.audio`/`.microphone`），MovieFileWriter 支持双音频轨道，各自独立 AAC 编码。

**注意**: `captureMicrophone` 和 `.microphone` 输出类型需要 macOS 15.0+。

### 10. 色彩管线（防泛白）
**问题**: 之前录制画面泛白、颜色不鲜艳，两个原因：
1. 编码器默认 limited range（Y=16-235），屏幕数据是 full range（0-255），直接喂给编码器导致对比度降低
2. macOS 屏幕是 Display P3 广色域，视频标准是 Rec.709，不转换导致饱和度不足

**方案**:
- SCStream 输出 BGRA（保留原始 full range）
- `VTPixelTransferSession` 做 Display P3 → Rec.709 色彩空间转换
- 编码器输出 full range + Rec.709 色彩元数据

### 11. 麦克风回声问题
录制时如果同时用扬声器播放系统声音，麦克风会录到扬声器输出的声音，造成回声。

## 版本

- **v2.0**: 系统音频录制功能（ProcessTapAudioCapture）
- **v2.1**: 区域录制、HEVC 编码、浏览器音频发现、崩溃修复
- **v2.2**: 麦克风混音录制（AudioMixer），支持系统音频+麦克风混合输出
- **v2.3**: UI 重新设计，Modern 风格，毛玻璃背景，图标化分区，窗口可调大小
- **v2.4**: UI 继续优化 — hero 控制栏、玻璃面板、新布局
- **v2.5**: 修复混音采样率对齐误差 + 麦克风单独录制崩溃问题
- **v2.5.1**: 修复混音循环内采样率转换误差 — 改用简单递增索引
- **v2.5.2**: 修复混音增益过高导致系统音频压制麦克风 — 改用加法混合替代 tanhf
- **v2.5.4**: 修复声道选择 + 格式统一 + 削波限幅（混音失真仍未解决）
- **v2.6.0**: **三轨分离架构** — 彻底移除手动混音，SCStream 三轨独立采集+独立编码
  - 删除 AudioEngineMixer.swift、AudioMixer.swift、ProcessTapAudioCapture.swift
  - MovieFileWriter 支持双 AAC 音频轨道
  - 最低系统要求提升至 macOS 15.0
- **v2.6.1** (当前): **色彩管线 + 指定应用声音修复 + UI 微调**
  - 修复录屏画面泛白：BGRA full range + VTPixelTransferSession Display P3 → Rec.709
  - 恢复 ProcessTapAudioCapture：指定应用声音模式用 Core Audio Process Tap 单独捕获
  - UI：圆角统一、编码/存储面板等高、录制按钮计时胶囊动画
  - 删除麦克风回声提示
