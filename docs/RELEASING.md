# Releasing Trash Panda

This guide shows how to make a signed and notarized DMG and how to publish the Homebrew cask.

Notarization means that Apple scans the app and approves it. After that, macOS opens the app with no warning. You need a paid Apple Developer Program account for this.

## What you need once

1. Join the Apple Developer Program.
2. Make a **Developer ID Application** certificate. In Xcode, open Settings, then Accounts, then Manage Certificates.
3. Export the certificate as a `.p12` file. Set a password.
4. Make an app-specific password at appleid.apple.com.
5. Make a second GitHub repository named `homebrew-tap`. It holds the cask.

## Release from GitHub (recommended)

Add these secrets to the `trashpanda` repository:

| Secret | Value |
| --- | --- |
| `MACOS_CERT_P12` | The `.p12` file, encoded with `base64 -i cert.p12` |
| `MACOS_CERT_PASSWORD` | The `.p12` password |
| `APPLE_ID` | Your Apple ID email |
| `APPLE_TEAM_ID` | Your 10-character team ID |
| `APPLE_APP_PASSWORD` | The app-specific password |
| `TAP_TOKEN` | A GitHub token that can write to `homebrew-tap` |

Then push a version tag:

```sh
git tag v0.1.0
git push origin v0.1.0
```

The workflow in `.github/workflows/release.yml` does these steps:

1. It runs the tests.
2. It builds a universal app (Apple silicon and Intel).
3. It signs the app and the DMG.
4. It sends the DMG to Apple and waits for approval.
5. It staples the approval to the DMG.
6. It publishes a GitHub release.
7. It updates the cask in `homebrew-tap`.

## Release from your Mac

Save your Apple credentials one time:

```sh
xcrun notarytool store-credentials "trashpanda" --apple-id YOU --team-id TEAMID --password APP_PASSWORD
```

Then run:

```sh
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="trashpanda" \
./scripts/release.sh 0.1.0
```

The script writes `build/TrashPanda-0.1.0.dmg` and a `.sha256` file.

To test the DMG steps without an account, run `./scripts/release.sh 0.1.0 --unsigned`. macOS blocks this file on other Macs. Use it for tests only.

## Install for users

```sh
brew install --cask chaitanya-ramji/tap/trashpanda
```

The cask appears in the tap after the first release.

## Homebrew main cask list

The official `homebrew/cask` list accepts only notarized apps that are well known. Submit the cask there after the project has many users.
