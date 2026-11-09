# Security Policy

Trash Panda deletes files on your Mac. A fault in the delete code can destroy data. We take reports seriously.

## What counts as a security problem

Please report a problem if the app can do one of these things:

- Delete a file or folder that it should never touch. Examples are documents, photos, keys, databases, and app settings.
- Delete a path outside your home folder.
- Follow a symbolic link or a path trick (such as `..`) to leave the safe area.
- Run a command that an attacker can change. Examples are a command that uses a file name or a project name.
- Act on the wrong Docker engine, for example a remote engine.
- Show a size that makes you delete more than you plan to delete.
- Run with more rights than it needs, or ask for a password.
- Write sensitive data to the log.

A wrong item in a list is a normal bug. Open a public issue for it. If you are not sure, report it as a security problem.

## How to report

**Do not open a public issue.** Use private reporting:

1. Open the [Security tab](https://github.com/chaitanya-ramji/trashpanda/security/advisories/new) of the repository.
2. Click **Report a vulnerability**.
3. Describe the problem. Include these items:
   - The version of Trash Panda and of macOS.
   - The steps to repeat the problem.
   - What you expected and what happened.
   - The last lines of `~/Library/Logs/TrashPanda/trashpanda.log`. Remove any private paths first.

If you cannot use this page, open a public issue that says only "I need a private way to report a security problem". Do not put details in it. We reply with a private way.

## What happens next

| Step | Target time |
| --- | --- |
| We confirm that we received your report | 7 days |
| We tell you if we can repeat the problem | 14 days |
| We publish a fix for a confirmed problem that can lose data | 30 days |

These are targets from a small team of volunteers. We tell you if a step takes longer.

When the fix is out, we publish a security advisory. We credit you by name if you want. We keep your name private if you prefer.

## Supported versions

Only the latest release gets security fixes.

| Version | Supported |
| --- | --- |
| Latest release | Yes |
| Older releases | No. Please update. |

## Safe use

Until a release is notarized by Apple, you must approve the app on first launch. Check the SHA-256 checksum of the DMG against the `.sha256` file on the Releases page. You can also build the app from source.

The app is not sandboxed, because it must read developer folders. It runs with your user rights. It never asks for an administrator password. It never sends data over the network.

## Safe harbor

We will not take legal action against you if you:

- Test only on your own Mac and your own data.
- Report the problem to us in private and give us time to fix it.
- Do not harm other people or access their data.

## Thanks

Thank you for helping to keep developers' files safe.
