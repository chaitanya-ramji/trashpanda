#!/bin/bash
# Builds build/TrashPanda.app with its icon.
#   CODESIGN_IDENTITY  signing identity. The default "-" signs ad hoc, for local use only.
#   UNIVERSAL=1        build for Apple silicon and Intel
#   VERSION            version text for Info.plist
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    ARCHS=(--arch arm64 --arch x86_64)
else
    ARCHS=()
fi
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/trashpanda"

APP="build/TrashPanda.app"
rm -rf "$APP" build/AppIcon.iconset build/AppIcon.icns
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/trashpanda"
cp scripts/Info.plist "$APP/Contents/Info.plist"

if [[ -n "${VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi

# The app draws its own icon. We write the sizes, then pack them.
"$BIN" --write-icons build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${CODESIGN_IDENTITY:--}"
if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --sign - --options runtime "$APP"
else
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP"
