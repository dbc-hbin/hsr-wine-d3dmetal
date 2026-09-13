#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

echo "==> Compiling Swift installer..."
ARCH="$(uname -m)"
OUTPUT_BIN="zzz-wine-installer"
APP_NAME="ZZZ Wine DX12 Installer.app"

swiftc -O \
    -target "${ARCH}-apple-macos14.0" \
    -framework SwiftUI \
    -framework AppKit \
    -framework CryptoKit \
    -o "$OUTPUT_BIN" \
    AsarPatcher.swift \
    InstallerEngine.swift \
    ContentView.swift \
    main.swift

echo "==> Packaging into ${APP_NAME}..."
rm -rf "$APP_NAME"
mkdir -p "$APP_NAME/Contents/MacOS"
mkdir -p "$APP_NAME/Contents/Resources"

cp "$OUTPUT_BIN" "$APP_NAME/Contents/MacOS/$OUTPUT_BIN"

cat << 'PLIST' > "$APP_NAME/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ko</string>
    <key>CFBundleExecutable</key>
    <string>zzz-wine-installer</string>
    <key>CFBundleIdentifier</key>
    <string>com.hanbinnoh.zzz-wine-installer</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>ZZZ Wine DX12 Installer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_NAME"

echo "==> Build complete: $APP_NAME and $OUTPUT_BIN"
