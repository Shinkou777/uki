#!/bin/bash
# Compile floater.swift, generate icon, assemble ClaudeFloater.app.
# Output: /Applications/ClaudeFloater.app
set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ClaudeFloater"
APP_DIR="/Applications/$APP_NAME.app"
BIN="$APP_DIR/Contents/MacOS/$APP_NAME"
BUNDLE_ID="${CLAUDE_FLOATER_BUNDLE_ID:-dev.eva.claudefloater}"

echo "[1/4] compiling floater.swift ..."
cd "$REPO/src"
/usr/bin/swiftc -O floater.swift -o /tmp/claude-floater-bin

echo "[2/4] generating AppIcon.icns ..."
swift make-icon.swift >/dev/null
iconutil -c icns /tmp/AppIcon.iconset -o /tmp/AppIcon.icns

echo "[3/4] assembling $APP_NAME.app ..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp /tmp/claude-floater-bin "$BIN"
cp /tmp/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>            <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>                  <string>Claude Floater</string>
    <key>CFBundleDisplayName</key>           <string>クロード稼働率</string>
    <key>CFBundleVersion</key>               <string>1.0</string>
    <key>CFBundleShortVersionString</key>    <string>1.0</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>        <string>13.0</string>
    <key>LSUIElement</key>                   <true/>
    <key>NSHighResolutionCapable</key>       <true/>
</dict>
</plist>
EOF

echo "[4/4] done."
echo "  App: $APP_DIR"
echo "  Run: open '$APP_DIR'"
