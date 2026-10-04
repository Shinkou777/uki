#!/bin/bash
# Compile uki.swift, generate icon, assemble Uki.app.
# Output: /Applications/Uki.app by default. Set UKI_APP_DIR (must end in .app)
# to build somewhere else, e.g. UKI_APP_DIR="$PWD/build/Uki.app" for a local
# test build that leaves /Applications alone.
set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Uki"
APP_DIR="${UKI_APP_DIR:-/Applications/$APP_NAME.app}"
case "$APP_DIR" in
  *.app) ;;
  *) echo "UKI_APP_DIR must end in .app (got: $APP_DIR)" >&2; exit 1 ;;
esac
BIN="$APP_DIR/Contents/MacOS/$APP_NAME"
BUNDLE_ID="${UKI_BUNDLE_ID:-com.shinkouniv.uki}"
# Version resolution: explicit env > CI tag (GITHUB_REF_NAME on tag push) > fallback
VERSION="${UKI_VERSION:-${GITHUB_REF_NAME:-0.1.1}}"
VERSION="${VERSION#v}"  # strip leading v if any

echo "[1/4] compiling uki.swift ..."
cd "$REPO/src"
/usr/bin/swiftc -O uki.swift -o /tmp/uki-bin

echo "[2/4] generating AppIcon.icns ..."
swift make-icon.swift >/dev/null
iconutil -c icns /tmp/AppIcon.iconset -o /tmp/AppIcon.icns

echo "[3/4] assembling $APP_NAME.app ..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/Fonts"
cp /tmp/uki-bin "$BIN"
cp /tmp/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$REPO/src/fonts/"*.ttf "$APP_DIR/Contents/Resources/Fonts/"

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>            <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>                  <string>Uki</string>
    <key>CFBundleDisplayName</key>           <string>浮子</string>
    <key>CFBundleVersion</key>               <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>        <string>13.0</string>
    <key>LSUIElement</key>                   <true/>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>ATSApplicationFontsPath</key>       <string>Fonts/</string>
</dict>
</plist>
EOF

echo "[4/4] done."
echo "  App: $APP_DIR"
echo "  Run: open '$APP_DIR'"
