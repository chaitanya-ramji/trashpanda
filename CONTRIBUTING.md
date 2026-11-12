# Contributing to Trash Panda

Thank you for your help. Trash Panda deletes files, so we work with care. This guide shows how to help in a safe way.

## Work from the roadmap

All work starts from an issue on the [roadmap](https://github.com/chaitanya-ramji/trashpanda/issues?q=is%3Aissue+label%3Aroadmap). The pinned **Roadmap** issue lists them in order.

1. Pick an open issue. Issues with the label `good first issue` are the best start. A workflow keeps the boxes of the Roadmap issue correct when an issue closes or reopens.
2. Write a comment on the issue to say that you take it.
3. Do the work in a branch. Open a pull request. Write `Closes #<number>` in the description.

If you have an idea that is not on the roadmap, open an issue first. Wait for a reply before you write code. This saves your time.

## Branches and pull requests

- Name a branch `feat/<topic>`, `fix/<topic>`, `hotfix/<topic>`, or `docs/<topic>`. Open the pull request against `main`. Nobody pushes to `main` directly.
- The build and all tests must pass on your Mac, and the checks of the pull request must pass, before a merge. A change to the path guard or to a delete rule also needs an independent review.
- We merge with "rebase and merge" (or "squash" when a branch has a merge commit). GitHub deletes the branch after the merge. Delete your local copy too: `git branch -D <name>`.

## Set up

You need macOS 13 or later and the Swift toolchain (Xcode or the Command Line Tools).

```sh
git clone https://github.com/chaitanya-ramji/trashpanda.git
cd trashpanda
swift build
swift test
```

To see what the app finds on your Mac without deleting anything, run:

```sh
swift run trashpanda --scan
```

To see the menu with made-up data, run this command. It never scans and never deletes. Use it for screenshots.

```sh
swift run trashpanda --demo light
swift run trashpanda --demo dark
```

Other demo options, for screenshots:

- `--hover N` shows the mouse over the Nth part of the split bar. `--click N` clicks it.
- `--submenu docker` opens the submenu of one group.
- `--backdrop` puts a plain window behind the menu, so that other windows do not show through it.
- Move the real mouse away before you capture, because a real mouse move changes the hover.

To see one confirmation dialog, add `--dialog volume`, `--dialog container`, or `--dialog safe`. Use it to check the wording. It deletes nothing.

```sh
swift run trashpanda --demo light --dialog volume
```

## How the code is organized

| Folder | Content |
| --- | --- |
| `Sources/PandaCore` | Finds items and deletes them. It has all the safety rules. |
| `Sources/TrashPanda` | The menu bar app. It has no logic that deletes files. |
| `Tests/PandaCoreTests` | Unit tests. |
| `docs/` | The spec, the review reports, and `VERSIONING.md` (the names of releases and how we cut one). |

## Add a language

Most languages need data only. Open `Sources/PandaCore/Catalog.swift`.

1. Add a case to `Ecosystem` in `Model.swift`. Give it a short name.
2. Add rows to `Catalog.caches` for global caches. Paths start in the home folder.
3. If an app uses a cache (an IDE, for example), give the row an `owner`. The cleaner then skips the row while the app runs. A test fails if an Xcode cache has no owner.
4. Add rows to `Catalog.artifacts` for build folders inside projects. Each row needs a marker file.
5. Add a test in `Tests/PandaCoreTests`.
6. Add the language to the table in `README.md`.

A marker file is a file that proves the folder is a project of that language. For example, `Cargo.toml` proves that `target` is a Rust build folder. Never match a folder by name alone.

Some folder names are common, for example `lib` and `local`. Give such a row `generic: true`. The project scan still enters a folder with a generic name, and lists it only when its marker file is next to it. A project inside a folder named `lib` is found as before.

## Test Docker features

No test may use a real Docker engine. Docker tests use a fake `docker` tool.

- Make your test class a subclass of `DockerTestCase`. It hides the real `docker` tool from the search path.
- Make the fake with `FakeDocker` (in `Tests/PandaCoreTests/FakeDocker.swift`). It answers from fixture files.
- Fixtures are in `Tests/PandaCoreTests/Fixtures/docker`. They have the shape of real Docker output. All names in them are made up.
  - `inventory-full.json` and `summary-full.jsonl` are a busy engine.
  - `inventory-empty.json` and `summary-empty.jsonl` are an empty engine.
  - `context-local.json` is a local engine. `context-remote-tcp.json` and `context-remote-ssh.json` are remote engines.
- The fake serves one inventory before a delete command and another one after it. Use this to test the measured result.
- The fake records every call. Check `fake.calls` to prove what ran. Check `fake.unexpected` to prove that nothing else ran.
- A remote engine must always give no items and no commands except `context inspect`.
- To add a case, add a fixture file or build one with `DockerJSON`.

## Test Xcode and simulator features

No test may use a real simulator, runtime, or archive. Simulator tests use a fake `xcrun`.

- Make your test class a subclass of `SimctlTestCase`. It hides the real `xcrun`.
- Make the fake with `FakeSimctl` (in `Tests/PandaCoreTests/FakeSimctl.swift`). It answers `simctl runtime list -j` and `simctl list devices -j` from fixture files in `Tests/PandaCoreTests/Fixtures/simctl`.
- The fake serves one answer before a delete command and another one after it. Use this to test the measured result.
- Check `fake.deletes` to prove which delete commands ran. Check `fake.unexpected` to prove that nothing else ran.
- Archives are plain folders. Test them in a `Sandbox` home folder.
- The fixtures follow the key names that the real `simctl` uses. We could not read a real list on a Mac that has runtimes, so if you have one, compare `xcrun simctl runtime list -j` with the fixtures and tell us what differs.

## Safety rules for every change

A pull request must follow these rules. A reviewer checks them.

- **Never delete user data.** Documents, photos, keys, databases, and app settings are out of scope.
- **Choose the tier with care.**
  - `safe` means that the item is cheap to get back. It comes back in seconds, in minutes, or with a download.
  - `review` means that the item is costly to get back, or it can hold data that is not stored elsewhere.
  - If you are not sure, use `review`.
- **Every delete goes through `PathGuard`.** Do not call `FileManager.removeItem` anywhere else.
- **Use fixed commands.** To run a tool, add a case to `OwnerCommand`. Never build a command from a path or from user input.
- **Use the owner tool when the tool keeps state.** Docker, Homebrew, and the simulator are examples.
- **Measure, do not guess.** If a tool keeps files that it never removes, ask the tool what it would free. See the Homebrew code.
- **Add a test that fails without your change.** A new catalog row needs a test. A new safety rule needs a test that tries to break it.
- **Never run a real delete in a test.** Use the `Sandbox` helper. It makes a fake home folder.

## Commit and pull request

- Keep one topic in each pull request.
- Use the present tense in the commit title. Keep it under 72 characters. Example: `Add Zig build folders`.
- Run `swift test` before you push. All tests must pass.
- Use your GitHub no-reply email address in git, so that your private email is not public.
  Find it in GitHub under Settings, then Emails.
- Do not add other app names to code or docs, except in `NOTICE` for credit.

## Licence

Trash Panda uses GPL-3.0. When you send a contribution, you agree that it uses the same licence. If you port code from another project, that project must use a compatible licence. Add its credit to `NOTICE`.

## Report a problem

- For a bug, open an issue. Attach the last lines of the log: `~/Library/Logs/TrashPanda/trashpanda.log`.
- For a **security** problem, do not open a public issue. Read [SECURITY.md](SECURITY.md).
- If the app removed something that it should not remove, treat it as a security problem.

## Behave well

Be kind and be direct. Give feedback on the work, not on the person. Maintainers can remove comments or block users who are not kind.
