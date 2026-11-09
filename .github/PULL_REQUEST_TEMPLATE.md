Closes #

## What changed

## Safety check
- [ ] No user data can be deleted by this change.
- [ ] Every delete goes through `PathGuard`.
- [ ] Each new item has the right tier (`safe` or `review`).
- [ ] New commands are fixed cases of `OwnerCommand`.
- [ ] I added a test that fails without this change.
- [ ] `swift test` passes.
