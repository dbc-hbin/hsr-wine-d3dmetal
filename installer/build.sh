#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

RUNTIME_ARCHIVE="wine-11.17-hsr-gptk4b2-stock.tar.xz"
RUNTIME_ARCHIVE_SOURCE="${RUNTIME_ARCHIVE_SOURCE:-$DIR/../build/hsr-runtime/$RUNTIME_ARCHIVE}"
if [ ! -f "$RUNTIME_ARCHIVE_SOURCE" ]; then
    echo "Missing macOS 26 runtime archive: $RUNTIME_ARCHIVE_SOURCE" >&2
    exit 1
fi
/usr/bin/python3 "$DIR/../scripts/validate-runtime-deployment-target.py" "$RUNTIME_ARCHIVE_SOURCE" --maximum 26.0

ARCHIVE_SHA256="$(/usr/bin/shasum -a 256 "$RUNTIME_ARCHIVE_SOURCE" | /usr/bin/cut -d ' ' -f 1)"
GENERATED_RUNTIME_PACKAGE="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/hsr-runtime-package.XXXXXX.swift")"
trap 'rm -f "$GENERATED_RUNTIME_PACKAGE"' EXIT
/usr/bin/sed "s/public static let archiveSHA256 = \"[0-9a-f]*\"/public static let archiveSHA256 = \"$ARCHIVE_SHA256\"/" RuntimePackage.swift > "$GENERATED_RUNTIME_PACKAGE"

echo "==> Compiling Swift installer..."
ARCH="$(uname -m)"
OUTPUT_BIN="hsr-wine-installer"
APP_NAME="HSR Wine D3DMetal Installer.app"

swiftc -O \
    -target "${ARCH}-apple-macos26.0" \
    -framework SwiftUI \
    -framework AppKit \
    -framework CryptoKit \
    -framework JavaScriptCore \
    -o "$OUTPUT_BIN" \
    "$GENERATED_RUNTIME_PACKAGE" \
    AsarPatcher.swift \
    ResourceRegistration.swift \
    InstallerEngine.swift \
    ContentView.swift \
    main.swift

echo "==> Compiling update registration helper..."
swiftc -O -parse-as-library \
    -target "${ARCH}-apple-macos26.0" \
    -framework CryptoKit -framework JavaScriptCore \
    -o hsr-wine-register \
    "$GENERATED_RUNTIME_PACKAGE" AsarPatcher.swift ResourceRegistration.swift RegistrationMain.swift
codesign --force --sign - hsr-wine-register

echo "==> Packaging into ${APP_NAME}..."
rm -rf "$APP_NAME"
mkdir -p "$APP_NAME/Contents/MacOS"
mkdir -p "$APP_NAME/Contents/Resources"

cp "$OUTPUT_BIN" "$APP_NAME/Contents/MacOS/$OUTPUT_BIN"
cp hsr-wine-register "$APP_NAME/Contents/Resources/hsr-wine-register"

for resource in typescript.js AsarTransform.js TypeScript-LICENSE.txt TypeScript-ThirdPartyNotice.txt; do
    source="$DIR/resources/$resource"
    if [ ! -f "$source" ]; then
        echo "Missing bundled installer resource: $source" >&2
        exit 1
    fi
    cp "$source" "$APP_NAME/Contents/Resources/$resource"
done

echo "==> Bundling macOS 26 runtime archive into App Resources..."
cp "$RUNTIME_ARCHIVE_SOURCE" "$APP_NAME/Contents/Resources/$RUNTIME_ARCHIVE"

cat << 'PLIST' > "$APP_NAME/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ko</string>
    <key>CFBundleExecutable</key>
    <string>hsr-wine-installer</string>
    <key>CFBundleIdentifier</key>
    <string>com.hanbinnoh.hsr-wine-installer</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>HSR Wine D3DMetal Installer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.1</string>
    <key>CFBundleVersion</key>
    <string>1.0.1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_NAME"

echo "==> Build complete: $APP_NAME and $OUTPUT_BIN"
