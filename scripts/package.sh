#!/bin/bash
# Installers without a paid Apple developer account:
#   Qwovi-<version>.dmg  the Mac app, ad-hoc signed, universal (Apple silicon + Intel), drag to Applications
#   Qwovi-<version>.ipa  the iPhone app, unsigned: Sideloadly / AltStore sign it with the user's own Apple ID
# Needs Xcode and xcodegen. Usage: scripts/package.sh [version] [out-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:-1.1.0}
mkdir -p "${2:-dist}"
OUT=$(cd "${2:-dist}" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

xcodegen generate >/dev/null
build() { # build <scheme> <destination> <settings…>
  local scheme=$1 destination=$2; shift 2
  xcodebuild -project Qwovi.xcodeproj -scheme "$scheme" -configuration Release -destination "$destination" \
    -derivedDataPath "$WORK/build" MARKETING_VERSION="$VERSION" "$@" build > "$WORK/$scheme.log" 2>&1 \
    || { grep -E "error:" "$WORK/$scheme.log" | head -20; echo "✗ $scheme didn't build"; exit 1; }
}

# Mac: "-" is an ad-hoc signature — enough to run on Apple silicon; Gatekeeper asks once (see README).
build QwoviMac 'generic/platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
mkdir "$WORK/dmg"
cp -R "$WORK/build/Build/Products/Release/Qwovi.app" "$WORK/dmg/"
ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -volname Qwovi -srcfolder "$WORK/dmg" -ov -format UDZO "$OUT/Qwovi-$VERSION.dmg" >/dev/null
echo "✓ $OUT/Qwovi-$VERSION.dmg"

# iPhone: an unsigned Payload/Qwovi.app in a zip — the .ipa sideloading tools re-sign.
build QwoviiOS 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=
mkdir -p "$WORK/ipa/Payload"
cp -R "$WORK/build/Build/Products/Release-iphoneos/Qwovi.app" "$WORK/ipa/Payload/"
(cd "$WORK/ipa" && zip -qry "$OUT/Qwovi-$VERSION.ipa" Payload)
echo "✓ $OUT/Qwovi-$VERSION.ipa"
