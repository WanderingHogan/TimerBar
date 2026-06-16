#!/bin/bash
set -e

APP_NAME="TimerBar"
DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$DIR/build"
APP="$BUILD/$APP_NAME.app"
MACOS="$APP/Contents/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS"

echo "Compiling..."
swiftc -O -o "$MACOS/$APP_NAME" "$DIR"/Sources/*.swift -framework Cocoa

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>      <string>com.local.timerbar</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>11.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
EOF

# Ad-hoc code signature. Notification authorization (UserNotifications) is
# unreliable for unsigned bundles; an ad-hoc signature with a stable bundle id
# is enough for local use.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warning: codesign failed (notifications may not work)"

echo "Built: $APP"
echo "Run with:  open \"$APP\"    (or)    \"$MACOS/$APP_NAME\""
