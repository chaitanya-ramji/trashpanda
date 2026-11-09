# Trash Panda: Product Specification

Status: Draft 1. Phase 1 is built. Phase 2 and Phase 3 are planned.
Language: This document follows ASD-STE100 Simplified Technical English.

## 1. Problem

Developer Macs run out of disk space. The cause is not one big file. The cause is many build folders and caches that tools create and never remove.

Examples are `node_modules`, Xcode build data, Rust `target` folders, Gradle caches, and Docker build cache. A developer can lose 50 GB to 100 GB this way.

The macOS storage screen shows these files as "System Data". The developer cannot see what is in it. The developer does not know what is safe to delete.

Existing cleaners have two faults:

- General cleaners do not know developer tools. They miss most of the files in this document.
- Some cleaners delete files without a clear warning. A wrong delete costs the user time. It destroys trust.

Trash Panda solves both faults. It shows the space that you can get back. It shows the cost to get each item back. It deletes only what you choose.

## 2. Users

| User | Need |
| --- | --- |
| Solo developer | Free space on a small disk. Do it fast and safely. |
| Mobile developer | Remove Xcode data and old simulators. |
| Polyglot developer | Clean many languages with one tool. |
| Team lead (Phase 3) | Give a team the same safe rules. |

## 3. Goals

1. The user sees free space and reclaimable space in one click.
2. The user reclaims space without a rebuild that surprises them.
3. The user never loses source code, data, or settings.
4. The app supports the ten most used languages in Phase 1.
5. A developer adds a new language by adding data, not code.

## 4. Non-Goals

| Non-goal | Reason |
| --- | --- |
| Remove malware or fix privacy | Other tools do this. It is not a developer problem. |
| Clean documents, photos, mail, or app data | The risk of data loss is too high. |
| Show a window or a dashboard | The product promise is a menu only. |
| Uninstall apps | This is a separate product. |
| Support Windows or Linux | The app uses macOS storage and menu APIs. |

## 5. User stories

**Solo developer**

- As a developer, I want to see my free space in the menu bar, so that I know when my disk is low.
- As a developer, I want to see how much space I can reclaim, so that I decide if a clean is worth it.
- As a developer, I want one button for the safe items, so that I do not review each folder.
- As a developer, I want the app to skip projects that I use now, so that my work does not break.

**Polyglot developer**

- As a developer, I want one line for each language, so that I see where the space goes.
- As a developer, I want to see what each item costs to get back, so that I choose with full information.

**Careful developer**

- As a developer, I want to put a project on a keep list, so that the app never touches it.
- As a developer, I want a list and a confirmation before any delete, so that I can stop a mistake.

**Mobile developer**

- As an iOS developer, I want to remove old simulators and build data, so that Xcode stops filling my disk.

## 6. Requirements

### 6.1 Must have (P0). Built in Phase 1.

| ID | Requirement | Acceptance criteria |
| --- | --- | --- |
| R1 | The app lives in the menu bar and has no window. | The app has no Dock icon. The only interface is the menu and one confirmation dialog. |
| R2 | The menu shows free space, total space, and a split bar. | Given a scan, the header shows free and total space. The bar shows used, review, reclaimable, and free space. |
| R3 | The menu shows the reclaimable total. | The total equals the sum of all safe items. |
| R4 | The app finds global caches for each Phase 1 language. | The catalog lists each cache. The scan reports it when the folder exists and holds 1 MB or more. |
| R5 | The app finds build folders inside projects. | A folder counts only when its marker file is in the project folder. |
| R6 | Each item has a tier: safe or review. | A project that changed in the last 30 days is review. A Python virtual environment is always review. |
| R7 | The menu shows the cost to get an item back. | Each item shows seconds, minutes, or download. |
| R8 | The app asks before it deletes. | The dialog lists the items and sizes. The app deletes nothing when the user cancels. |
| R9 | The app skips projects that a running process uses. | A process with its working directory in the project blocks the delete. |
| R10 | Every delete passes the path guard. | The guard refuses symbolic links, paths outside home, system paths, and protected data. |
| R11 | The user can keep a path. | A path in `~/.config/trashpanda/keep` is never deleted, and no parent of it is deleted. |
| R12 | The app counts only space that a delete frees. | A file with more than one hard link is not counted. |
| R13 | The app uses the owning tool when the tool holds state. | Docker, Homebrew, uv, Go, and simulator cleans run fixed commands. |
| R14 | A scan finishes in 10 seconds on a typical developer Mac. | The author machine scans in 3.6 seconds. |
| R15 | A read-only scan mode exists. | `trashpanda --scan` prints the result and deletes nothing. |

### 6.2 Should have (P1). Phase 1.5.

| ID | Requirement | Acceptance criteria |
| --- | --- | --- |
| R16 | The app is signed and notarized. | Gatekeeper opens the app with no warning. |
| R17 | A Homebrew cask installs the app. | `brew install --cask trashpanda` installs and opens the app. |
| R18 | A low-disk alert exists. | The app shows a notification when free space is below a set limit. The user can turn it off. |
| R19 | The user can choose a delete mode. | The user chooses between permanent delete and move to Trash. |
| R20 | The user can set the stale limit. Built in v0.2. | The default is 30 days. The user can change it with `stale_days` in `~/.config/trashpanda/settings`. |
| R21 | The menu shows the age of each project. | The tooltip shows the days since the last change. |

### 6.3 Future (P2). Phase 2 and Phase 3.

See Section 8. The catalog format must support these items without a code change.

## 7. Safety model

