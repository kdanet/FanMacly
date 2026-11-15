#!/bin/bash
# Run an isolated preview copy (own bundle ID and preferences, no helper) to
# look at the UI without touching an installed FanMacly.
#   bash scripts/preview.sh [--panel-window] [--open-window=profiles|monitor|settings]
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product FanMacly >/dev/null
dir="${TMPDIR:-/tmp}/fanmacly-preview"
app="$dir/FanMaclyPreview.app"
rm -rf "$dir" && mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/FanMacly" "$app/Contents/MacOS/FanMacly"
cp Resources/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.fanmacly.preview" "$app/Contents/Info.plist"
codesign --force --sign - "$app" >/dev/null 2>&1
pkill -f FanMaclyPreview.app || true
open -n "$app" --args "$@"
echo "$app"
