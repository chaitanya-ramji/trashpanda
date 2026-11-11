# Versions and releases

This page is the rule book for the name of a release and for how we cut one. The app reads these names (see "Why the form is fixed"), so follow it exactly.

## The name of a version

A version has three numbers. A beta has a word and a number after them.

| Kind | Form | Example |
| --- | --- | --- |
| Beta (a pre-release) | `MAJOR.MINOR.PATCH-beta.N` | `0.8.0-beta.1` |
| Stable | `MAJOR.MINOR.PATCH` | `1.0.0` |

- The tag is `v` and the version: `v0.8.0-beta.1`.
- The file is `TrashPanda-<version>.dmg`, with `TrashPanda-<version>.dmg.sha256` next to it.
- The title of the release is `Trash Panda <version>`: `Trash Panda 0.8.0-beta.1`.
- A beta is always marked "pre-release" on GitHub. A stable version never is.
- Do not use other forms: not `0.6a`, not `0.8`, not `0.8.0-beta6`, not `beta 6`.

### Why the form is fixed

The update check of the app reads the tags of the releases. It accepts only three numbers with an optional part after a dash (`ClaudeVersions.isVersionName`). A tag in another form is not a version, so the app never offers it. A beta user sees newer betas and newer stable versions. A stable user sees stable versions only.

## What the numbers mean

Until 1.0, the roadmap milestones decide the numbers.

- **MINOR** is the milestone that the build works toward. It is the lowest milestone that still has an open issue when you cut the release. Milestone `v0.8` ships as `0.8.0-beta.1`, `0.8.0-beta.2`, and so on.
- **N** counts the betas of one MINOR. It starts at 1 and goes up by 1. It never goes back, and a number is never used two times.
- **PATCH** is for a fix of a version that is already out, with no new feature. The first fix of `0.8.0` is `0.8.1`. Before 1.0 a fix is mostly a new beta, so PATCH stays 0.
- **MAJOR** is 0 until the app is notarized and the milestone `v1.0` is finished. Then it is `1.0.0`, and it is stable.

A milestone is finished when each of its issues is closed or moved to a later milestone. Move an issue on purpose, and say why in a comment.

## When to cut a beta

A beta is not made for each merge. Cut one only when all of these are true:

1. The owner asks for it. A release is outward-facing, so nobody cuts one alone.
2. At least one roadmap issue closed since the last release, and the release notes say which ones.
3. `main` has a passing CI run, and `swift build` and the full `swift test` pass on your Mac.
4. The README roadmap and the roadmap issue match (`python3 scripts/sync-roadmap.py --check`).

## What never changes

- A published tag is never moved, renamed, or deleted. Links, the Homebrew cask, and the update check use it.
- A DMG is built from the commit of its tag, and from nothing else.
- A version number is never reused. If a release is wrong, publish the next number and say in the notes that the old one is superseded.
- The notes and the files of a release have no personal data and no real names from a private Mac.

## How to cut a release

1. Pick the version with the rules above. Check that the tag does not exist.
2. Update the milestone: each issue closed or moved. Close the milestone if it is finished.
3. Build: `VERSION=<version> scripts/release.sh <version> --unsigned` (until the app is notarized, see #30). Check the DMG: open it, check that the app starts, and check `CFBundleShortVersionString`.
4. Write the notes from the template below.
5. Create the tag and the release (pre-release for a beta). Upload the DMG and the `.sha256` file.
6. Update the download text in the README, and the cask (`scripts/make-cask.sh`) when there is one.
7. Run the update check against the new release: an older beta must show "Update available".

## Template for the notes

```
**This is a beta.** <one sentence: what it builds on>

## Changes since <previous version>
- <one line for each closed issue, with its number>

## Please test first
- <what to try, and what to export or save first>

## Not checked on a real install
<every path, tool, or screen that no one checked on a real Mac>

## Not in this beta
<issues that people ask about and that are not here, with numbers>

## Install
<the steps and the checksum command>
```

## History

Before these rules, the betas of the milestones `v0.4`, `v0.5`, and `v0.6` all shipped as `0.4.0-beta.1` to `0.4.0-beta.6`. The tags stay as they are, because of the rule above. The notes of beta 1 to 5 say that beta 6 supersedes them. The next release is the first one that follows this page.

| Release | What it is |
| --- | --- |
| `0.1.0` | The first release (stable, not notarized). |
| `0.4.0-beta.1` to `0.4.0-beta.5` | Early betas of the work of milestones `v0.4` to `v0.6`. Superseded by beta 6. |
| `0.4.0-beta.6` | The last beta of that work. |
