#!/bin/bash
# Builds "build/Claude Usage Bar.app". `./build.sh install` also copies it to /Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/ClaudeUsageBar"

APP="build/Claude Usage Bar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeUsageBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    pkill -x ClaudeUsageBar && while pgrep -x ClaudeUsageBar >/dev/null; do sleep 0.2; done || true
    rm -rf "/Applications/Claude Usage Bar.app"
    cp -R "$APP" /Applications/
    open "/Applications/Claude Usage Bar.app"
    echo "Installed and launched /Applications/Claude Usage Bar.app"
fi
