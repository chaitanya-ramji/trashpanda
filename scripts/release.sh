#!/bin/bash
# Builds, signs, notarizes, and staples build/TrashPanda-<version>.dmg.
#
#   scripts/release.sh 0.2.0              full release. Needs the variables below.
#   scripts/release.sh 0.2.0 --unsigned   local test of the DMG steps only. Gatekeeper rejects this file.
#
# Needed for a full release:
#   DEVELOPER_ID   for example "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE a notarytool keychain profile name
#     or APPLE_ID, TEAM_ID, and APP_PASSWORD (an app-specific password)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?Usage: scripts/release.sh <version> [--unsigned]}"
UNSIGNED=0
[[ "${2:-}" == "--unsigned" ]] && UNSIGNED=1

if [[ $UNSIGNED -eq 0 ]]; then
    : "${DEVELOPER_ID:?Set DEVELOPER_ID to your Developer ID Application identity}"
    if [[ -z "${NOTARY_PROFILE:-}" ]]; then
        : "${APPLE_ID:?Set NOTARY_PROFILE, or set APPLE_ID, TEAM_ID, and APP_PASSWORD}"
        : "${TEAM_ID:?Set TEAM_ID}"
        : "${APP_PASSWORD:?Set APP_PASSWORD}"
    fi
fi

UNIVERSAL=1 VERSION="$VERSION" CODESIGN_IDENTITY="${DEVELOPER_ID:--}" ./scripts/build-app.sh

APP="build/TrashPanda.app"
DMG="build/TrashPanda-$VERSION.dmg"
STAGE="build/dmg-stage"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Trash Panda" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" > /dev/null
rm -rf "$STAGE"

if [[ $UNSIGNED -eq 1 ]]; then
    echo "Built $DMG (not signed, not notarized)"
    (cd build && shasum -a 256 "TrashPanda-$VERSION.dmg" | tee "TrashPanda-$VERSION.dmg.sha256")
    exit 0
fi

codesign --force --sign "$DEVELOPER_ID" --timestamp "$DMG"

echo "Submitting to Apple. This takes a few minutes."
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
else
    xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD" --wait
fi

xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

(cd build && shasum -a 256 "TrashPanda-$VERSION.dmg" | tee "TrashPanda-$VERSION.dmg.sha256")
echo "Ready: $DMG"
