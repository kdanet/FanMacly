#!/bin/bash
set -euo pipefail
app="$1"
binary_dir="$2"
sdk_path="$3"
identity="$4"
configuration="$5"
case "$configuration" in release) xcode_configuration=Release ;; debug) xcode_configuration=Debug ;; *) exit 1 ;; esac
controls="$app/Contents/PlugIns/FanMaclyControls.appex"
metadata="$PWD/build/control-metadata"
mkdir -p "$controls/Contents/MacOS" "$controls/Contents/Resources" "$metadata"
short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
if ! xcodebuild -project FanMaclyControls.xcodeproj -scheme FanMaclyControls \
    -configuration "$xcode_configuration" -derivedDataPath "$PWD/build/ControlsDerivedData" \
    CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES SDKROOT="$sdk_path" \
    MARKETING_VERSION="$short_version" CURRENT_PROJECT_VERSION="$build_version" build \
    > "$metadata/xcodebuild.log" 2>&1; then
    tail -70 "$metadata/xcodebuild.log"
    exit 1
fi
derived="$PWD/build/ControlsDerivedData/Build/Products/$xcode_configuration/FanMaclyControls.appex"
ditto "$derived" "$controls"

python3 - "$metadata" "$configuration" <<'PY'
from pathlib import Path
import sys
root = Path.cwd()
output = Path(sys.argv[1])
configuration = sys.argv[2].capitalize()
sources = sorted((root / 'Sources/FanMacly').glob('*.swift'))
(output / 'app-sources.txt').write_text(''.join(f'{p}\n' for p in sources))
constants = [p.resolve() for p in (root / '.build').rglob('FanMacly-primary.swiftconstvalues') if f'/{configuration}/' in str(p)]
if not constants:
    raise SystemExit('Missing main-app App Intents constant metadata')
(output / 'app-constants.txt').write_text(''.join(f'{p}\n' for p in constants))
PY
toolchain_dir="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
xcode_version="$(xcodebuild -version | tail -1 | awk '{print $3}')"
module=FanMacly
output="$app/Contents/Resources"
deployment=14.0
target=app
    xcrun appintentsmetadataprocessor --output "$output" --module-name "$module" \
        --toolchain-dir "$toolchain_dir" --sdk-root "$sdk_path" \
        --xcode-version "$xcode_version" --platform-family macOS \
        --deployment-target "$deployment" --target-triple "arm64-apple-macos$deployment" \
        --source-file-list "$metadata/$target-sources.txt" \
        --swift-const-vals-list "$metadata/$target-constants.txt" --deployment-aware-processing
entitlements=Resources/FanMaclyControls.entitlements
if [ -n "${APP_GROUP:-}" ]; then
    /usr/libexec/PlistBuddy -c "Add :FanMaclyAppGroup string $APP_GROUP" "$controls/Contents/Info.plist"
    entitlements="$PWD/build/FanMaclyControls.entitlements"
    cat > "$entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.application-groups</key><array><string>$APP_GROUP</string></array>
</dict></plist>
PLIST
fi
if [ "$identity" = - ]; then
    codesign --force --sign - --entitlements "$entitlements" "$controls"
else
    codesign --force --options runtime --timestamp --sign "$identity" \
        --entitlements "$entitlements" "$controls"
fi
