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
- **Three operations only.** The engine moves an item to the Trash (`FileManager.trashItem`), renames it, or moves it within the scanned folder. Never permanently delete a user's file. Rename and move never overwrite an existing item. All three go through `CleanupExecutor`, and a new action states the one operation it uses in its definition (`CleanupAction.definition`); the executor refuses any other.
- **Recheck before acting.** Just before each change, confirm the file still exists and is unchanged since the scan (size and modification date, or content hash where the plan relied on it). If not, skip it and report it.
- **One failure does not stop the rest.** Each item succeeds or fails on its own with a typed error and a message a user can understand. No `try!`, no force unwraps, no `fatalError` on file operations.
- **Idempotent.** Running the action again right after it finishes produces an empty plan.
- **Grace period.** An item added or modified in the last hour is never a candidate. Filter with the shared `CandidateEligibility`, passing the current time in so tests control it, and recheck it at execution with Date Added read from disk; never write a planner's own time rule. To try an action on freshly made files, launch a debug build with `-GracePeriodSeconds <n>`.
- **In-progress downloads.** Files still downloading (`.crdownload`, `.download`, `.part`) are untouched by every action except Clear failed downloads, which has its own rule: it passes `downloads: .allowed` to the shared rules and decides with `FailedDownloadPlanner` (decision record 0010). No other action may pass `.allowed`.
- **The archive.** A folder named `Old downloads` at the top level of the scanned folder is the archive. Neither it nor anything in it is ever a candidate.
- **Kept.** Files the user marked Kept never appear in any plan, as a change or as an unchecked file. Filter with `CandidateEligibility.allows`, which refuses Kept records, and never get round it. Only an action that compares files may let a Kept file take part, and then only as the copy it keeps, as Find Duplicates does (decision record 0009). The executor checks the Kept list again before every change; there is nothing to add for it.
- **One way in.** State the planner in `CleanupPlanners` (`plan` and `hasPlanner`; both switches make that a compile-time duty). The app plans only through it, via the shared `CleanupSearchModel`, which reads the Kept list first. `plan` also takes `installers: InstallerSources` (application folders, facts cache, mount folder, receipts), which only Remove Used Installers reads; tests pass `.testing(...)` so no real folder is read.
- **Planners write nothing.** A planner that learns something worth keeping returns it on the plan (as `installerFactsRead`) and the app stores it afterwards. Add the action to `PlannersRespectKeptTests.plannedActions` in declaration order; the fake folder must give it something to propose.
- **Off the main thread.** Scanning and hashing run in the background with Swift concurrency, support cancellation, and report progress. The window never freezes.
- **Logged and undoable.** Every executed change is recorded in the activity log with enough information to undo it: at least the operation, the original path and where the item went.
- **Stay in scope.** Only act inside the folder the user chose. Follow no symlinks out of it. Leave hidden files and subfolders alone unless the action says otherwise.

## Registering an action

An action is one entry in each of these places, and the compiler points to each switch:

1. **Engine definition:** a case in `CleanupAction` (its declaration order is the menus' order) and its entry in `CleanupAction.definition` (`CleanupActionDefinition.swift`). The entry holds a written-out `identifier`, which the activity log stores and must never change, and the `operation` its plans use.
2. **Planner:** its planner in `CleanupPlanners.plan`, and `true` in `CleanupPlanners.hasPlanner`. Only then do the Clean Up menus offer it.
3. **Executor:**
   - An action that trashes adds its own checks to the `.moveToTrash` switch in `CleanupExecutor.process`, in a file of its own (`CleanupExecutor+Duplicates.swift`, `CleanupExecutor+FailedDownloads.swift`, `CleanupExecutor+UnpackedZips.swift`, `CleanupExecutor+UsedInstallers.swift`).
   - Add that file to `SafetyTests.diskChangeCallers`.
   - Renames and moves share `CleanupExecutor+Relocation.swift`.
4. **App display:** its entry in `CleanupAction.display` (`SmartOSFileStore/CleanupAction+Display.swift`): titles, a one-sentence explanation, an SF Symbol, a free Shift-Command letter, progress words, a `progressStyle` (`.spinner` for a planner that reads no files; for one that reports `CleanupPlanningProgress` through `CleanupPlanners`, `.bytesRead`, `.zipsChecked`, `.installersChecked`, or a count style of its own; `ItemCheckProgress` throttles a count) and empty-preview words. Shortcuts live only in the menu bar's Clean Up menu.
5. **Reasons:** a new `ProposedChange.Reason` case needs a log code in `ActivityLogCodes.swift` and words in `CleanupPlan+Display.swift`. A reason whose change the preview should leave unticked says so through `Reason.isPossibleMatch`. Skip reasons get their words, per action where it matters, from `CleanupSkipReason.localizedDescription(for:)`.
6. **Tests:** a row in `RenameExecutorTests.actionsAllowExactlyTheirOwnOperation`, the identifier in `CleanupActionDefinitionTests`, and `PlannersRespectKeptTests.plannedActions`.

The preview, confirmation, summary, Undo, logging and refresh are shared and need nothing.

## Steps for a new action

1. Write down the behaviour in a few lines first: what it matches, what it proposes, which item it keeps, and its edge cases. If any of that is a product decision the owner has not made, ask before coding.
2. Add the files that exercise it to the test folder (see the `cleanup-test-fixtures` skill), including cases that must not match. Date every intended candidate past the grace period, keeping creation order.
3. Write the planner and its unit tests. Cover the normal case, name clashes, empty input, files that look similar but must not match, a file inside the grace period, the archive folder, a file marked Kept, and idempotence.
4. Write or extend the executor and its tests against a temporary folder. Include a locked file, a file that disappears between plan and execute, and one replaced by a link. For rename and move, add a destination name that is already taken. Store no path with a trailing `/` (`URL.storedPath`): a folder's URL from a listing has one, and `lstat` on it would follow a link.
5. Hook the plan into the existing preview and confirm screens. Reuse them; do not build a new screen per action.
6. Build, test and launch the app (see the `mac-app-build-verify` skill), then try the action by hand on the test folder.
7. Add a short decision record under `docs/decisions/` for each choice the code does not explain by itself.
8. Report what the action does, what it deliberately leaves alone, and any decision the owner still needs to make.

## Duplicate detection specifics

- Duplicates are files with identical content, whatever their names.
- Group by size first, and only hash files that share a size. Hash with SHA-256 from CryptoKit, reading in chunks so large files do not load into memory.
- Keep the copy with the cleanest name (no ` (1)`, ` copy` or similar suffix), with the oldest file as the tiebreak. Propose the others for the Trash.
- Decide and test empty files explicitly; do not let them be grouped by accident.
