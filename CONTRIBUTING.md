# Contributing to Trash Panda

Thank you for your help. Trash Panda deletes files, so we work with care. This guide shows how to help in a safe way.

## Work from the roadmap

All work starts from an issue on the [roadmap](https://github.com/chaitanya-ramji/trashpanda/issues?q=is%3Aissue+label%3Aroadmap). The pinned **Roadmap** issue lists them in order.

1. Pick an open issue. Issues with the label `good first issue` are the best start.
2. Write a comment on the issue to say that you take it.
3. Do the work in a branch. Open a pull request. Write `Closes #<number>` in the description.

If you have an idea that is not on the roadmap, open an issue first. Wait for a reply before you write code. This saves your time.

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

## How the code is organized

| Folder | Content |
| --- | --- |
| `Sources/PandaCore` | Finds items and deletes them. It has all the safety rules. |
| `Sources/TrashPanda` | The menu bar app. It has no logic that deletes files. |
| `Tests/PandaCoreTests` | Unit tests. |
| `docs/` | The spec and the release guide. |

## Add a language

Most languages need data only. Open `Sources/PandaCore/Catalog.swift`.

1. Add a case to `Ecosystem` in `Model.swift`. Give it a short name.
2. Add rows to `Catalog.caches` for global caches. Paths start in the home folder.
3. Add rows to `Catalog.artifacts` for build folders inside projects. Each row needs a marker file.
4. Add a test in `Tests/PandaCoreTests`.
5. Add the language to the table in `README.md`.

A marker file is a file that proves the folder is a project of that language. For example, `Cargo.toml` proves that `target` is a Rust build folder. Never match a folder by name alone.

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
