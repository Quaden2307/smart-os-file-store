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
- Interface uses system colours, fonts and controls only, with light and dark mode, as `docs/design.md` sets out (see Design below). No custom theme yet.

## Architecture

- `FileStoreCore` holds all file logic: scanning, planning and executing. It must not import SwiftUI or AppKit. The app target only calls the engine and shows results. On-device AI lives in `FileStoreIntelligence` and reaches the engine only through what the app hands it (see Apple Intelligence below), so each engine action stays small, single-purpose and has typed inputs and outputs.
- Every cleanup action follows scan, plan, preview, confirm, execute. Nothing on disk changes before the user confirms, and no code path skips the preview. Use the `add-cleanup-action` skill whenever adding or changing a cleanup action.
- Plans are pure values. Planners are pure functions with no file writes.
- The engine has three operations: move to Trash, rename, and move within the scanned folder, and, for undo only, a fourth: put back from the Trash. Removal always means `FileManager.trashItem`; never permanently delete a user file, anywhere, for any reason. Rename, move and put back never overwrite an existing item.
- Recheck each file right before acting on it (still exists, same size and modification date). If it changed, skip it and report it.
- Each item succeeds or fails on its own with a typed error and a message a user can understand. One failure never stops the rest.
- Actions are idempotent: running one again right after it finishes produces an empty plan.
- Scanning and hashing run off the main thread with async/await, support cancellation, and never freeze the window. UI state lives on the main actor.
- Every plan, run, undo and Kept mark belongs to exactly one managed folder (`ManagedFolder`), known by an ID made once and stored in the activity log, never by its path. Every engine entry point takes the folder it works on. `FolderRegistry` lists the folders (Downloads, Desktop and Documents when turned on, and folders the user added) and is the only code in the engine that asks the system where a standard folder is; `SafetyTests` fails if another does.
- A run belongs to one folder. The executor refuses a change whose file or destination lies outside its plan's folder, and the activity log refuses a run for a folder it does not hold. Undo puts a file back into the folder its run was made in, found by the run's own folder ID whatever the list is now; if that folder is gone, or no longer where the run saw it, undo refuses and says why.
- Which folders may be managed is decided in one place, `FolderSafetyRules`, when a folder is added and every time it is found: never the home folder or a folder that holds it, the top of a disk, anything in a Library or an application, a system location, the Trash, the app's own data, or a folder inside or holding a managed one. Links are resolved first. Downloads gets the same rules. Add a rule there, with a test, and nowhere else.
- No planner reads a cloud placeholder (`FileRecord.isDataless`): reading one would download it. A planner that reads content checks the flag where it would read, and every reader looks (`lstat`) before it opens.
- Stay in scope: act only inside the chosen folder, follow no symlinks out of it, and skip hidden files.
- Grace period: an item added or modified in the last hour is never a candidate for any action. Every planner and the executor's recheck use the one shared eligibility check (`CandidateEligibility`), which takes the current time as a parameter.
- In-progress downloads (`.crdownload`, `.download`, `.part`) are untouched by every action except Clear failed downloads, which has its own rule.
- A folder named "Old downloads" at the top level of the scanned folder is the archive. No action treats it or its contents as a candidate.
- Every executed change is recorded in the activity log with enough information to undo it.
- Files the user marked Keep never appear as a proposed change in any plan.
- Each folder has `FolderRules` (`ManagedFolder.rules`): offered actions, Tidy Now actions, whether previews tick, and its own thresholds. `CleanupPlanners` and `TidyNowPlanner` enforce them, so no caller plans an action a folder does not offer. A preview's default ticks come only from `CleanupPlan.defaultTickedIDs`; Documents and custom folders tick nothing.
- Code ticks only changes whose reason is `isTickedByCode`: the preview's default, Select All and Tidy Now. Review-only changes (near-duplicates, large downloads) and possible installer matches are ticked by the user, one by one.
- In one Tidy Now run, the item a trashed zip was unpacked to and the kept copy of a duplicate group are never trashed by a lower-priority action (`TidyNowPlan.resolve`).
- Each segment adds a short decision record under `docs/decisions/` (what was decided, the alternatives, why).
- The app shows each managed folder in the sidebar, with its own list (`FolderListsModel`). Debug builds accept overrides so hand testing uses fake folders and never the real ones: `-DemoHome <path>` (or `SMARTOS_DEMO_HOME`) makes `<path>/Downloads`, `<path>/Desktop` and `<path>/Documents` the three standard folders; `-ScanFolder <path>` (or `SMARTOS_SCAN_FOLDER`) makes one folder Downloads, with no Desktop or Documents; `-GracePeriodSeconds <n>` lets freshly made files be candidates; `-ApplicationsFolder <path>` makes Remove Used Installers look for installed apps in a fake Applications folder. Of the folder overrides the first that is set applies, in the order `-DemoHome`, `-ScanFolder`, `SMARTOS_DEMO_HOME`, `SMARTOS_SCAN_FOLDER`, and an override that cannot be used never falls back to the real folders. Each override has its own temporary activity log. Also debug only: `-StartPlace`, `-TurnOnStandardFolders` and `-SnapshotTo <name>` (the window drawn off screen and printed as base64 PNG). Release builds ignore all of them.

## Apple Intelligence

