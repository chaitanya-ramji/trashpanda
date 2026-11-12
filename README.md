<p align="center"><img src="assets/icon.png" width="128" alt="Trash Panda icon"></p>

# Trash Panda

Trash Panda is a small menu bar app for developers. It finds the files that fill your disk. It shows how much space you can get back. You decide what to delete.

The app has no window. It has only a menu.

## What you see

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/menu-dark.png">
    <img src="assets/menu-light.png" width="340" alt="The Trash Panda menu. It shows 61 GB free of 245 GB, one bar that splits the data you can clean by language, a button to free up 9.3 GB, and one line for each language.">
  </picture>
</p>

The picture uses made-up data.

Click the panda in the menu bar. The menu shows:

- The free space and the total space of your disk.
- A bar that shows where the data that you can clean is. It has one part for each line below it that shows a size, and each part has the size of its line. A short legend names the largest three.
- The space that you can reclaim now.
- One line for each language or tool. Open a line to see each item.

**Hover** a part of the bar to see its name, its size, its share, and how much of it is safe. **Click** a part to open the items of that language or tool. An item of an app that is open stays in the bar, with a light striped fill. The hover tells you which app to quit. A line that is for information only has no part. When an app opens or quits, the bar and the lines change.

<p align="center">
  <img src="assets/menu-hover.png" width="340" alt="The same menu with the mouse over the JavaScript part of the bar. The line under the title reads JavaScript and TypeScript, 3.7 GB, 15 percent, 2.2 GB safe.">
</p>

## What it cleans

Trash Panda looks in two places:

1. **Global caches** in your home folder, for example the npm cache or Xcode build data.
2. **Build folders inside your projects**, for example `node_modules` or `target`.

