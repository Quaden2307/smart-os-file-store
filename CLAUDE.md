# Smart OS File Store

A native macOS file browser that will replace Finder, starting with a self-cleaning Downloads folder. This is a production app that will ship to real users by direct download. Every change is held to a release-quality bar: correct, safe with user files, tested, warning-free and accessible.

## Owner and workflow

- The owner edits in VS Code (Swift extension, SweetPad) and does not use the Xcode editor. Xcode is installed only for building.
- The owner tests by hand. When a change is visible, end with exact steps: what to open, click and expect.
- Work in small segments: one feature per session, ending in a build that runs and a commit.
- If a requirement is unclear or a product decision has not been made, ask before writing code. Do not invent features beyond the request.

## Stack

- Swift 6 language mode with complete strict concurrency. SwiftUI for the app; AppKit only where SwiftUI falls short (for example a large, fast file table).
- XcodeGen: `project.yml` is the source of truth. The generated `.xcodeproj` is not committed. Never edit it by hand.
- Targets: `SmartOSFileStore` (app), `FileStoreCore` (framework: the engine), `FileStoreCoreTests` (unit tests for the engine). Add targets only when asked.
- Deployment target macOS 26.0, Apple silicon. Bundle id `com.quaden2307.SmartOSFileStore`.
- No App Sandbox (direct download, not the Mac App Store). Hardened Runtime on, so the app can be notarized later.
- CryptoKit for hashing, Quick Look for previews, UniformTypeIdentifiers for file types.
- No third-party dependencies without the owner's approval. No database yet; GRDB (SQLite) arrives with the activity log in a later segment.
- Interface uses system colours, fonts and controls only, with light and dark mode. No custom theme yet.

## Architecture

- `FileStoreCore` holds all file logic: scanning, planning and executing. It must not import SwiftUI or AppKit. The app target only calls the engine and shows results. Later, on-device AI will call the same engine actions as tools, so each action is small, single-purpose and has typed inputs and outputs.
- Every cleanup action follows scan, plan, preview, confirm, execute. Nothing on disk changes before the user confirms, and no code path skips the preview. Use the `add-cleanup-action` skill whenever adding or changing a cleanup action.
- Plans are pure values. Planners are pure functions with no file writes.
- Removal always means `FileManager.trashItem`. Never permanently delete a user file, anywhere, for any reason.
- Recheck each file right before acting on it (still exists, same size and modification date). If it changed, skip it and report it.
- Each item succeeds or fails on its own with a typed error and a message a user can understand. One failure never stops the rest.
- Actions are idempotent: running one again right after it finishes produces an empty plan.
- Scanning and hashing run off the main thread with async/await, support cancellation, and never freeze the window. UI state lives on the main actor.
- Stay in scope: act only inside the chosen folder, follow no symlinks out of it, skip hidden files, and never touch files still downloading (`.crdownload`, `.download`, `.part`) or modified in the last few seconds.
- The scanned folder is Downloads by default. Debug builds accept an override (launch argument `-ScanFolder <path>` or environment variable `SMARTOS_SCAN_FOLDER`) so hand testing uses a fake folder. Release builds ignore both.

## Code standards

- No `try!`, no force unwraps, no `fatalError` and no `precondition` on anything involving files or user data.
- Zero compiler warnings. Do not silence a warning with flags, `@preconcurrency`, `nonisolated(unsafe)` or `@unchecked Sendable` unless a comment explains why it is safe.
- Prefer value types and `Sendable` models. Keep files small and named after what they contain.
- Every user-facing string is localizable (String Catalog). Every control has an accessibility label and works from the keyboard.
- Log with `os.Logger` (subsystem = the bundle id). Never log file contents. Treat file paths as private (`privacy: .private`).

## Testing

- Engine code gets unit tests in `FileStoreCoreTests` using Swift Testing.
- Tests only touch temporary folders they create and remove themselves. Never the real Downloads, Desktop, Documents or any other user folder. Use the `cleanup-test-fixtures` skill for the shared fixture helper and the hand-testing folder.
- Never delete, skip or weaken a test to get a pass.

## Done means verified

Before reporting any change as done, follow the `mac-app-build-verify` skill: regenerate, build with zero warnings, run all tests, launch the app. Report what changed, the build result, the test count, and what the owner should check by hand. If a step could not run, say so.

At the end of each segment, run `/code-review` on the diff and fix what it finds. Run `/security-review` before any segment that changes how files are moved, renamed or trashed is committed.

## Git

- One commit per segment, on `main`, with a short imperative message (for example `Add duplicate finder engine`).
- Commit only when the owner says the segment works, or when the prompt says to commit.
- `.gitignore` covers `build/`, `*.xcodeproj`, `DerivedData/`, `.DS_Store`, `xcuserdata/` and `.swiftpm/`.
- Never force-push, never rewrite pushed history, never commit secrets or signing certificates.

## Current scope (version 0.1)

1. A window listing the top level of Downloads: name, type, size, date added, date modified.
2. One cleanup action: find exact duplicates by content. Keep the cleanest-named copy, oldest as tiebreak. Empty files and folders are never duplicate candidates.
3. A preview with checkboxes. Confirmed files go to the Trash and the list refreshes.

Out of scope until the owner asks: activity log, database, undo beyond the Trash, other cleanup actions, folders beyond Downloads, AI features, custom theme.