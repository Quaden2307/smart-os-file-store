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
- Targets: `SmartOSFileStore` (app), `FileStoreCore` (framework: the engine), `FileStoreCoreTests` (unit tests for the engine), `FileStoreIntelligence` (framework: the Apple Intelligence chat, with no dependency on any other target of ours) and `FileStoreIntelligenceTests`. Add targets only when asked.
- Deployment target macOS 27.0, Apple silicon. Bundle id `com.quaden2307.SmartOSFileStore`.
- No App Sandbox (direct download, not the Mac App Store). Hardened Runtime on, so the app can be notarized later.
- CryptoKit for hashing, Quick Look for previews, UniformTypeIdentifiers for file types.
- No third-party dependencies without the owner's approval. GRDB (SQLite) is approved and is the only one. It is pinned to the commit of one release in `project.yml` and linked to `FileStoreCore` only; only the activity log's files (`ActivityLog*.swift`) import it, as `internal import GRDB`.
- Interface uses system colours, fonts and controls only, with light and dark mode. No custom theme yet.

## Architecture

- `FileStoreCore` holds all file logic: scanning, planning and executing. It must not import SwiftUI or AppKit. The app target only calls the engine and shows results. On-device AI lives in `FileStoreIntelligence` and reaches the engine only through what the app hands it (see Apple Intelligence below), so each engine action stays small, single-purpose and has typed inputs and outputs.
- Every cleanup action follows scan, plan, preview, confirm, execute. Nothing on disk changes before the user confirms, and no code path skips the preview. Use the `add-cleanup-action` skill whenever adding or changing a cleanup action.
- Plans are pure values. Planners are pure functions with no file writes.
- The engine has three operations: move to Trash, rename, and move within the scanned folder, and, for undo only, a fourth: put back from the Trash. Removal always means `FileManager.trashItem`; never permanently delete a user file, anywhere, for any reason. Rename, move and put back never overwrite an existing item.
- Recheck each file right before acting on it (still exists, same size and modification date). If it changed, skip it and report it.
- Each item succeeds or fails on its own with a typed error and a message a user can understand. One failure never stops the rest.
- Actions are idempotent: running one again right after it finishes produces an empty plan.
- Scanning and hashing run off the main thread with async/await, support cancellation, and never freeze the window. UI state lives on the main actor.
- Stay in scope: act only inside the chosen folder, follow no symlinks out of it, and skip hidden files.
- Grace period: an item added or modified in the last hour is never a candidate for any action. Every planner and the executor's recheck use the one shared eligibility check (`CandidateEligibility`), which takes the current time as a parameter.
- In-progress downloads (`.crdownload`, `.download`, `.part`) are untouched by every action except Clear failed downloads, which has its own rule.
- A folder named "Old downloads" at the top level of the scanned folder is the archive. No action treats it or its contents as a candidate.
- Every executed change is recorded in the activity log with enough information to undo it.
- Files the user marked Keep never appear as a proposed change in any plan.
- Code ticks only changes whose reason is `isTickedByCode`: the preview's default, Select All and Tidy Now. Review-only changes (near-duplicates, large downloads) and possible installer matches are ticked by the user, one by one.
- In one Tidy Now run, the item a trashed zip was unpacked to and the kept copy of a duplicate group are never trashed by a lower-priority action (`TidyNowPlan.resolve`).
- Each segment adds a short decision record under `docs/decisions/` (what was decided, the alternatives, why).
- The scanned folder is Downloads by default. Debug builds accept an override (launch argument `-ScanFolder <path>` or environment variable `SMARTOS_SCAN_FOLDER`) so hand testing uses a fake folder, `-GracePeriodSeconds <n>` so freshly made files can be candidates, and `-ApplicationsFolder <path>` so Remove Used Installers looks for installed apps in a fake Applications folder. Release builds ignore all four.

## Apple Intelligence

- **The model proposes and never executes.** `FileStoreIntelligence` imports none of our modules, so it cannot name the executor, `DiskChange`, the activity log or GRDB. The app hands it plain rows (`FolderSnapshot`) and, when a tool needs the engine, a function. `BoundaryTests` and the build setting `DIAGNOSE_MISSING_TARGET_DEPENDENCIES` fail the moment that changes. `FileStoreCore` and the app never import `FoundationModels`.
- **Names and contents of files are untrusted data.** Anything read from the disk reaches the model only through `ToolOutput`: cleaned of control and invisible characters, cut short, and inside the delimiters that the instructions describe as data.
- **Numbers and file lists shown to the user come from code, never from model text.** Tools write their full results to `TurnEffects`, the app draws from that, and the model gets only a short capped summary. Counting, summing, sorting and dates are done in code.
- **Prompt templates live in one file with versions** (`PromptLibrary.swift`), and a changed template gets a new version. `PromptLibraryTests` pins each one's hash.
- **Nothing leaves the Mac:** the on-device `SystemLanguageModel` only. No Private Cloud Compute and no third-party models.
- **Check SDK names before using an API named in a plan.** Read the Foundation Models interface in the installed Xcode SDK first, follow the SDK where it differs, and list each difference in the segment's decision record.
- Tests and CI never need Apple Intelligence: a scripted model that conforms to the framework's `LanguageModel` drives the real session and tool loop.

## Code standards

- No `try!`, no force unwraps, no `fatalError` and no `precondition` on anything involving files or user data.
- Zero compiler warnings. Do not silence a warning with flags, `@preconcurrency`, `nonisolated(unsafe)` or `@unchecked Sendable` unless a comment explains why it is safe.
- Prefer value types and `Sendable` models. Keep files small and named after what they contain.
- Every user-facing string is localizable (String Catalog). Every control has an accessibility label and works from the keyboard.
- Log with `os.Logger` (subsystem = the bundle id). Never log file contents. Treat file paths as private (`privacy: .private`).

## Testing

- Engine code gets unit tests in `FileStoreCoreTests` using Swift Testing. Chat code gets them in `FileStoreIntelligenceTests`.
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

## Current scope (version 0.3, in progress)

Everything in version 0.1:

1. A window listing the top level of Downloads: name, type, size, date added, date modified.
2. Find exact duplicates by content. Keep the cleanest-named copy, oldest as tiebreak. Empty files and folders are never duplicate candidates.
3. A preview with checkboxes. Confirmed files go to the Trash and the list refreshes.

Plus:

4. Six cleanup actions: clear failed downloads, remove unpacked zips, remove used installers, fix messy names, flag near-duplicates, archive old downloads.
5. Two review lists: large downloads and empty folders.
6. In the file list: a Last Opened column, the download source, and marks.
7. Keep this file.
8. A local database with an activity log, undo, and a space freed counter.
9. A Tidy Now overview.

And from version 0.3 so far:

10. A chat bar that answers questions about Downloads with the on-device model. It only looks things up; it changes nothing on disk.

Out of scope until the owner asks: watching Downloads automatically, user-defined rules, schedules, folders beyond Downloads, subfolders, the full storage view, search, tags, sharing, AI that proposes or makes changes, AI that reads file contents, custom theme.

Features the owner has noted for later are in `docs/backlog.md`: opening an Activity entry for its details (2026-11-14), and undoing more than the last cleanup with repeated ⌘Z (2026-11-15). None is part of any segment yet; ask before starting one. When the owner notes a new idea for later, add it there.