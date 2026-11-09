#!/bin/bash
# Builds build/TrashPanda.app. Set CODESIGN_IDENTITY to sign with a Developer ID.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/TrashPanda.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/trashpanda "$APP/Contents/MacOS/trashpanda"
cp scripts/Info.plist "$APP/Contents/Info.plist"

codesign --force --sign "${CODESIGN_IDENTITY:--}" --options runtime "$APP"
echo "Built $APP"
