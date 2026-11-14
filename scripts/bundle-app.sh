#!/bin/sh
# Builds ThermacBar.app into dist/ and ad-hoc signs it.
# The app embeds the recorder (Contents/MacOS/thermac) and its login agent
# (Contents/Library/LaunchAgents/com.thermac.bar.recorder.plist), which the app
# registers with SMAppService — installing the app is the only setup step.
# Usage: scripts/bundle-app.sh [--install]   (--install moves it to ~/Applications)
set -eu
cd "$(dirname "$0")/.."
VERSION="0.2.0"
BUILD="$(date +%Y%m%d%H%M)"

swift build -c release --product ThermacBar
swift build -c release --product thermac
BIN="$(swift build -c release --show-bin-path)"
APP=dist/ThermacBar.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents"
cp "$BIN/ThermacBar" "$APP/Contents/MacOS/ThermacBar"
cp "$BIN/thermac" "$APP/Contents/MacOS/thermac"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>        <string>com.thermac.bar</string>
    <key>CFBundleName</key>              <string>thermac</string>
    <key>CFBundleDisplayName</key>       <string>thermac</string>
    <key>CFBundleExecutable</key>        <string>ThermacBar</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$BUILD</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHumanReadableCopyright</key>  <string>© thermac contributors</string>
</dict>
</plist>
PLIST

cat > "$APP/Contents/Library/LaunchAgents/com.thermac.bar.recorder.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>                     <string>com.thermac.bar.recorder</string>
    <key>BundleProgram</key>             <string>Contents/MacOS/thermac</string>
    <key>ProgramArguments</key>
    <array><string>thermac</string><string>record</string><string>-i</string><string>5</string></array>
    <key>AssociatedBundleIdentifiers</key><array><string>com.thermac.bar</string></array>
    <key>RunAtLoad</key>                 <true/>
    <key>KeepAlive</key>                 <true/>
    <key>ProcessType</key>               <string>Background</string>
    <key>Nice</key>                      <integer>10</integer>
    <key>LowPriorityIO</key>             <true/>
</dict>
</plist>
PLIST

# Sign inside-out: the embedded recorder first, then the app.
codesign --force --sign - "$APP/Contents/MacOS/thermac"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "built $APP ($VERSION, build $BUILD)"

if [ "${1:-}" = "--install" ]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/ThermacBar.app"
    # Move, not copy: a second identical app in dist/ would show up in Spotlight/Launchpad.
    mv "$APP" "$HOME/Applications/"
    echo "installed ~/Applications/ThermacBar.app"
fi
