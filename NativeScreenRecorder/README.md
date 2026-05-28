# Native Screen Recorder

一个原生 macOS 录屏实验项目。目标是不用 BlackHole 这类虚拟声卡，也不切换系统输出设备，直接通过 Apple 的屏幕与音频捕获 API 录制：

- 全局系统声音
- 指定应用程序的声音
- 当前显示器画面

## 技术路线

- `ScreenCaptureKit` 负责屏幕帧和系统音频采集。
- `SCContentFilter` 在指定应用模式下只包含某个应用的窗口。
- `AVAssetWriter` 把屏幕帧和音频样本合成 MP4。

这条路线不会把系统输出切到虚拟设备，所以录制时不会影响你当前使用的扬声器、耳机或系统音量路径。

## 运行

当前机器只有 Command Line Tools，不能直接用 `xcodebuild` 构建 `.app`。安装完整 Xcode 后，可以直接用 Xcode 打开这个文件夹里的 `Package.swift`，选择 `NativeScreenRecorder` 运行。

首次运行时，macOS 会要求授予屏幕录制权限。系统音频捕获也可能触发隐私授权提示。

## 现状

这是第一版可运行架构：

- 已有 SwiftUI 界面。
- 已有显示器和应用枚举。
- 已有全局/指定应用两种录制模式。
- 已有 MP4 写入模块。

下一步建议把指定应用声音从 `SCContentFilter` 模式升级为 Core Audio Process Tap，这样可以做到“只取某个进程音频，同时画面仍可录整个屏幕”的更细粒度模式。
