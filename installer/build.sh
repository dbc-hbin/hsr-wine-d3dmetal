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
    -framework JavaScriptCore \
    -o "$OUTPUT_BIN" \
    RuntimePackage.swift \
    AsarPatcher.swift \
    InstallerEngine.swift \
    ContentView.swift \
    main.swift

echo "==> Packaging into ${APP_NAME}..."
rm -rf "$APP_NAME"
mkdir -p "$APP_NAME/Contents/MacOS"
mkdir -p "$APP_NAME/Contents/Resources"

cp "$OUTPUT_BIN" "$APP_NAME/Contents/MacOS/$OUTPUT_BIN"

for resource in typescript.js AsarTransform.js TypeScript-LICENSE.txt TypeScript-ThirdPartyNotice.txt; do
    source="$DIR/resources/$resource"
    if [ ! -f "$source" ]; then
        echo "Missing bundled installer resource: $source" >&2
        exit 1
    fi
    cp "$source" "$APP_NAME/Contents/Resources/$resource"
done

RUNTIME_ARCHIVE="Wine 11.17 ZZZ DX12 (GPTK4.0b2).tar.xz"
LOCAL_RUNTIME_SOURCE="$HOME/Library/Application Support/Yaagl ZZZ OS/local-runtimes/$RUNTIME_ARCHIVE"
if [ -f "$LOCAL_RUNTIME_SOURCE" ]; then
    echo "==> Bundling runtime archive into App Resources (standalone installer)..."
    cp "$LOCAL_RUNTIME_SOURCE" "$APP_NAME/Contents/Resources/$RUNTIME_ARCHIVE"
else
    LEGACY_SOURCE="$HOME/Library/Application Support/Yaagl ZZZ OS/local-runtimes/wine-11.17-git.913e31f-zzz-dx12-tuned-d3dmetal-cache-warmup-cursor-rollback-gptk4b2.tar.xz"
    if [ -f "$LEGACY_SOURCE" ]; then
        echo "==> Bundling legacy runtime archive as $RUNTIME_ARCHIVE into App Resources..."
        cp "$LEGACY_SOURCE" "$APP_NAME/Contents/Resources/$RUNTIME_ARCHIVE"
    fi
fi

if [ -d "$DIR/../external/D3DMetal.framework" ]; then
    echo "==> Bundling D3DMetal.framework into App Resources..."
    ditto "$DIR/../external/D3DMetal.framework" "$APP_NAME/Contents/Resources/D3DMetal.framework"
fi

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
    <string>1.0.1</string>
    <key>CFBundleVersion</key>
    <string>1.0.1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_NAME"

echo "==> Build complete: $APP_NAME and $OUTPUT_BIN"
