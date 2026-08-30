#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="iConsole FTMS"
BUILD_DIR="$ROOT_DIR/dist"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BRIDGE_BIN="$RESOURCES_DIR/iconsole_ftms"
LAUNCHER_BIN="$MACOS_DIR/iconsole-ftms-launcher"
LAUNCHER_SRC="$ROOT_DIR/macos_app/iconsole_macos_launcher.swift"
ICON_GEN_SRC="$ROOT_DIR/macos_app/generate_app_icon.swift"
ICON_MASTER_PNG="$BUILD_DIR/AppIcon-1024.png"
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
ICON_ICNS="$RESOURCES_DIR/AppIcon.icns"
VERSION_FILE="$ROOT_DIR/VERSION"

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [version]"
  exit 2
fi

if [[ $# -eq 1 ]]; then
  APP_VERSION="$1"
elif [[ -n "${ICONSOLE_APP_VERSION:-}" ]]; then
  APP_VERSION="$ICONSOLE_APP_VERSION"
elif [[ -f "$VERSION_FILE" ]]; then
  APP_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
else
  APP_VERSION="dev"
fi

if [[ -z "$APP_VERSION" ]]; then
  echo "App version cannot be empty"
  exit 2
fi
BRIDGE_SOURCES=(
  "$ROOT_DIR/iconsole_ftms.swift"
  "$ROOT_DIR/iconsole_ftms_config.swift"
  "$ROOT_DIR/iconsole_ftms_ftms.swift"
  "$ROOT_DIR/iconsole_ftms_rfcomm.swift"
  "$ROOT_DIR/iconsole_ftms_telemetry.swift"
  "$ROOT_DIR/iconsole_ftms_web.swift"
)

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

echo "Building Swift bridge binary..."
swiftc "${BRIDGE_SOURCES[@]}" -o "$BRIDGE_BIN"

echo "Building native macOS launcher..."
swiftc -parse-as-library "$LAUNCHER_SRC" -framework Cocoa -framework WebKit -o "$LAUNCHER_BIN"

echo "Generating app icon..."
swift "$ICON_GEN_SRC" "$ICON_MASTER_PNG"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
sips -z 16 16 "$ICON_MASTER_PNG" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_MASTER_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_MASTER_PNG" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_MASTER_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_MASTER_PNG" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_MASTER_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_MASTER_PNG" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_MASTER_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_MASTER_PNG" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
cp "$ICON_MASTER_PNG" "$ICONSET_DIR/icon_512x512@2x.png"
iconutil -c icns "$ICONSET_DIR" -o "$ICON_ICNS"
rm -rf "$ICONSET_DIR" "$ICON_MASTER_PNG"
printf "%s\n" "$APP_VERSION" > "$RESOURCES_DIR/APP_VERSION"

echo "Creating .app bundle..."

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>iConsole FTMS</string>
    <key>CFBundleDisplayName</key>
    <string>iConsole FTMS</string>
    <key>CFBundleIdentifier</key>
    <string>com.iconsole.ftms.bridge</string>
    <key>CFBundleVersion</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>iconsole-ftms-launcher</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>iConsole FTMS uses Bluetooth to connect to your bike and broadcast FTMS data.</string>
    <key>NSBluetoothPeripheralUsageDescription</key>
    <string>iConsole FTMS uses Bluetooth to connect to your bike and broadcast FTMS data.</string>
</dict>
</plist>
PLIST

chmod +x "$LAUNCHER_BIN" "$BRIDGE_BIN"

echo "Signing app bundle..."
codesign --force --deep --sign - --timestamp=none "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo
echo "Done:"
echo "  $APP_DIR"
echo
echo "Double-click the app to start bridge + open native window."
echo "Logs:"
echo "  $HOME/Library/Logs/iConsoleFTMS/bridge.log"
