#!/bin/bash
# Prints the Homebrew cask for one release.   scripts/make-cask.sh <version> <sha256>
set -euo pipefail

VERSION="${1:?Usage: scripts/make-cask.sh <version> <sha256>}"
SHA="${2:?Usage: scripts/make-cask.sh <version> <sha256>}"

cat <<EOF
cask "trashpanda" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/chaitanya-ramji/trashpanda/releases/download/v#{version}/TrashPanda-#{version}.dmg"
  name "Trash Panda"
  desc "Menu bar app that finds and removes developer disk waste"
  homepage "https://github.com/chaitanya-ramji/trashpanda"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :ventura"

  app "TrashPanda.app"

  zap trash: [
    "~/.config/trashpanda",
    "~/Library/Logs/TrashPanda",
  ]
end
EOF
