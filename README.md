<p align="center"><img src="assets/icon.png" width="128" alt="Trash Panda icon"></p>

# Trash Panda

Trash Panda is a small menu bar app for developers. It finds the files that fill your disk. It shows how much space you can get back. You decide what to delete.

The app has no window. It has only a menu.

## What you see

Click the panda in the menu bar. The menu shows:

- The free space and the total space of your disk.
- A bar that splits the disk into used, review, reclaimable, and free space.
- The space that you can reclaim now.
- One line for each language or tool. Open a line to see each item.

## What it cleans

Trash Panda looks in two places:

1. **Global caches** in your home folder, for example the npm cache or Xcode build data.
2. **Build folders inside your projects**, for example `node_modules` or `target`.

| Language or tool | Global caches | Project folders |
| --- | --- | --- |
| Swift, Obj-C, Xcode | Build data, simulator files, Swift packages, CocoaPods | `.build`, `Pods` |
| JavaScript, TypeScript | npm, Yarn, Bun, pnpm, Playwright | `node_modules`, `.next`, `.nuxt`, `.turbo` |
| Python | pip, uv, pre-commit, Poetry, Hugging Face, PyTorch | `.venv`, `.tox`, `.nox` |
| Java, Kotlin | Gradle, Maven, Android, Kotlin/Native, JetBrains | `target`, `build`, `.gradle` |
| C#, .NET | NuGet | `obj`, `bin`, `.vs` |
| C, C++ | ccache, clangd, vcpkg, Conan | CMake and Meson build folders |
| Go | Build cache, module cache | None |
| Rust | Cargo registry and git files | `target` |
| PHP | Composer | `vendor` |
| Ruby | Bundler | None |
| Homebrew | Downloads and old versions | None |
| Docker | Build cache | None |

Trash Panda does **not** touch your images, volumes, documents, or app data.

## Safe and Review

Each item has a tier.

- **Safe.** The item is cheap to get back. The "Reclaim" button deletes only safe items.
- **Review.** The item is costly to get back, or someone changed the project in the last 30 days. You must choose each review item.

The menu shows the cost to get an item back. The cost is seconds, minutes, or a new download.

## Safety rules

Trash Panda deletes files for good. They do not go to the Trash. These rules reduce the risk:

- The app always shows a list and asks you before it deletes.
- A project folder counts only when a marker file is next to it. For example, `node_modules` needs `package.json`.
- The app skips a project when a running process uses it.
- The app marks a project as review when someone changed it in the last 30 days.
- Python virtual environments are always review items.
- The app never follows symbolic links.
- The app never deletes outside your home folder.
- The app never deletes Documents, Desktop, Pictures, Movies, Music, `.ssh`, `.config`, iCloud, or app data.
- The app counts only space that a delete frees. A file with more than one hard link frees no space.
- For Homebrew, the app asks `brew` what it would remove. Homebrew keeps its own index files, and the app does not count them.
- The app asks the owning tool to clean its own data when it can. It runs fixed commands only.

## Install

You need macOS 13 or later.

### Option 1: DMG

1. Download `TrashPanda-0.1.0.dmg` from the [Releases page](https://github.com/chaitanya-ramji/trashpanda/releases).
2. Open the DMG. Drag Trash Panda to Applications.
3. Open Trash Panda from Applications.

The app is not notarized by Apple yet. macOS blocks the first launch. To allow it, use one of these methods:

- Open **System Settings**, then **Privacy & Security**. Scroll down and click **Open Anyway** next to Trash Panda.
- Or run this command in Terminal, then open the app again:

```sh
xattr -dr com.apple.quarantine /Applications/TrashPanda.app
```

You do this one time only. To check the download, compare its SHA-256 checksum with the `.sha256` file on the Releases page.

### Option 2: Build from source

An app that you build on your own Mac does not need approval. You need the Swift toolchain (Xcode or the Command Line Tools).

```sh
git clone https://github.com/chaitanya-ramji/trashpanda.git
cd trashpanda
./scripts/install-from-source.sh
```

The script builds the app, copies it to Applications, and opens it.

To build without installing:

```sh
./scripts/build-app.sh
open build/TrashPanda.app
```

### Homebrew

A Homebrew cask is planned. It needs a notarized app first.

To start the app at login, choose **Open at Login** in the menu.

To see the result without the menu, run this command. It never deletes anything.

```sh
.build/release/trashpanda --scan
```

## Spinner and log

The panda in the menu bar turns into a spinner while the app scans or cleans. The menu header shows a spinner too.

The app writes every scan, every command, and every delete to a log:

```
~/Library/Logs/TrashPanda/trashpanda.log
```

Hold the Option key and open the menu. Choose **Show log in Finder**. The log shows the size of each item before and after a clean. After each clean, the app measures what is left. The "Freed" number is the measured result.

## Settings

Settings are plain text files. Each file has one path on each line. A line that starts with `#` is a comment.

- `~/.config/trashpanda/keep` lists paths that the app never touches.
- `~/.config/trashpanda/roots` lists more folders to search for projects.

The app searches these folders by default: `Developer`, `dev`, `Projects`, `Code`, `GitHub`, `Repos`, `Workspace`, `Development`, `src`, `work`, and `www`.

## Development

```sh
swift build
swift test
```

The code has two parts:

- `PandaCore` finds items and deletes them. It has all the safety rules and the tests.
- `TrashPanda` is the menu bar app. It has no logic that deletes files.

To add a language, add rows to `Sources/PandaCore/Catalog.swift`. Add a test in `Tests/PandaCoreTests`.

## Plan

Phase 1 covers the languages in the table above. Phase 2 is planned: Dart and Flutter, Elixir, Scala, Haskell, Zig, R, Julia, AI coding tools, unused Homebrew packages, and old language runtimes. See `docs/SPEC.md` for the full spec and `docs/RELEASING.md` for releases.

## Licence

Trash Panda is free software under the GNU General Public License, version 3. See `LICENSE`. Credits are in `NOTICE`.