| Language or tool | Global caches | Project folders |
| --- | --- | --- |
| Swift, Obj-C, Xcode | Build data, simulator caches, Swift packages, CocoaPods. Review: simulator runtimes, old simulators, archives, device support files (one item for each OS version; the newest of each device model is kept). | `.build`, `Pods` |
| JavaScript, TypeScript | npm, Yarn, Bun, pnpm, Playwright (old browser versions), Electron and node-gyp downloads | `node_modules`, `.next`, `.nuxt`, `.turbo` |
| Old language runtimes | Versions installed by nvm, fnm, pyenv, rustup, SDKMAN, asdf, and mise: one review item for each version that is not the default, not the newest, not asked for by a scanned project, and not running. | None |
| JavaScript global packages | Packages that you installed with `npm install -g`, `pnpm add -g`, `yarn global add`, or `bun add -g`: one review item for each. The manager removes it. | None |
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
| Scala | Coursier cache (safe). Ivy cache (review). | `target` (sbt), `.bloop`, `.bsp`, `.metals`, `out` (Mill) |
| Haskell | Cabal and GHCup downloads (safe). Stack snapshots (review). | `dist-newstyle`, `.stack-work` |
| R | renv package cache (review). | None |
| Julia | Precompiled code (safe). Packages and artifacts (review). | None |
| Nim | Build cache (safe). | `nimcache` |
| OCaml | Dune cache (safe). | `_build` (dune), `_opam` (review) |
| Crystal | Compiler cache (safe). | None (`lib` is left out: see the PR) |
| Clojure | Git libraries (review). `~/.m2` is already covered under Java. | `target`, `.cpcache`, `.shadow-cljs` |
| Perl | cpanm and CPAN build folders and downloads (safe). | `blib` (`local` is left out: see the PR) |
| Lua | None (no global cache path could be confirmed on macOS). | `lua_modules` (review) |
| Homebrew | Downloads and old versions (safe). Review: each package that no other package needs (`brew leaves`), with its install date. Brew removes it. | None |
| Browsers | Chromium browsers (Chrome, Arc, Brave, Edge, Vivaldi, Opera, Dia): cache, code cache, and GPU caches. Firefox and Zen: `cache2` and `startupCache`. Dia and Zen are not checked on a real install yet. Review: Service Worker storage. | None |
| Other apps | Old update downloads of apps that use the Sparkle updater (older than 7 days) | None |
| Logs and crash reports | Old files in `~/Library/Logs`: one review item for logs, one for crash reports (`DiagnosticReports`, `CrashReporter`). Files at least 30 days old only. | None |
| Old installers | `.dmg` and `.pkg` files in `~/Downloads` that are older than 30 days. One review item for each file. No other file type. | None |
| AI agents | uv: unused cache entries, removed with `uv cache prune` (safe; agents such as Claude Code and Codex start uv). Old session transcripts of Codex (`~/.codex/sessions`, `archived_sessions`) and Claude Code (`~/.claude/projects/<project>/<id>.jsonl`), older than the stale limit (review). Gemini CLI chats: a note only. Zed: `Library/Caches/Zed`, `Library/Caches/dev.zed.Zed`, and the language servers in `Application Support/Zed/languages` (safe). LM Studio, Jan, and GPT4All models (review, one item for each model; paths from public documentation, not checked on a real install). Hugging Face hub cache (also used by MLX and llama.cpp): one review item for each model, dataset, or space. Ollama models (review, one item for each model that nobody changed for the stale limit and that is not loaded; removed with `ollama rm`). VS Code, Cursor, Windsurf, and Antigravity: `CachedData`, `CachedExtensionVSIXs`, the Chromium caches, logs older than 7 days, and old extension versions that the editor marks obsolete (safe). Electron app caches of Claude, Codex, and Antigravity (safe: `Cache`, `Code Cache`, `GPUCache`, the Dawn caches, `Shared Dictionary`). Claude Desktop: old runtimes (all but the newest of each family) and the Cowork VM (review). Claude Code command line tool: old versions in `~/.local/share/claude/versions` (safe). Codex desktop app: leftover runtime installs (`~/.cache/codex-runtimes/codex-runtime-install-*`, at least 1 day old, safe) and the downloaded runtime (review). More products are added by their own issues (see #28). | None |
| Trash | The size of `~/.Trash`. One review item. Finder empties it (see Safety rules). | None |
| Docker | Build cache, untagged images (safe). Stopped containers, old unused images, and unused volumes (review). | None |

Trash Panda does **not** touch your documents or app data. It removes a Docker image only when no container uses it, running or stopped. An old named image is a review item.

## Safe and Review

Each item has a tier.

- **Safe.** The item is cheap to get back. The "Reclaim" button deletes only safe items.
- **Review.** The item is costly to get back, or someone changed the project in the last 30 days (you can change the limit). You must choose each review item.

The menu shows the cost to get an item back. The cost is seconds, minutes, or a new download.

## Safety rules

By default, Trash Panda deletes files for good. They do not go to the Trash. You can change this with the `delete_mode` setting (see Settings). These rules reduce the risk:

- Check for updates: once a day, and when you choose "Check for updates…", the app asks the GitHub releases of this project for the list of releases (`api.github.com`) and shows the menu line "Update available: <version>…" when a newer one exists. A beta sees newer betas and newer stable versions. A stable version sees stable versions only. The line opens the release page in your browser, and only a page on `github.com` in this repository is opened. **The app never downloads or installs an update.** The request has no body, no cookie, no id, no version, and a general name (`TrashPanda`) as user agent, and it uses a session that stores nothing, so GitHub sees an IP address and a request, as for any web page. The menu item "Check for updates every day" turns the automatic check off (it is on by default).
- A list in a group menu that has more than 12 rows shows the first 12, and the rest open in a submenu ("N more…"), so that no row is hidden.
- The cache explorer lists the largest folders in `~/Library/Caches` (at least 10 MB, up to 30; the rest of a long list opens in an "N more…" submenu). A folder that already has its own item (Homebrew, pnpm, Playwright, and so on) is not listed again here, so nothing is counted twice. Every row that is listed can be emptied, and nothing in the menu is read only. A folder with an unknown owner is a **cache folder** review item: apps can download the files again, but some keep logins or offline files there. `CloudKit` (iCloud data), `com.apple.*` (managed by macOS), Family Sharing, Maps, Safari, Photos, and Mail folders are **system cache** review items with the strongest dialog: it says that iCloud and macOS rebuild the files, that data which is not synced yet can be lost, and that Trash Panda cannot check this. The path guard lifts its rule for the one folder that you chose, never for `~/Library/Caches` itself and never for another action, and each child is checked again to be inside that folder and not a link. Items are never in the one-click clean, and the default button keeps the data. Only the contents are deleted, the folder stays, and a folder that is named like the bundle ID of an app is skipped while that app is open. The size of a folder does not count what another item already counts inside it (for example the old update downloads of Arc). The guard refuses `~/Library/Caches` itself and every `keep` folder.
- Time Machine local snapshots: when `tmutil listlocalsnapshots /` shows snapshots, the menu has one information line with their number and the age of the oldest, and says in one sentence that they can hold space that deleting files does not free at once. Trash Panda only reads the list. It never deletes or thins a snapshot (a test forbids those commands). The link opens a search of Apple Support, because I could not confirm one Apple page.
- Docker volumes that only a stopped container uses: Docker refuses `volume rm` while any container uses a volume, even a stopped one, so such a volume used to be shown as "info" with no way forward. Now the stopped container and the volumes that only it uses are one review item ("Stopped container · name and 1 volume"). The cleaner asks Docker again before it runs anything: the container must still be stopped, and each volume must still be local and used by this container only. Then it runs `container rm <id>` and `volume rm <name>` for each volume, never with `-f`, `--force`, `-v`, `--volumes`, or a prune, and if any check fails it runs nothing. The dialog warns that a volume can hold a database (export it first, for example with `pg_dump`), and its default button keeps the data. A volume that a running container uses stays information, and the line names the container and says to stop it first.
- Nothing in the menu is read only: a line that has no action (for example the Time Machine snapshot note, the newest Xcode runtime that is kept on purpose, the Docker Desktop disk image, or a volume that several containers share) is not shown as a disabled row.
- Docker running containers: a running container (with the volumes that only it uses) is a review item too, because the owner wants to be able to delete it. The app stops it with `docker stop` (which asks it to shut down and waits, never `kill`, never forced, never a zero wait), checks that it really stopped, then removes the container and each volume. If Docker does not stop it, or another container uses a volume now, nothing is removed. The dialog is the strongest one ("Stop and delete this running container?"), it warns that programs and databases stop now, and its default button keeps everything.
- Docker: after a clean, the menu says what Docker freed inside Docker. If the Mac gained less than half of it (the data of Docker Desktop, OrbStack, Colima, and Rancher Desktop lives in one disk file that shrinks slowly), the app says so in one sentence, with a link to the steps. The log keeps the two numbers apart (freed inside Docker, and the change of the free space of the Mac). Other items of the same clean are not counted as Docker space.
- Old language runtime versions (nvm, fnm, pyenv, rustup, SDKMAN, asdf, mise) are review items, one for each version, and the default button keeps it. A version is offered only when it is not the default or global version of its manager, no scanned project asks for it (`.nvmrc`, `.node-version`, `.python-version`, `rust-toolchain`, `.tool-versions`, `.sdkmanrc`, `mise.toml`), it is not the newest version of its tool, and no running program starts from it. A request that the app cannot read (`lts/*`, `latest`, `system`, `20.x`, a range, an array) keeps every version of that tool. The cleaner decides again at clean time, and if it cannot read the projects it removes nothing. The text says "no scanned project asks for it" and never "unused", because a script, an editor, or a project outside the scanned folders can still use a version. The version folder is removed by its path, the same as `uninstall` does (nvm and SDKMAN are shell functions that an app cannot run). None of these managers is installed on the author's Mac, so the layouts are not checked on a real install.
- Global JavaScript packages are review items, one for each package, and the default button keeps it. The package manager removes the package (`npm uninstall -g`, `pnpm remove -g`, `yarn global remove`, `bun remove -g`), with no option, and Trash Panda lists the packages again before and after to check the result. The managers themselves and their helpers (`npm`, `pnpm`, `yarn`, `bun`, `corepack`, `node`) are never listed. No manager records when a tool was last used, so the menu shows the date of the package folder and never says "unused". A program that calls the tool, such as an MCP server that an AI app starts, stops working, and the dialog says so. `npm` is checked on a real Mac. The output of `pnpm`, `yarn`, and `bun` follows their documentation and is not checked on a real install.
- The AI agents menu is split by product when it has more than 6 rows from more than one product. Each product is one row with its icon (the icon of its app, or a symbol when the app is not installed) and the size that it can free, and it opens its own list with its own "Free up" line. Rows are no longer cut at 12 in this menu.
- uv: Trash Panda runs `uv cache prune` (unused entries only, never `--force`) as a safe item. Its size cannot be previewed, so the menu shows the whole cache as an upper bound, and the report shows what was freed. Removing the whole cache (`uv cache clean`) is a separate review item. The Pythons and tools that uv installed (`~/.local/share/uv/python` and `tools`) are never deleted.
- Session transcripts (Codex, Claude Code) are review items, and the default button of the dialog keeps them. Only transcript files older than the stale limit are listed, and the clean removes only files that were old at the time of the preview and were not used again. You cannot resume a deleted conversation, and the tool may still list it. Claude Code's `memory` folders, `history.jsonl`, the logins (`auth.json`, `.credentials.json`), the databases, and settings are never touched. Claude Code deletes old transcripts itself (`cleanupPeriodDays`), and the item says so. The chats of Gemini CLI are only named, with the command to remove them.
- Zed: the guard allows exactly three folders (`Library/Caches/Zed`, `Library/Caches/dev.zed.Zed`, `Application Support/Zed/languages`). The database (`db`), `extensions`, conversations, and settings are never allowed. Zed must be closed.
- LM Studio, Jan, and GPT4All models are review items, one for each model folder or `.gguf` file at the exact depth of its app (for example `~/.lmstudio/models/<publisher>/<model>`, `Application Support/Jan/data/models/<model>`, `Application Support/nomic.ai/GPT4All/<file>.gguf`). Chats (`Jan/data/threads`, GPT4All `chats`), settings, `localdocs`, and hidden folders are never allowed, and the app must be closed. Trash Panda deletes the model by itself (these apps have no documented delete command). Not checked on a real install.
- Hugging Face repositories are review items, one for each folder in `~/.cache/huggingface/hub` (`models--org--name`), and the dialog keeps the repository by default. Trash Panda runs `hf cache rm <type>/<org>/<name> --yes` when `hf` is installed, and otherwise deletes only that one repository folder (it holds its own blobs). A repository with a download in the last day (a fresh `.incomplete` file) is left alone. `hf cache prune` and the interactive `huggingface-cli delete-cache` are not used. Not checked on a real install.
- Ollama models share layers, so Trash Panda never deletes a file in `~/.ollama` (the guard refuses the whole folder). It runs `ollama rm <name>` and nothing else (no `-a`, no `--force`). The name is checked, the model must still be listed, and a model that `ollama ps` shows as loaded is skipped. If Ollama does not answer, there is no item. The freed size is measured from the models folder, and it can be smaller than the model because shared layers stay. Not checked on a real Ollama install.
- VS Code style editors (VS Code, Cursor, Windsurf, Antigravity): the guard allows only `CachedData`, `CachedExtensionVSIXs`, the Chromium cache names, and `logs/<timestamp>` folders (and the app must be closed). `User` (settings, the chats of Copilot in `workspaceStorage`, `globalStorage`, `state.vscdb` with the logins and chats of Cursor), `Backups` (unsaved files), cookies, and local storage are never allowed. An extension folder is removed only when the editor itself lists it in `.obsolete` and does not list it as installed in `extensions.json`.
- The Electron app caches (Claude, Codex, Antigravity) are safe items. The guard allows only fixed Chromium cache folder names, at the top of the app folder and in `Partitions/<name>`. Logins, cookies, `Local Storage`, `IndexedDB`, `Session Storage`, settings, and chats are never allowed. The app must be closed.
- Claude Desktop: the old runtimes and the Cowork VM are review items, and the dialog of the VM keeps it by default. Reports say that Claude downloads about 10 GB again after the VM is removed, and that is not confirmed by Anthropic. The guard allows exactly four folder shapes inside `Application Support/Claude` (`claude-code/<version>`, `claude-code-vm/<version>`, `vm_bundles/claudevm.bundle`, `vm_bundles/warm`). Chats, logins, cookies, settings, and sessions are refused. Claude Desktop must be closed.
- Old Claude Code versions: the newest version, the version that `~/.local/bin/claude` points to, and every version that is open now (found with `lsof` by file name) always stay. If `lsof` cannot answer, nothing is removed. `claude update` downloads a version again.
- The AI agents group has its own menu. Each item starts with the product name and shows its icon. The Codex runtime is a review item, and its dialog keeps it by default. A leftover install must be at least a day old, and the app is not touched while it runs (the app, or a program that starts from the folder). Chat history, logins, and settings of these tools are never in a list.
- `~/Library/Caches` itself can never be deleted by a path, and neither can `CloudKit` (iCloud data), `FamilyCircle`, `GeoServices`, or any `com.apple.*` folder in it. Other cache folders are cleaned only through an item with its own checks.
- Logins and secrets are protected by name. The Hugging Face login (`~/.cache/huggingface/token` and `stored_tokens`) and the folder that holds it can never be deleted. The Hugging Face rows cover only the repositories in `hub` and the `xet` chunk cache.
- A Homebrew package is a review item, one for each package that no other package needs. Trash Panda does not delete its files: it runs `brew uninstall --formula <name>`, and never `--force` or `--ignore-dependencies`, so brew itself refuses when another package needs it. The app reads the list again when you confirm, and it skips a package that runs. Brew does not record when a tool was last used, so the menu shows the install date and never says "unused".
- Old logs and crash reports are two review items, never in the one-click clean, and the default button of the dialog keeps the files. Only plain files at least 30 days old count. A folder, a link, and a newer file never count, and the app reads the age again when you confirm. The log of Trash Panda (`~/Library/Logs/TrashPanda`) is never touched.
- Old installers are review items, one for each file, never in the one-click clean, and the default button of the dialog keeps the file. Only `.dmg` and `.pkg` files that lie directly in `~/Downloads` count, and only when they are at least 30 days old. A link, a folder, and a file in a sub-folder never count. The app reads the age again when you confirm, and it skips a disk image that is mounted. The first time, macOS asks if Trash Panda may look in Downloads. Say no, and the app shows no installers.
- The Trash is a review item. It is never in the one-click clean. Trash Panda does not delete those files itself: it asks Finder to empty the Trash, the same as the Finder menu. The first time, macOS asks if Trash Panda may control Finder. Say no, and nothing is deleted. The app reads only `~/.Trash`, not the Trash of an external drive. If macOS does not let the app read the Trash (Full Disk Access), the app shows nothing for it.
- The app always shows a list and asks you before it deletes.
- A project folder counts only when a marker file is next to it. For example, `node_modules` needs `package.json`.
- The app skips a project when a running process uses it.
- For a browser, the app removes only eight named cache folders inside each profile (`Default` or `Profile N`). It never touches cookies, logins, history, local storage, IndexedDB, extensions, preferences, sessions, or Service Worker storage. Service Worker storage (the files of websites that work offline) is its own kind of review item: one item for each website, so that you can keep the web app that you use offline and clear the rest. A website is shown by its host name only when the name of its folder proves it (the folder name is the SHA-1 of the storage key, and Trash Panda keeps a name from the files of the folder only when its hash is that folder name). Otherwise it is "Unknown site". The guard allows exactly one 40-hex site folder inside `Service Worker/CacheStorage`. It is never in the one-click clean, and the default button of its dialog keeps it. Firefox gets two folders (`cache2` and `startupCache`) in `Library/Caches`, and its profile folder is never touched. Safari is not cleaned: macOS protects its folders with a Full Disk Access prompt, and the app never asks for it. A browser that is open is skipped. The item of an open app is listed like any other, with the icon of the app. Click it to see "Quit <app> and free <size>": Trash Panda asks the app to quit, the same as choosing Quit in the app, and waits. It never forces an app to quit, and an app that stays open is left alone.
- The app removes an update download only when it is older than 7 days, and it reads the age again when you confirm. It touches only the `Installation` and `PersistentDownloads` folders of an app, never the rest of its cache. It refuses a cache folder that is a link.
- The app does not clean a cache while the app that uses it runs. For example, Xcode build data waits until you quit Xcode. The menu shows which app to quit, and the cleaner checks again before each item.
- The app marks a project as review when someone changed it in the last 30 days. You can change this limit (see Settings).
- Python virtual environments are always review items.
- The app never follows symbolic links.
- The app never deletes outside your home folder.
- The app never deletes Documents, Desktop, Pictures, Movies, Music, `.ssh`, `.config`, iCloud, or app data.
- The app counts only space that a delete frees. A file with more than one hard link frees no space.
- For Homebrew, the app asks `brew` what it would remove. Homebrew keeps its own index files, and the app does not count them.
- The app asks the owning tool to clean its own data when it can. It runs fixed commands only.
- Xcode deletes a simulator runtime by shutting down the simulators on it, so the app refuses a runtime that has a running simulator. It keeps the newest runtime of each platform and any runtime used in the last 30 days. It never deletes a running simulator. It never uses the bulk forms of the simulator delete commands.
- An Xcode archive holds the symbol files that you need to read crash reports of a build that you shipped. The app lists each archive by itself, never in the one-click clean, and the default button of its dialog keeps it.
- Docker volumes can hold databases. The app removes a volume only when no container uses it and it is a local volume. Each volume needs its own confirmation, and the default button keeps it. A volume in use is shown but cannot be removed.
- Docker Desktop keeps all its data in one disk image file. The app shows the size that the file really uses, next to the size of the data inside. It never changes the file. Lowering the disk limit in Docker Desktop deletes the file and all containers and images, so the app never suggests it.
- The app never prunes all Docker images. It removes a named image only by its exact name, never forced.
- Docker runs on a local engine only (OrbStack, Docker Desktop, Colima, or Rancher Desktop). The app refuses remote engines and unknown sockets. It ignores `DOCKER_HOST` and `DOCKER_CONTEXT`.

## Install

You need macOS 13 or later.

### Option 1: DMG

1. Download the DMG from the [Releases page](https://github.com/chaitanya-ramji/trashpanda/releases). The newest build is **0.8.0**, the first stable release since 0.1.0. How versions are named is in [`docs/VERSIONING.md`](docs/VERSIONING.md). It has many more safety checks than 0.1.0, which can act on a remote Docker engine and can clean Xcode data while Xcode runs. The build is not signed or notarized yet, so macOS blocks the first launch (see below). Some of the tools that it can clean are not tested yet on many real Macs. The release notes list them.
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

The `settings` file has two options:

```
# A project that changed within this many days is a review item.
# A Docker image is listed only when it has been on this Mac for this many days.
# Use a whole number from 1 to 3650.
stale_days = 30
```

If the value is not valid, the app uses 30 and writes a warning to the log.

```
# What the app does with a file or a folder that it may remove.
# permanent (the default): delete for good.
# trash: move it to the Trash, so that you can put it back.
delete_mode = permanent
```

You can also turn it on in the menu: **Settings**, then **Move files to the Trash**. The change is saved in the `settings` file.

In `trash` mode:

- Files and folders go to the Trash with the system call of macOS. The app never deletes them. If a move fails, the item is reported as failed and stays where it is. The app does not delete it for good instead.
- **The space is not free until you empty the Trash.** The confirmation dialog, the message after a clean, and the menu bar text say "moved to the Trash", not "freed".
- An item that a tool removes (Docker, Homebrew, the simulator, a package manager, Ollama, `hf`) is not a file delete. The tool still removes it for good, and the dialog says so. The Trash item is unchanged: it still asks Finder to empty the Trash.
- A file that is already in the Trash is not moved again. An external disk that has no Trash gives an error for that item, and the item stays.
- All safety checks run first, in the same order as in `permanent` mode.
- Not checked on a real install: the move of real folders with `FileManager.trashItem`, and the error of a disk with no Trash. The tests use a fake Trash folder and never touch the real Trash.

If the value is not `permanent` or `trash`, the app uses `permanent` and writes a warning to the log.

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

### Done: v0.2 Dart, Elixir, Zig
- [x] Add Dart and Flutter support ([#1](https://github.com/chaitanya-ramji/trashpanda/issues/1))
- [x] Add Elixir and Erlang support ([#2](https://github.com/chaitanya-ramji/trashpanda/issues/2))
- [x] Add Zig support ([#3](https://github.com/chaitanya-ramji/trashpanda/issues/3))
- [x] Let the user set the stale limit ([#4](https://github.com/chaitanya-ramji/trashpanda/issues/4))
- [x] Add a screenshot of the menu to the README ([#5](https://github.com/chaitanya-ramji/trashpanda/issues/5))

### Done: v0.3 Docker
- [x] Docker: act only on a local engine ([#6](https://github.com/chaitanya-ramji/trashpanda/issues/6))
- [x] Docker: remove dangling images ([#7](https://github.com/chaitanya-ramji/trashpanda/issues/7))
- [x] Docker: remove stopped containers ([#8](https://github.com/chaitanya-ramji/trashpanda/issues/8))
- [x] Docker: remove unused images older than N days ([#9](https://github.com/chaitanya-ramji/trashpanda/issues/9))
- [x] Docker: show volumes and remove dangling ones ([#10](https://github.com/chaitanya-ramji/trashpanda/issues/10))
- [x] Docker: test with a fake docker tool ([#11](https://github.com/chaitanya-ramji/trashpanda/issues/11))
- [x] Docker: explain a VM disk that does not shrink ([#12](https://github.com/chaitanya-ramji/trashpanda/issues/12))
- [x] Roadmap: keep the checkboxes correct ([#39](https://github.com/chaitanya-ramji/trashpanda/issues/39))

### Done: v0.4 Xcode, app and browser caches (one item on hold: #43)
- [x] Xcode: old simulator runtimes, devices, and archives (review) ([#27](https://github.com/chaitanya-ramji/trashpanda/issues/27))
- [x] Xcode: iOS device support files, one item for each iOS version ([#41](https://github.com/chaitanya-ramji/trashpanda/issues/41))
- [ ] Xcode: keep the device support folder of a connected device ([#43](https://github.com/chaitanya-ramji/trashpanda/issues/43))
- [x] Menu header: one bar, aligned to the menu edge ([#45](https://github.com/chaitanya-ramji/trashpanda/issues/45))
- [x] Browsers: Dia, Zen, and Safari ([#46](https://github.com/chaitanya-ramji/trashpanda/issues/46))
- [x] Blocked app: offer Quit and clean ([#47](https://github.com/chaitanya-ramji/trashpanda/issues/47))
- [x] Open-app items: list them like any item, with the app icon ([#48](https://github.com/chaitanya-ramji/trashpanda/issues/48))
- [x] Clean stale app update downloads ([#13](https://github.com/chaitanya-ramji/trashpanda/issues/13))
- [x] Browser caches: Chromium browsers ([#14](https://github.com/chaitanya-ramji/trashpanda/issues/14))
- [x] Browser caches: Firefox ([#15](https://github.com/chaitanya-ramji/trashpanda/issues/15))
- [x] Do not clean an app while it runs ([#16](https://github.com/chaitanya-ramji/trashpanda/issues/16))
- [x] Browser Service Worker storage (review only) ([#17](https://github.com/chaitanya-ramji/trashpanda/issues/17))
- [x] Old test browser downloads: Cypress, Playwright, Puppeteer, Chrome for Testing ([#18](https://github.com/chaitanya-ramji/trashpanda/issues/18))
- [x] Electron and node-gyp download caches ([#19](https://github.com/chaitanya-ramji/trashpanda/issues/19))

### Done: v0.5 Insight
- [x] Cache explorer: show the largest folders in Library/Caches ([#20](https://github.com/chaitanya-ramji/trashpanda/issues/20))
- [x] Explain space that does not come back: local snapshots ([#21](https://github.com/chaitanya-ramji/trashpanda/issues/21))
- [x] Logs and crash reports (review) ([#22](https://github.com/chaitanya-ramji/trashpanda/issues/22))
- [x] Show the Trash size and offer to empty it ([#23](https://github.com/chaitanya-ramji/trashpanda/issues/23))
- [x] Old installers in Downloads (DMG, PKG, ZIP) ([#24](https://github.com/chaitanya-ramji/trashpanda/issues/24))
- [x] Docker: say when freed space is not back on the Mac yet ([#40](https://github.com/chaitanya-ramji/trashpanda/issues/40))
- [x] Service Worker storage: show each website by name ([#44](https://github.com/chaitanya-ramji/trashpanda/issues/44))
- [x] Menu: show the full split of reclaimable data as an interactive bar ([#42](https://github.com/chaitanya-ramji/trashpanda/issues/42))

### Done: v0.6 Old tools (one item moves on: #88)
- [x] Old language runtimes: nvm, fnm, pyenv, rustup, sdkman, mise, asdf ([#25](https://github.com/chaitanya-ramji/trashpanda/issues/25))
- [x] Unused Homebrew packages ([#26](https://github.com/chaitanya-ramji/trashpanda/issues/26))
- [x] Unused global JavaScript packages: npm, pnpm, Bun, Yarn ([#51](https://github.com/chaitanya-ramji/trashpanda/issues/51))
- [x] AI coding tool caches and old versions ([#28](https://github.com/chaitanya-ramji/trashpanda/issues/28))
- [x] More languages (phase 2b): Scala, Haskell, R, Julia, Nim, OCaml, Crystal, Clojure, Perl, Lua ([#29](https://github.com/chaitanya-ramji/trashpanda/issues/29))
- [ ] Project scan: match generic folder names (lib, local) only when the marker file is present ([#88](https://github.com/chaitanya-ramji/trashpanda/issues/88))

### Done: v0.7 Correct numbers and safe tools
- [x] Do not count the uv cache two times in the totals ([#124](https://github.com/chaitanya-ramji/trashpanda/issues/124))
- [x] Show one folder in one group only ([#125](https://github.com/chaitanya-ramji/trashpanda/issues/125))
- [x] Careful dialog for a container, and the critical style for a permanent delete ([#126](https://github.com/chaitanya-ramji/trashpanda/issues/126))
- [x] Start system tools from fixed paths, and refuse a tool file that others can write to ([#127](https://github.com/chaitanya-ramji/trashpanda/issues/127))
- [x] Correct the network sentence in SECURITY.md ([#128](https://github.com/chaitanya-ramji/trashpanda/issues/128))
- [x] Do not start a process on the main thread when the menu opens ([#129](https://github.com/chaitanya-ramji/trashpanda/issues/129))
- [x] One shared delete helper: measure first, check last ([#130](https://github.com/chaitanya-ramji/trashpanda/issues/130))
- [x] Make the guard independent of letter case and Unicode form ([#138](https://github.com/chaitanya-ramji/trashpanda/issues/138))
- [x] Close small gaps in delete handlers ([#139](https://github.com/chaitanya-ramji/trashpanda/issues/139))
- [x] Keep paths out of the system log, and protect the log file ([#140](https://github.com/chaitanya-ramji/trashpanda/issues/140))
- [x] Count a file with hard links one time ([#141](https://github.com/chaitanya-ramji/trashpanda/issues/141))
- [x] Do not offer a Homebrew package that is younger than the stale limit ([#142](https://github.com/chaitanya-ramji/trashpanda/issues/142))
- [x] Harden the CI job and the release job ([#143](https://github.com/chaitanya-ramji/trashpanda/issues/143))
- [x] Valid bundle version and complete package data ([#144](https://github.com/chaitanya-ramji/trashpanda/issues/144))

### Done: v0.8 Menu and dialogs (released as 0.8.0)
- [x] Move the menu code into a tested menu model, with no change of behavior ([#147](https://github.com/chaitanya-ramji/trashpanda/issues/147))
- [x] Move the demo code out of the production classes ([#148](https://github.com/chaitanya-ramji/trashpanda/issues/148))
- [x] Settings submenu with About, Help, and "Report a problem" ([#149](https://github.com/chaitanya-ramji/trashpanda/issues/149))
- [x] Fold small groups into one row ([#150](https://github.com/chaitanya-ramji/trashpanda/issues/150))
- [x] Say what the main action removes ([#151](https://github.com/chaitanya-ramji/trashpanda/issues/151))
- [x] Show the time of the last scan ([#152](https://github.com/chaitanya-ramji/trashpanda/issues/152))
- [x] "Show in Finder" for an item, and the rebuild label as a subtitle ([#153](https://github.com/chaitanya-ramji/trashpanda/issues/153))
- [x] Section headers in a group submenu ([#154](https://github.com/chaitanya-ramji/trashpanda/issues/154))
- [x] Do not build the menu again while it is open ([#155](https://github.com/chaitanya-ramji/trashpanda/issues/155))
- [x] Progress and a stop during a clean ([#156](https://github.com/chaitanya-ramji/trashpanda/issues/156))
- [x] One summary dialog after a clean, with the check of the real free space ([#157](https://github.com/chaitanya-ramji/trashpanda/issues/157))
- [x] A fixed color for each group ([#158](https://github.com/chaitanya-ramji/trashpanda/issues/158))
- [x] The header follows the accessibility settings ([#159](https://github.com/chaitanya-ramji/trashpanda/issues/159))
- [x] Label and tooltip for the menu bar item ([#160](https://github.com/chaitanya-ramji/trashpanda/issues/160))
- [x] Small text and list defects ([#161](https://github.com/chaitanya-ramji/trashpanda/issues/161))
- [x] "Always keep this item" in the dialog ([#162](https://github.com/chaitanya-ramji/trashpanda/issues/162))
- [x] Remove dead code and code that is written two times ([#163](https://github.com/chaitanya-ramji/trashpanda/issues/163))
- [x] Own version type, and a failed update check is not a check ([#164](https://github.com/chaitanya-ramji/trashpanda/issues/164))
- [x] Stop a tool that ignores the time limit (own child process only) ([#186](https://github.com/chaitanya-ramji/trashpanda/issues/186))
- [x] Show the Docker disk file in a "Good to know" section ([#187](https://github.com/chaitanya-ramji/trashpanda/issues/187))
- [x] Row "Other space on this Mac" in "Good to know" ([#188](https://github.com/chaitanya-ramji/trashpanda/issues/188))

### Now: v0.9 More coverage
- [ ] Git worktrees: find the ones that tools and you left behind, and remove them safely ([#118](https://github.com/chaitanya-ramji/trashpanda/issues/118))
- [ ] Android emulator images and virtual devices (review items) ([#189](https://github.com/chaitanya-ramji/trashpanda/issues/189))
- [ ] Caches of conda, Deno, and Terraform ([#190](https://github.com/chaitanya-ramji/trashpanda/issues/190))
- [ ] The two Xcode folders of G-06 ([#191](https://github.com/chaitanya-ramji/trashpanda/issues/191))
- [ ] Trim the build folder of an active Rust project ([#192](https://github.com/chaitanya-ramji/trashpanda/issues/192))
- [ ] Show what grew since the last week (size history with an off setting) ([#193](https://github.com/chaitanya-ramji/trashpanda/issues/193))
- [ ] One dependency value for the scanner and the cleaner ([#194](https://github.com/chaitanya-ramji/trashpanda/issues/194))
- [ ] Quality gates in CI ([#195](https://github.com/chaitanya-ramji/trashpanda/issues/195))
- [ ] Split the two largest core files ([#196](https://github.com/chaitanya-ramji/trashpanda/issues/196))

### Next: v1.0 Signed and stable
- [ ] Notarize the app and publish signed releases ([#30](https://github.com/chaitanya-ramji/trashpanda/issues/30))
- [ ] Homebrew cask and tap ([#31](https://github.com/chaitanya-ramji/trashpanda/issues/31))
- [x] Check for updates ([#32](https://github.com/chaitanya-ramji/trashpanda/issues/32))
- [ ] One-click updates (OTA) with Sparkle ([#121](https://github.com/chaitanya-ramji/trashpanda/issues/121))
- [x] Move to Trash delete mode ([#33](https://github.com/chaitanya-ramji/trashpanda/issues/33))
- [ ] Low-disk alert ([#34](https://github.com/chaitanya-ramji/trashpanda/issues/34))
- [ ] Scheduled clean (opt in) ([#35](https://github.com/chaitanya-ramji/trashpanda/issues/35))
- [ ] Test on Intel Macs and older macOS versions ([#36](https://github.com/chaitanya-ramji/trashpanda/issues/36))
- [ ] Decide: cloud-synced project folders ([#37](https://github.com/chaitanya-ramji/trashpanda/issues/37))
- [ ] Commands for scripts: JSON, dry run, and a clean of safe items ([#197](https://github.com/chaitanya-ramji/trashpanda/issues/197))
- [ ] A note at the first start ([#198](https://github.com/chaitanya-ramji/trashpanda/issues/198))
- [ ] Swift 6 language mode ([#199](https://github.com/chaitanya-ramji/trashpanda/issues/199))

### Later: ideas (no milestone yet)
- [ ] "Make room": a plan that frees a size that you choose ([#200](https://github.com/chaitanya-ramji/trashpanda/issues/200))
- [ ] Group the items by project ([#201](https://github.com/chaitanya-ramji/trashpanda/issues/201))
- [ ] A note when a cache grows back ([#202](https://github.com/chaitanya-ramji/trashpanda/issues/202))
- [ ] More facts for the menu: device backups and a second Xcode ([#203](https://github.com/chaitanya-ramji/trashpanda/issues/203))

## Licence

Trash Panda is free software under the GNU General Public License, version 3. See `LICENSE`. Credits are in `NOTICE`.
