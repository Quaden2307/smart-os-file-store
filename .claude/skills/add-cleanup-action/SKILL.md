---
name: add-cleanup-action
description: Use when adding or changing a file cleanup action in Smart OS File Store (duplicates, renames, installers, zips, stale files) so each one follows the same plan, preview, confirm, execute pattern with tests.
---

# Add a cleanup action

Every cleanup action in this app follows one pattern, so that preview, confirmation, logging, undo and later AI control work the same way for all of them. If the pattern already exists in the code, match it exactly. If this is the first action, establish it as described here.

## The pattern

1. **Scan** reads the folder and produces plain file records (path, name, size, dates, type). It changes nothing.
2. **Plan** takes file records and returns a list of proposed changes. It is a pure function with no file writes, so it is fast to test.
3. **Preview** shows the plan to the user: what stays, what changes, and why. The user can untick any item.
4. **Execute** carries out only the confirmed items and returns a result per item.

Nothing on disk changes before the user confirms. There is no code path that skips the preview.

## Rules that always apply

- **Engine and interface stay separate.** Scan, plan and execute live in the engine and import no SwiftUI or AppKit interface code. Views only call the engine and display results.
- **Removal means the Trash.** Use `FileManager.trashItem`. Never permanently delete a user's file.
- **Recheck before acting.** Just before each change, confirm the file still exists and is unchanged since the scan (size and modification date, or content hash where the plan relied on it). If not, skip it and report it.
- **One failure does not stop the rest.** Each item succeeds or fails on its own with a typed error and a message a user can understand. No `try!`, no force unwraps, no `fatalError` on file operations.
- **Idempotent.** Running the action again right after it finishes produces an empty plan.
- **Never touch files in use.** Skip files still downloading (`.crdownload`, `.download`, `.part`) and files modified in the last few seconds.
- **Off the main thread.** Scanning and hashing run in the background with Swift concurrency, support cancellation, and report progress. The window never freezes.
- **Each proposed change records enough to undo it** (original path and name), even before an undo feature exists.
- **Stay in scope.** Only act inside the folder the user chose. Follow no symlinks out of it. Leave hidden files and subfolders alone unless the action says otherwise.

## Steps for a new action

1. Write down the behaviour in a few lines first: what it matches, what it proposes, which item it keeps, and its edge cases. If any of that is a product decision the owner has not made, ask before coding.
2. Add the files that exercise it to the test folder (see the `cleanup-test-fixtures` skill), including cases that must not match.
3. Write the planner and its unit tests. Cover the normal case, name clashes, empty input, files that look similar but must not match, and idempotence.
4. Write or extend the executor and its tests against a temporary folder, including a locked file and a file that disappears between plan and execute.
5. Hook the plan into the existing preview and confirm screens. Reuse them; do not build a new screen per action.
6. Build, test and launch the app (see the `mac-app-build-verify` skill), then try the action by hand on the test folder.
7. Report what the action does, what it deliberately leaves alone, and any decision the owner still needs to make.

## Duplicate detection specifics

- Duplicates are files with identical content, whatever their names.
- Group by size first, and only hash files that share a size. Hash with SHA-256 from CryptoKit, reading in chunks so large files do not load into memory.
- Keep the copy with the cleanest name (no ` (1)`, ` copy` or similar suffix), with the oldest file as the tiebreak. Propose the others for the Trash.
- Decide and test empty files explicitly; do not let them be grouped by accident.
