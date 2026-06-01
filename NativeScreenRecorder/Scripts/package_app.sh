#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/arm64-apple-macosx/release"
OUTPUT_DIR="$ROOT_DIR/Build"
VERSION=$(grep -A1 'CFBundleShortVersionString' "$ROOT_DIR/App/Info.plist" | grep string | sed 's/.*<string>\(.*\)<\/string>/\1/')

cd "$ROOT_DIR"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

package_app() {
    local lang="$1"
    local suffix="$2"
    local app_dir="$OUTPUT_DIR/NativeScreenRecorder_v${VERSION}_${suffix}.app"
    local contents="$app_dir/Contents"

    mkdir -p "$contents/MacOS" "$contents/Resources"
    cp "$BUILD_DIR/NativeScreenRecorder" "$contents/MacOS/"
    cp "$ROOT_DIR/App/Info.plist" "$contents/"
    cp "$ROOT_DIR/App/AppIcon.icns" "$contents/Resources/"
    chmod +x "$contents/MacOS/NativeScreenRecorder"
    xattr -cr "$app_dir" 2>/dev/null || true
    codesign --deep --sign - "$app_dir" 2>/dev/null || true
    echo "$app_dir"
}

echo "Building Chinese version..."
swift build -c release
package_app "zh" "中文"

echo "Building English version..."
swift build -c release -Xswiftc -DENGLISH
package_app "en" "English"

echo ""
echo "Done! Output:"
ls -d "$OUTPUT_DIR"/*.app
