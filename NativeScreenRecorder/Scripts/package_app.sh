#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/arm64-apple-macosx/release"
OUTPUT_DIR="$ROOT_DIR/Build"
VERSION=$(grep -A1 'CFBundleShortVersionString' "$ROOT_DIR/App/Info.plist" | grep string | sed 's/.*<string>\(.*\)<\/string>/\1/')

cd "$ROOT_DIR"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

echo "Building..."
swift build -c release

app_dir="$OUTPUT_DIR/NativeScreenRecorder_v${VERSION}.app"
contents="$app_dir/Contents"

mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$BUILD_DIR/NativeScreenRecorder" "$contents/MacOS/"
cp "$ROOT_DIR/App/Info.plist" "$contents/"
cp "$ROOT_DIR/App/AppIcon.icns" "$contents/Resources/"

# 复制本地化资源到 app bundle
if [ -d "$BUILD_DIR/NativeScreenRecorder_NativeScreenRecorder.bundle" ]; then
    cp -R "$BUILD_DIR/NativeScreenRecorder_NativeScreenRecorder.bundle" "$contents/Resources/"
fi

chmod +x "$contents/MacOS/NativeScreenRecorder"
xattr -cr "$app_dir" 2>/dev/null || true
codesign --deep --sign - "$app_dir" 2>/dev/null || true

echo ""
echo "Done! Output:"
echo "$app_dir"