- **The model proposes and never executes.** `FileStoreIntelligence` imports none of our modules, so it cannot name the executor, `DiskChange`, the activity log or GRDB. The app hands it plain rows (`FolderSnapshot`) and, when a tool needs the engine, a function. A cleanup asked for in the chat is planned by the app (`TidyNowPlanner` with the actions and files asked for), which keeps the plan; the module gets rows and a card id. Only the user's Confirm, in the app, carries a plan out. `BoundaryTests` and the build setting `DIAGNOSE_MISSING_TARGET_DEPENDENCIES` fail the moment that changes. `FileStoreCore` and the app never import `FoundationModels`.
- **Names and contents of files are untrusted data.** Anything read from the disk reaches the model only through `ToolOutput`: cleaned of control and invisible characters, cut short, and inside the delimiters that the instructions describe as data.
- **Numbers and file lists shown to the user come from code, never from model text.** Tools write their full results to `TurnEffects`, the app draws from that, and the model gets only a short capped summary. Counting, summing, sorting and dates are done in code.
- **Prompt templates live in one file with versions** (`PromptLibrary.swift`), and a changed template gets a new version. `PromptLibraryTests` pins each one's hash.
- **Instructions and tool definitions stay within 42% of the model's context** (`ChatEngine.fixedPromptShare`, decision 0023). Measure after any change to a template, a tool or an argument (README, Chat measurements). How to word a reply after a tool goes in that tool's output, not in the instructions, where it leaks into every answer.
- **Nothing leaves the Mac:** the on-device `SystemLanguageModel` only. No Private Cloud Compute and no third-party models.
- **Check SDK names before using an API named in a plan.** Read the Foundation Models interface in the installed Xcode SDK first, follow the SDK where it differs, and list each difference in the segment's decision record.
- Tests and CI never need Apple Intelligence: a scripted model that conforms to the framework's `LanguageModel` drives the real session and tool loop.

## Design

- `docs/design.md` is the source for how the app looks: the rules, the tokens with their values, the standard components and the copy rules. Read it before adding or changing a view.
- Every view takes its fonts, colours, spacing, radii and animations from `SmartOSFileStore/DesignTokens.swift` (`Design`). `DesignTokenTests` fails on a raw value. When a view needs a value that does not exist, add it to the tokens and to `docs/design.md` first.
- Animations go through `.motion(_:value:)`, which does nothing when Reduce Motion is on.
- A result is summarised in a `Card`, a sheet is a `SheetScaffold` in one of three sizes, work in progress is a `ProgressLine`, and an empty, loading, failed or blocked screen is a `StateView` with at most one action. Do not write a card outline, a sheet frame or a state by hand.
- Text inside windows and sheets is sentence case. Menus (menu bar, toolbar menu, context menus) keep the Mac's Title Case. One word for one thing: see Copy in `docs/design.md`.
- The chat bar keeps its own values in `Design.Chat`, some of them off the grid. It is the one exception; nothing else uses them.

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

10. A chat bar that answers questions about the managed folders with the on-device model. It remembers the conversation in app code (`ChatMemory`): follow-ups such as "only the big ones" search inside the last result, and "Continue" asks a stopped question again.
11. Cleanups from the chat bar: `proposeCleanup` makes a card in the conversation (what the app understood, the actions with counts, Review, Confirm). Confirm asks once, the card becomes the run's summary with Undo, and the run is marked as started from chat in Activity. A card goes out of date when a file of it changes or a newer card replaces it, and then offers Refresh.

12. A design system: tokens, `docs/design.md` and a check that views use them, with the main window's shell (sidebar, toolbar, file table, filter bar, status bar) restyled on it.
13. Shared components for every result, sheet, progress line and state (`Card`, `SheetScaffold`, `ProgressLine`, `StateView`), a welcome shown once (`FirstRun`), an About line and an app icon. Settings is on the tokens but not yet redesigned.
14. Managed folders in the engine (Folders, segment 1): `ManagedFolder`, `FolderRegistry`, `FolderSafetyRules`, a folder ID on every run, change and Kept mark, undo into the run's own folder, and the `-DemoHome` override.
15. Desktop, Documents and folders the user adds, in the app (Folders, segment 2): a Folders sidebar section, turning Desktop and Documents on, permission states, Add Folder (button, File menu, drag from Finder), rename and remove, unavailable folders, and a folder name and filter in Activity.
16. Per-folder cleanup rules (Folders, segment 3): `FolderRules` with tested defaults per kind, stored in the log, enforced by the planners, and a Folders pane in Settings.
17. The chat across folders (Folders, segment 4): `searchFiles`, `findDuplicates` and `proposeCleanup` take a folder (on screen, named, or all); one card per folder; folder rules respected; per-folder subtotals.
18. A storage view (Visualizations, segment 1): what is taking space per folder and kind, what each cleanup could get back (counted as previews tick, each file once), and the largest files, with Swift Charts.
19. Cleanup insights (Visualizations, segment 2): daily totals from the log (undo subtracted on its day), kept through pruning in `dailyTotals`, shown at the top of Activity as headlines, a twelve-week chart and breakdowns.

Out of scope until the owner asks: watching Downloads automatically, user-defined rules, schedules, cloud-drive folders, automatic or scheduled rules, an archive name of its own for each kind of folder, undo that follows a folder that has moved, subfolders, search, tags, sharing, AI that makes a change without the user's Confirm, changing a card by talking (`reviseCleanup`), AI that reads file contents, custom theme.

Features the owner has noted for later are in `docs/backlog.md`: opening an Activity entry for its details (2026-11-14), and undoing more than the last cleanup with repeated ⌘Z (2026-11-15). None is part of any segment yet; ask before starting one. When the owner notes a new idea for later, add it there.