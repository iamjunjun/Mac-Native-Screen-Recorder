#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/Build/NativeScreenRecorder.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

cd "$ROOT_DIR"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift build

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$ROOT_DIR/.build/debug/NativeScreenRecorder" "$MACOS_DIR/NativeScreenRecorder"
cp "$ROOT_DIR/App/Info.plist" "$CONTENTS_DIR/Info.plist"
mkdir -p "$CONTENTS_DIR/Resources"
cp "$ROOT_DIR/App/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
chmod +x "$MACOS_DIR/NativeScreenRecorder"

xattr -cr "$APP_DIR" 2>/dev/null || true
codesign --deep --sign - "$APP_DIR" 2>/dev/null || true

echo "$APP_DIR"
