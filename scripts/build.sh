#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${CONFIGURATION:-release}"
identity="${SIGN_IDENTITY:--}"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
# Swift Build can otherwise record the deployment target as the linked SDK,
# which opts AppKit/SwiftUI into old control appearance despite new headers.
swift build -c "$configuration" --sdk "$sdk_path" \
    -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$sdk_version"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app="$PWD/build/FanMacly.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Library/LaunchDaemons"
cp "$binary_dir/FanMacly" "$app/Contents/MacOS/FanMacly"
cp "$binary_dir/FanMaclyHelper" "$app/Contents/MacOS/FanMaclyHelper"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/app.fanmacly.helper.plist "$app/Contents/Library/LaunchDaemons/"
swift scripts/make-icon.swift "$PWD/build"
iconutil -c icns "$PWD/build/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
# Signed builds share a small status file with the desktop widget through an
# App Group prefixed with the signing team ID. Ad-hoc builds skip it.
team="$(printf '%s' "$identity" | sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p')"
app_entitlements=""
if [ -n "$team" ]; then
    group="$team.app.fanmacly"
    /usr/libexec/PlistBuddy -c "Add :FanMaclyAppGroup string $group" "$app/Contents/Info.plist"
    app_entitlements="$PWD/build/FanMacly.entitlements"
    cat > "$app_entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>com.apple.security.application-groups</key><array><string>$group</string></array>
</dict></plist>
PLIST
fi
APP_GROUP="${group:-}" bash scripts/build-controls.sh "$app" "$binary_dir" "$sdk_path" "$identity" "$configuration"

if [ "$identity" = "-" ]; then
    codesign --force --sign - --identifier app.fanmacly.helper "$app/Contents/MacOS/FanMaclyHelper"
    codesign --force --sign - --identifier app.fanmacly "$app"
    printf '\nBuilt %s\nAd-hoc build: monitoring works; helper requires an Apple signing identity.\n' "$app"
else
    codesign --force --options runtime --timestamp --sign "$identity" --identifier app.fanmacly.helper "$app/Contents/MacOS/FanMaclyHelper"
    codesign --force --options runtime --timestamp --sign "$identity" --identifier app.fanmacly \
        ${app_entitlements:+--entitlements "$app_entitlements"} "$app"
    printf '\nBuilt and signed %s\n' "$app"
fi
codesign --verify --deep --strict "$app"
