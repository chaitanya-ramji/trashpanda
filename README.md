<p align="center"><img src="assets/icon.png" width="128" alt="Trash Panda icon"></p>

# Trash Panda

Trash Panda is a small menu bar app for developers. It finds the files that fill your disk. It shows how much space you can get back. You decide what to delete.

The app has no window. It has only a menu.

## What you see

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/menu-dark.png">
    <img src="assets/menu-light.png" width="340" alt="The Trash Panda menu. It shows 61 GB free of 245 GB, a bar, a button to free up 13 GB, and one line for each language.">
  </picture>
</p>

The picture uses made-up data.

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
| Dart, Flutter | Pub packages, analysis cache | `.dart_tool`, Flutter `build` |
| Elixir, Erlang | Hex packages, rebar3 | `_build`, `deps`, `.elixir_ls` |
| Zig | Global cache | `.zig-cache`, `zig-out` |
| Homebrew | Downloads and old versions | None |
| Docker | Build cache, untagged images (safe). Stopped containers, old unused images, and unused volumes (review). | None |

Trash Panda does **not** touch your documents or app data. It removes a Docker image only when no container uses it, running or stopped. An old named image is a review item.

## Safe and Review

Each item has a tier.

- **Safe.** The item is cheap to get back. The "Reclaim" button deletes only safe items.
- **Review.** The item is costly to get back, or someone changed the project in the last 30 days (you can change the limit). You must choose each review item.

The menu shows the cost to get an item back. The cost is seconds, minutes, or a new download.

## Safety rules

Trash Panda deletes files for good. They do not go to the Trash. These rules reduce the risk:

- The app always shows a list and asks you before it deletes.
- A project folder counts only when a marker file is next to it. For example, `node_modules` needs `package.json`.
- The app skips a project when a running process uses it.
- The app marks a project as review when someone changed it in the last 30 days. You can change this limit (see Settings).
- Python virtual environments are always review items.
- The app never follows symbolic links.
- The app never deletes outside your home folder.
- The app never deletes Documents, Desktop, Pictures, Movies, Music, `.ssh`, `.config`, iCloud, or app data.
- The app counts only space that a delete frees. A file with more than one hard link frees no space.
- For Homebrew, the app asks `brew` what it would remove. Homebrew keeps its own index files, and the app does not count them.
- The app asks the owning tool to clean its own data when it can. It runs fixed commands only.
- Docker volumes can hold databases. The app removes a volume only when no container uses it and it is a local volume. Each volume needs its own confirmation, and the default button keeps it. A volume in use is shown but cannot be removed.
- Docker Desktop keeps all its data in one disk image file. The app shows the size that the file really uses, next to the size of the data inside. It never changes the file. Lowering the disk limit in Docker Desktop deletes the file and all containers and images, so the app never suggests it.
- The app never prunes all Docker images. It removes a named image only by its exact name, never forced.
- Docker runs on a local engine only (OrbStack, Docker Desktop, Colima, or Rancher Desktop). The app refuses remote engines and unknown sockets. It ignores `DOCKER_HOST` and `DOCKER_CONTEXT`.

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
- `~/.config/trashpanda/settings` holds options as `name = value` lines.

The `settings` file has one option now:

```
# A project that changed within this many days is a review item.
# A Docker image is listed only when it has been on this Mac for this many days.
# Use a whole number from 1 to 3650.
stale_days = 30
```

If the value is not valid, the app uses 30 and writes a warning to the log.

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

## Roadmap

