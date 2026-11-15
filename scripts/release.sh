#!/bin/bash
# Build, notarize and package a release: build/release/FanMacly.zip (+ .sha256).
#   SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' bash scripts/release.sh
# Notarization uses a notarytool keychain profile (default name "FanMacly").
# Store it once:
#   xcrun notarytool store-credentials FanMacly --apple-id YOU@EXAMPLE.COM --team-id TEAMID
# (it asks for an app-specific password from account.apple.com).
set -euo pipefail
cd "$(dirname "$0")/.."

identity="${SIGN_IDENTITY:-}"
profile="${NOTARY_PROFILE:-FanMacly}"
case "$identity" in
    "Developer ID Application:"*) ;;
    *) echo "Set SIGN_IDENTITY to a 'Developer ID Application: …' identity; only those can be notarized." >&2; exit 1 ;;
esac
if [ -n "$(git status --porcelain)" ]; then
    echo "The working tree has uncommitted changes; a release must match a commit." >&2
    exit 1
fi
xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 || {
    echo "No notarytool profile '$profile'. Store it with: xcrun notarytool store-credentials $profile --apple-id … --team-id …" >&2
    exit 1
}

bash scripts/check.sh
SIGN_IDENTITY="$identity" bash scripts/build.sh
app="$PWD/build/FanMacly.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
out="$PWD/build/release"
rm -rf "$out" && mkdir -p "$out"

echo "Notarizing FanMacly $version ($build)…"
ditto -c -k --keepParent "$app" "$out/notarize.zip"
result="$(xcrun notarytool submit "$out/notarize.zip" --keychain-profile "$profile" --wait --timeout 30m --output-format json)"
rm -f "$out/notarize.zip"
id="$(plutil -extract id raw - <<<"$result")"
status="$(plutil -extract status raw - <<<"$result")"
if [ "$status" != "Accepted" ]; then
    echo "Notarization $status (submission $id). Log:" >&2
    xcrun notarytool log "$id" --keychain-profile "$profile" >&2 || true
    exit 1
fi
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute -vv "$app" 2>&1 | tee "$out/gatekeeper.txt"
grep -q "source=Notarized Developer ID" "$out/gatekeeper.txt" || { echo "Gatekeeper did not accept the stapled app." >&2; exit 1; }
rm "$out/gatekeeper.txt"

# The asset name is stable so releases/latest/download/FanMacly.zip always works.
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/FanMacly.zip"
(cd "$out" && shasum -a 256 FanMacly.zip > FanMacly.zip.sha256)
echo "FanMacly $version ($build), commit $(git rev-parse --short HEAD), notarization $id"
echo "$out/FanMacly.zip"
cat "$out/FanMacly.zip.sha256"