The app deletes files for good in Phase 1. These layers reduce the risk. Each layer works alone.

1. **Catalog only.** The app deletes only paths that the catalog names or that a marker rule finds.
2. **Marker rule.** A build folder counts only when a marker file is next to it. A CMake folder also needs a CMake cache file inside.
3. **Activity rule.** The app skips a project that a process uses. It marks a project review when it changed in 30 days.
4. **Path guard.** The guard checks every path again at delete time. It refuses:
   - symbolic links,
   - paths outside the home folder,
   - the home folder and its direct children,
   - system paths,
   - Documents, Desktop, Pictures, Movies, Music, iCloud, mail, keychains, `.ssh`, `.config`, and app data,
   - package stores that hold the only copy of data,
   - paths on the keep list.
5. **Owner tools.** Docker, Homebrew, uv, Go, and the simulator run their own clean commands. The app runs fixed commands. It never builds a command from user data.
6. **Confirmation.** The user sees a list before any delete.
7. **Re-check.** The cleaner reads the running processes again before it deletes.

The app never deletes Docker images, Docker volumes, simulator runtimes, or Xcode archives.

## 8. Language and tool support

Support is data in `Sources/PandaCore/Catalog.swift`. A new language needs a list of cache paths, a list of build folder names, and the marker files.

### Phase 1. Built.

| Group | Languages | Status |
| --- | --- | --- |
| Swift, Obj-C, Xcode | Swift, Objective-C | Built |
| JavaScript, TypeScript | JavaScript, TypeScript | Built |
| Python | Python | Built |
| Java, Kotlin | Java, Kotlin, Android | Built |
| C#, .NET | C#, F#, VB.NET | Built |
| C, C++ | C, C++ | Built |
| Go | Go | Built |
| Rust | Rust | Built |
| PHP | PHP | Built |
| Ruby | Ruby | Built |
| Tools | Homebrew, Docker build cache | Built |

### Phase 2. Planned.

| Item | Notes |
| --- | --- |
| Dart and Flutter | Pub cache, `.dart_tool`, `build` |
| Elixir | `_build`, `deps`, Hex cache |
| Scala | sbt and Coursier caches, `target` |
| Haskell | Stack and Cabal stores, `.stack-work`, `dist-newstyle` |
| Zig | `.zig-cache`, global cache |
| R and Julia | Package caches |
| Old language runtimes | Old versions from nvm, fnm, pyenv, rustup, and sdkman. Show only versions that no project uses. |
| Unused Homebrew packages | Formulae that no other formula needs and that the user did not run for a long time |
| AI coding tool caches | Caches and old versions of coding agents |
| Xcode extras | Old simulator runtimes, old Xcode archives. Always review. |
| Docker extras | Unused images and volumes. Always review. |

### Phase 3. Planned.

- Scheduled clean with rules that the user sets.
- Team policy file and reports (commercial).
- A project history view that shows which projects are dead.

## 9. Success metrics

The app sends no data. The metrics below use public signals and user reports. See open question Q3.

**Leading (first 30 days)**

| Metric | Target |
| --- | --- |
| Repository stars | 500 |
| Release downloads | 1,000 |
| Reports of "deleted something I needed" | 0 |
| Reports of a wrong item in the list | Fewer than 5. Each is fixed in 7 days. |

**Lagging (first 6 months)**

| Metric | Target |
| --- | --- |
| Homebrew cask installs | 5,000 |
| Languages added by outside contributors | 3 |
| Paid commercial licences or support plans | Set after Q2 is answered |

**Quality gates (every release)**

- All unit tests pass.
- A scan on a real developer machine shows no item from the protected list.
- A new catalog row has a test.

## 10. Open questions

| ID | Question | Owner | Blocks |
| --- | --- | --- | --- |
| Q1 | Does the app need Full Disk Access for any Phase 1 path? | Engineering | Phase 1.5 |
| Q2 | How does the project earn money when the code is GPL-3.0? The licence allows free commercial use. Options: signed builds, support, team features. | Owner | Phase 3 |
| Q3 | Should the app have opt-in anonymous metrics? The promise of "no data sent" is a trust asset. | Owner | Phase 1.5 |
| Q4 | Who pays for the Apple Developer account for signing and notarization? | Owner | Phase 1.5 |
| Q5 | Is permanent delete the right default? A Trash mode costs no space until the user empties the Trash. | Owner and users | Phase 1.5 |
| Q6 | How does the app size Docker Desktop disk images? The image file is large and sparse. | Engineering | Phase 2 |
| Q7 | Should the app scan folders that cloud services sync? A delete there can sync to other devices. | Engineering | Phase 2 |
| Q8 | How does the app decide that a runtime or a Homebrew package is unused? | Engineering | Phase 2 |

## 11. Timeline

| Phase | Content | Depends on |
| --- | --- | --- |
| 1 (done) | Menu app, ten language groups, Homebrew, Docker, tests | None |
| 1.5 | Signing, notarization, Homebrew cask, low-disk alert, delete mode, stale limit | Q1, Q3, Q4, Q5 |
| 2 | More languages, old runtimes, unused packages, AI tool caches | Q6, Q7, Q8 |
| 3 | Scheduled clean, team policy, project history | Q2 |

## 12. Licence and credit

Trash Panda uses GPL-3.0. Part of the catalog and the safety rules come from the Mole project, which also uses GPL-3.0. The file `NOTICE` gives the credit.

The GPL licence allows free commercial use of the source code. Paid offers must sell something else. Examples are signed builds, support, and team features.