We work from the pinned [Roadmap issue](https://github.com/chaitanya-ramji/trashpanda/issues/38). Each box below is an issue. Pick one and help.

### Done
- [x] Menu bar app with a storage bar and the reclaimable total
- [x] Ten language groups: Swift and Xcode, JavaScript and TypeScript, Python, Java and Kotlin, C# and .NET, C and C++, Go, Rust, PHP, Ruby
- [x] Homebrew and Docker build cache
- [x] Safe and review tiers, path guard, and a log
- [x] Spinner, new icon, and a DMG release (not notarized)

### Now: v0.2 Dart, Elixir, Zig
- [x] Add Dart and Flutter support ([#1](https://github.com/chaitanya-ramji/trashpanda/issues/1))
- [x] Add Elixir and Erlang support ([#2](https://github.com/chaitanya-ramji/trashpanda/issues/2))
- [x] Add Zig support ([#3](https://github.com/chaitanya-ramji/trashpanda/issues/3))
- [x] Let the user set the stale limit ([#4](https://github.com/chaitanya-ramji/trashpanda/issues/4))
- [x] Add a screenshot of the menu to the README ([#5](https://github.com/chaitanya-ramji/trashpanda/issues/5))

### Next: v0.3 Docker
- [x] Docker: act only on a local engine ([#6](https://github.com/chaitanya-ramji/trashpanda/issues/6))
- [x] Docker: remove dangling images ([#7](https://github.com/chaitanya-ramji/trashpanda/issues/7))
- [x] Docker: remove stopped containers ([#8](https://github.com/chaitanya-ramji/trashpanda/issues/8))
- [x] Docker: remove unused images older than N days ([#9](https://github.com/chaitanya-ramji/trashpanda/issues/9))
- [x] Docker: show volumes and remove dangling ones ([#10](https://github.com/chaitanya-ramji/trashpanda/issues/10))
- [x] Docker: test with a fake docker tool ([#11](https://github.com/chaitanya-ramji/trashpanda/issues/11))
- [x] Docker: explain a VM disk that does not shrink ([#12](https://github.com/chaitanya-ramji/trashpanda/issues/12))

### Next: v0.4 App and browser caches
- [ ] Clean stale app update downloads ([#13](https://github.com/chaitanya-ramji/trashpanda/issues/13))
- [ ] Browser caches: Chromium browsers ([#14](https://github.com/chaitanya-ramji/trashpanda/issues/14))
- [ ] Browser caches: Firefox ([#15](https://github.com/chaitanya-ramji/trashpanda/issues/15))
- [ ] Do not clean an app while it runs ([#16](https://github.com/chaitanya-ramji/trashpanda/issues/16))
- [ ] Browser Service Worker storage (review only) ([#17](https://github.com/chaitanya-ramji/trashpanda/issues/17))
- [ ] Old test browser downloads: Cypress, Playwright, Puppeteer, Chrome for Testing ([#18](https://github.com/chaitanya-ramji/trashpanda/issues/18))
- [ ] Electron and node-gyp download caches ([#19](https://github.com/chaitanya-ramji/trashpanda/issues/19))

### Later: v0.5 Insight
- [ ] Cache explorer: show the largest folders in Library/Caches ([#20](https://github.com/chaitanya-ramji/trashpanda/issues/20))
- [ ] Explain space that does not come back: local snapshots ([#21](https://github.com/chaitanya-ramji/trashpanda/issues/21))
- [ ] Logs and crash reports (review) ([#22](https://github.com/chaitanya-ramji/trashpanda/issues/22))
- [ ] Show the Trash size and offer to empty it ([#23](https://github.com/chaitanya-ramji/trashpanda/issues/23))
- [ ] Old installers in Downloads (DMG, PKG, ZIP) ([#24](https://github.com/chaitanya-ramji/trashpanda/issues/24))

### Later: v0.6 Old tools
- [ ] Old language runtimes: nvm, fnm, pyenv, rustup, sdkman, mise, asdf ([#25](https://github.com/chaitanya-ramji/trashpanda/issues/25))
- [ ] Unused Homebrew packages ([#26](https://github.com/chaitanya-ramji/trashpanda/issues/26))
- [ ] Xcode: old simulator runtimes and archives (review) ([#27](https://github.com/chaitanya-ramji/trashpanda/issues/27))
- [ ] AI coding tool caches and old versions ([#28](https://github.com/chaitanya-ramji/trashpanda/issues/28))
- [ ] More languages (phase 2b): Scala, Haskell, R, Julia, Nim, OCaml, Crystal, Clojure, Perl, Lua ([#29](https://github.com/chaitanya-ramji/trashpanda/issues/29))

### Later: v1.0 Signed and stable
- [ ] Notarize the app and publish signed releases ([#30](https://github.com/chaitanya-ramji/trashpanda/issues/30))
- [ ] Homebrew cask and tap ([#31](https://github.com/chaitanya-ramji/trashpanda/issues/31))
- [ ] Check for updates ([#32](https://github.com/chaitanya-ramji/trashpanda/issues/32))
- [ ] Move to Trash delete mode ([#33](https://github.com/chaitanya-ramji/trashpanda/issues/33))
- [ ] Low-disk alert ([#34](https://github.com/chaitanya-ramji/trashpanda/issues/34))
- [ ] Scheduled clean (opt in) ([#35](https://github.com/chaitanya-ramji/trashpanda/issues/35))
- [ ] Test on Intel Macs and older macOS versions ([#36](https://github.com/chaitanya-ramji/trashpanda/issues/36))
- [ ] Decide: cloud-synced project folders ([#37](https://github.com/chaitanya-ramji/trashpanda/issues/37))

## Licence

Trash Panda is free software under the GNU General Public License, version 3. See `LICENSE`. Credits are in `NOTICE`.
