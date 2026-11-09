#!/bin/bash
# Builds Trash Panda on this Mac and installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

DEST="${INSTALL_DIR:-/Applications}/TrashPanda.app"
pkill -x trashpanda 2>/dev/null || true
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
cp -R build/TrashPanda.app "$DEST"
echo "Installed $DEST"
open "$DEST"
