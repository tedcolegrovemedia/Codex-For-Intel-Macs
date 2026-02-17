#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CodexIntelApp"
PRODUCT_NAME="$APP_NAME"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
PLIST_PATH="$APP_DIR/Contents/Info.plist"
BIN_PATH="$ROOT_DIR/.build/release/$PRODUCT_NAME"
ICON_SOURCE="$ROOT_DIR/Assets/CodexIntel.icns"
ICON_NAME="CodexIntel.icns"

cd "$ROOT_DIR"

echo "Building release binary..."
swift build -c release --product "$PRODUCT_NAME"

if [[ ! -f "$BIN_PATH" ]]; then
  echo "Error: expected binary not found at $BIN_PATH" >&2
  exit 1
fi

echo "Creating app bundle at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$BIN_DIR" "$RES_DIR"
cp "$BIN_PATH" "$BIN_DIR/$APP_NAME"

if [[ -f "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$RES_DIR/$ICON_NAME"
fi

cat > "$PLIST_PATH" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>CodexIntelApp</string>
  <key>CFBundleDisplayName</key>
  <string>CodexIntelApp</string>
  <key>CFBundleIdentifier</key>
  <string>com.local.codexintelapp</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleExecutable</key>
  <string>CodexIntelApp</string>
  <key>CFBundleIconFile</key>
  <string>CodexIntel.icns</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  echo "Applying ad-hoc code signature..."
  codesign --force --deep --sign - "$APP_DIR"
fi

echo "Done."
echo "App bundle: $APP_DIR"
echo "Launch with: open \"$APP_DIR\""
