# Plan: Segment 1, list the files in Downloads

## Context

The project skeleton exists (commit `fbf797b`): XcodeGen spec, a placeholder `ContentView`, the `FileStoreCore` framework with one type (`ScanLocation`, which resolves Downloads or the debug override), and 7 passing tests. This segment adds the first real feature: a read-only listing of the top level of Downloads in a sortable table, with Quick Look, Reveal in Finder, Refresh, loading / empty / error states, and a fixture helper plus hand-testing script that every later cleanup segment will reuse. **Nothing in this segment writes, moves or deletes a user file.** The only writes are by tests and the script, inside folders they create under the system temporary directory.

The owner asked for the plan to live in `plans/`. Plan mode only allows writing this file, so step 0 copies it into the project as `plans/2026-11-12-list-downloads.md` (same naming as `plans/2026-11-12-set-up-project.md`).

### Facts verified on this machine (2026-11-12)

| Item | Finding |
|---|---|
| Toolchain | Xcode 27.2 (27B52), Swift 6.4.2, xcodegen at `/opt/homebrew/bin`, remote `origin` → `Quaden2307/smart-os-file-store` |
| Symlinks | `URL.resourceValues` describes the link itself: a link to a folder reports `isDirectory=false`, `isSymbolicLink=true`, type `public.symlink`, description "Alias". The scanner therefore never follows links. |
| Packages | A bare directory named `Fake.app` reports `isPackage=true`, type `com.apple.application-bundle`, description "Application". |
| Errors from `contentsOfDirectory` | Missing folder: `NSCocoaErrorDomain` 260, underlying POSIX 2 (ENOENT). No permission: `NSCocoaErrorDomain` 257, underlying POSIX 13 (EACCES); a TCC denial of Downloads surfaces the same way with POSIX 1 (EPERM). |
| `addedToDirectoryDateKey` | Populated for files created in a `mktemp` folder (APFS), so fixtures have a Date Added. |
| `KeyPathComparator` | Has an initializer for optional `Comparable` key paths, so `Int64?` and `Date?` columns sort without a custom comparator. `TableColumn(_:sortUsing:content:)` and `TableColumn(_:value:comparator:content:)` both exist. |
| `UTType` | Is `Sendable`; `FileRecord` can hold one and stay `Sendable`. |
| Quick Look in SwiftUI | `.quickLookPreview(_:)` and `.quickLookPreview(_:in:)` live in the `_QuickLook_SwiftUI` cross-import overlay: a file that imports both `SwiftUI` and `QuickLook` gets them. No AppKit panel code needed. |
| `@concurrent` | Compiles with typed throws under `-swift-version 6 -strict-concurrency=complete`. It guarantees the scan runs off the caller's actor whatever the "approachable concurrency" settings are. |
| SwiftUI `Table` | `Table(_:selection:sortOrder:columns:)`, `.contextMenu(forSelectionType:menu:primaryAction:)` (double click = `primaryAction`), `.onKeyPress(.space)`, `.focusedSceneValue` all present. |

### Decisions (plain-language notes for the owner; say if you want any changed)

- **Display name** is the file name exactly as on disk (`report (1).pdf`), not Finder's prettified name that can hide the extension. The cleanup actions later key off real names, so the list shows real names.
- **Kind column** shows macOS's own description of the type ("PDF document", "Folder", "Application", "Alias" for a symlink). If macOS has none, a short fallback ("File", "Folder", "Alias", "Package") is shown.
- **Packages** are folders that macOS shows as a single item (an `.app` is one). Sizing a package means reading inside it, which this segment must not do, so packages show a dash for Size like folders.
- **Date Added** can be missing on some disks; the cell then shows a dash and sorts last.
- **Selection** allows several rows (Shift / Command click, Command-A), like Finder. Quick Look previews all selected items (arrow keys move between them); Reveal in Finder selects them all.
- **Refresh keeps the current rows on screen** with a small spinner in the status line, and only shows the full-window progress indicator on the first load. This avoids the table flashing empty on every Command-R.
- **Privacy pane button** opens `x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders` (the "Files and Folders" page of Privacy & Security). "TCC" below means macOS's per-app permission system that produces the "would like to access your Downloads folder" dialog.
- **Window default size** grows from 720×480 to 960×600 so five columns fit without truncation.
- **Script extras**: `scripts/make-fake-downloads.sh` is the skill's script plus one `partial.part` file (the third in-progress extension named in CLAUDE.md) and an optional `EXTRA_FILES=N` environment variable that adds N tiny files, used for the 5,000-row check the prompt asks for. The test helper mirrors the script, except `big-video.mov` is 1 MiB instead of 200 MB so tests stay fast.
- **No `/security-review` this segment**: CLAUDE.md requires it only before segments that move, rename or trash files. This one is read-only. `/code-review` does run.

---

## Steps (in order)

### 0. Copy this plan into the project
Write this file to `plans/2026-11-12-list-downloads.md`.

### 1. Engine: `FileStoreCore` (Foundation + UniformTypeIdentifiers only, no SwiftUI/AppKit)

**`FileStoreCore/FileRecord.swift`**
```swift
public struct FileRecord: Sendable, Identifiable, Hashable {
    public enum Kind: Sendable, Hashable { case file, folder, symlink, package }

    public var id: URL { url }
    public let url: URL
    public let displayName: String            // url.lastPathComponent
    public let kind: Kind
    public let localizedTypeDescription: String?
    public let contentType: UTType?
    public let sizeInBytes: Int64?            // nil for folders and packages
    public let dateAdded: Date?
    public let dateModified: Date?
    public let isDownloading: Bool

    public init(url:displayName:kind:localizedTypeDescription:contentType:sizeInBytes:dateAdded:dateModified:isDownloading:)

    /// True for the extensions browsers use while a download is still in progress.
    public static func isInProgressDownload(_ url: URL) -> Bool   // crdownload, download, part; case-insensitive
}
```
Kind precedence when reading resource values: symlink → package → folder → file (a package is also a directory, so package is checked before folder). An internal `init(url:resourceKeys:) throws` reads `url.resourceValues(forKeys:)` and builds the record; it is what the scanner calls.

**`FileStoreCore/FolderScanError.swift`**
```swift
public enum FolderScanError: Error, Sendable, Equatable {
    case folderNotFound(URL)                     // Cocoa 260 / ENOENT
    case accessDenied(URL)                       // Cocoa 257 / EACCES / EPERM (TCC denial)
    case folderUnreadable(URL, reason: String)   // any other listing failure
    case itemUnreadable(URL, reason: String)     // per item; reported, never thrown
    case cancelled
}
```
Mapping lives in an internal `init(listingError: any Error, folder: URL)` that inspects `NSError` domain/code and the underlying POSIX code.

**`FileStoreCore/FolderScanResult.swift`**
```swift
public struct FolderScanResult: Sendable, Equatable {
    public struct SkippedItem: Sendable, Equatable, Identifiable { public let url: URL; public let error: FolderScanError; public var id: URL { url } }
    public let folderURL: URL
    public let records: [FileRecord]
    public let skippedItems: [SkippedItem]
    public let scannedAt: Date
}
```

**`FileStoreCore/FolderScanner.swift`**
```swift
public struct FolderScanner: Sendable {
    public static let resourceKeys: Set<URLResourceKey> = [
        .addedToDirectoryDateKey, .contentModificationDateKey, .fileSizeKey, .contentTypeKey,
        .localizedTypeDescriptionKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey]

    public init()

    /// Lists the top level of `location.folderURL`. Never descends, never follows symlinks, skips hidden items.
    @concurrent
    public func scan(_ location: ScanLocation) async throws(FolderScanError) -> FolderScanResult
}
```
Behaviour:
- `if Task.isCancelled { throw .cancelled }` at the start, every 64 items, and once more before returning (typed throws means `Task.checkCancellation()` cannot be used directly).
- `FileManager.default.contentsOfDirectory(at:includingPropertiesForKeys:options: [.skipsHiddenFiles])`. A failure here maps to `folderNotFound` / `accessDenied` / `folderUnreadable` and ends the scan.
- Per item: build the `FileRecord`; if `isHidden` is somehow true, skip silently (belt and braces); if reading resource values throws, append a `SkippedItem` with `.itemUnreadable` and continue. One bad item never fails the scan.
- Records come back in file-system order; sorting is the app's job.
- `os.Logger(subsystem: "com.quaden2307.FileStoreCore", category: "FolderScanner")` logs item count, skipped count and duration (via `ContinuousClock`). Paths use `privacy: .private`; never contents.

### 2. Tests: `FileStoreCoreTests` (Swift Testing)

**`FileStoreCoreTests/Support/TemporaryFolder.swift`**: move `withTemporaryFolder` out of `ScanLocationTests.swift` (where it is `private`) and add an `async` overload. `ScanLocationTests` keeps using it unchanged.

**`FileStoreCoreTests/Support/FakeDownloadsFolder.swift`**: the shared fixture helper required by the `cleanup-test-fixtures` skill. Builds the exact layout of `scripts/make-fake-downloads.sh` in a fresh `mktemp`-style folder under `FileManager.default.temporaryDirectory`, exposes the names as constants (`FakeDownloadsFolder.Names.reportPDF`, `.hiddenFile`, `.symlink`, `.unicodePDF`, …) and removes everything afterwards, clearing the immutable flag on `locked.txt` first (`FileManager.setAttributes([.immutable: false])`). `withFakeDownloadsFolder { fixture in … }` wraps make + remove. Only difference from the script: `big-video.mov` is 1 MiB.

**`FileStoreCoreTests/FolderScannerTests.swift`** (12 tests, each on its own temporary folder):

| Test | Asserts |
|---|---|
| `listsNormalFilesWithMetadata` | `report.pdf`: kind `.file`, size 21, `contentType == .pdf`, non-nil type description, non-nil dateAdded and dateModified, `isDownloading == false`, `id == url` |
| `listsFolderWithoutSize` | `Subfolder` and `project`: kind `.folder`, size nil |
| `reportsPackageAsPackage` | temp folder with a bare `Fake.app` directory → kind `.package`, size nil |
| `reportsSymlinkWithoutFollowing` | `report-link.pdf`: kind `.symlink`; a second link pointing at a folder outside the fixture is still `.symlink`, not `.folder` |
| `skipsHiddenFiles` | no record named `.hidden-file` |
| `doesNotListSubfolderContents` | no record whose URL is under `Subfolder/` or `project/`; count matches the top-level fixture count |
| `keepsUnicodeName` | a record with `displayName == "résumé – final ✓.pdf"` exists (Swift `==` is normalization-aware) |
| `flagsInProgressDownloads` | `.crdownload`, `.download`, `.part` records are `isDownloading`; `report.pdf` is not |
| `emptyFolderGivesNoRecords` | records and skippedItems both empty, `folderURL` matches |
| `missingFolderIsTypedError` | `#expect(throws: FolderScanError.folderNotFound(url))` |
| `unreadableFolderIsAccessDenied` | folder with permissions `0o000` → `.accessDenied(url)`; permissions restored in `defer` so cleanup works |
| `cancelledScanThrowsCancelled` | a `Task` that cancels itself (`withUnsafeCurrentTask { $0?.cancel() }`) before calling `scan` → `.cancelled`. Deterministic: no timing race. |

Expected total after this segment: **19 tests** (7 existing + 12 new).

### 3. Script: `scripts/make-fake-downloads.sh`
`#!/bin/bash`, `set -euo pipefail`, executable bit set. Body is the skill's script verbatim, then `printf 'partial' > "partial.part"`, then the optional `EXTRA_FILES` loop (`bulk-00001.txt` …). Ends by printing the folder path and the exact removal command (`chflags nouchg "$F/locked.txt" && rm -rf "$F"`). Header comment: the folder always comes from `mktemp`; never point this at a real folder. Add a short "Hand testing" note to `README.md` pointing at the script (one sentence; the README already explains `-ScanFolder`).

### 4. App: `SmartOSFileStore`

| File | Contents |
|---|---|
| `FileListModel.swift` | `@MainActor @Observable final class`. Holds `location: Result<ScanLocation, ScanLocationError>` (resolved once at init), `records`, `skippedItems`, `isLoading`, `hasLoadedOnce`, `failure: ScanFailure?`, `sortOrder: [KeyPathComparator<FileRecord>]` (default `KeyPathComparator(\.dateAdded, order: .reverse)`), a stored `sortedRecords` re-sorted only when `records` or `sortOrder` change, `itemCount`, `totalBytes`. `refresh()` cancels the in-flight `Task`, starts a new one that awaits `FolderScanner().scan(location)`, then updates state on the main actor. `.cancelled` from a superseded scan is ignored, not shown as an error. |
| `ScanFailure.swift` | App-side enum wrapping `ScanLocationError` and `FolderScanError` into a localized `message` (`String(localized:)`) plus `isPermissionDenied` and `canRetry`. Keeps every user-facing sentence in the app's String Catalog, as CLAUDE.md requires. |
| `ContentView.swift` | Switches on model state: first load → `ProgressView("Loading…")`; failure → `ScanErrorView`; loaded with no rows → `ContentUnavailableView("Folder Is Empty", …)`; otherwise `FileTableView`. Always shows `StatusBar` underneath. Toolbar: Refresh button (`Label("Refresh", systemImage: "arrow.clockwise")`, `.keyboardShortcut("r")`, `.help`, `.accessibilityLabel`). Publishes the selected URLs with `.focusedSceneValue(\.selectedFileURLs, …)` for the menu command. |
| `FileTableView.swift` | `Table(model.sortedRecords, selection: $selection, sortOrder: $model.sortOrder)` with columns Name (`FileIconView` + name), Kind, Size (`sizeInBytes.formatted(.byteCount(style: .file))` or "—"), Date Added, Date Modified (`.formatted(date: .abbreviated, time: .shortened)` or "—"). `.contextMenu(forSelectionType: FileRecord.ID.self) { ids in Button("Reveal in Finder") … } primaryAction: { ids in quickLook(ids) }` (double click). `.onKeyPress(.space) { quickLook(selection); return .handled }`. `.quickLookPreview($previewItem, in: previewItems)` with `import QuickLook`. `.accessibilityLabel("Files")`. |
| `FileIconView.swift` | `Image(nsImage:)` from `NSWorkspace.shared.icon(forFile:)` via a small `@MainActor` dictionary cache keyed by URL, cleared on each refresh. The `Table` is lazy, so only visible rows pay. If scrolling 5,000 rows still stutters during verification, fall back to `icon(for: UTType)` (type icon, no disk access) and say so in the report. Only file in the app that imports AppKit besides `RevealInFinder`. |
| `RevealInFinder.swift` | `NSWorkspace.shared.activateFileViewerSelecting(urls)` behind one function, plus the `FocusedValues` key `selectedFileURLs`. |
| `ScanErrorView.swift` | `ContentUnavailableView` with the failure message, a Retry button, and, when `isPermissionDenied`, an "Open Privacy Settings" button that opens the Files and Folders pane URL (guarded `if let url = URL(string:)`, no force unwrap) with an explanation that macOS blocked access to Downloads and how to allow it. |
| `StatusBar.swift` | "12 items, 214.5 MB" built from `itemCount` and `totalBytes`; a "N items could not be read" note when `skippedItems` is non-empty; a small `ProgressView` while refreshing. `#if DEBUG` second line: "Scanning: /path (launch argument / environment variable / Downloads)". All text has accessibility labels. |
| `SmartOSFileStoreApp.swift` | `.defaultSize(width: 960, height: 600)`; `.commands { CommandGroup(after: .newItem) { RevealInFinderCommand() } }` where the command reads `@FocusedValue(\.selectedFileURLs)`, is disabled when empty, shortcut Command-Option-R. |

Rules honoured: no `try!`, force unwraps, `fatalError` or `precondition`; every string is a `LocalizedStringKey` or `String(localized:)` so the build adds it to `Localizable.xcstrings` (the two placeholder strings from segment 0 become stale and are removed from the catalog JSON after the first build); system colours and controls only; `os.Logger(subsystem: "com.quaden2307.SmartOSFileStore", category: "FileList")` for state transitions, paths `.private`.

Keyboard path: Tab reaches the Refresh button and then the table; arrow keys and type-to-select move the selection; Space opens Quick Look; Command-R refreshes; Command-Option-R reveals; Command-A selects all; column headers are reachable with VoiceOver and sort on activation.

### 5. Verify (`mac-app-build-verify` skill)
1. `xcodegen generate`
2. `xcodebuild -scheme SmartOSFileStore -destination 'platform=macOS' -derivedDataPath build build 2>&1 | tail -40` → zero errors, zero warnings (warnings are errors in `project.yml`). Also `-configuration Release build` once, to prove the `#if DEBUG` status line compiles out.
3. `xcodebuild … test 2>&1 | tail -60` → 19 tests pass.
4. `F=$(scripts/make-fake-downloads.sh | awk '/Test folder/ {print $3}')`, then `open build/Build/Products/Debug/SmartOSFileStore.app --args -ScanFolder "$F"`. Confirm the process is alive (`pgrep -x SmartOSFileStore`), capture the window with `screencapture` and inspect it: the fixture's top-level items are listed, `.hidden-file` and `Subfolder/report.pdf` are not, folders show a dash, the debug line names `$F`. Quit the app and remove `$F` with the printed command.
5. 5,000-row check: `EXTRA_FILES=5000 scripts/make-fake-downloads.sh`, launch the same way, read the scan duration from `log show --predicate 'subsystem == "com.quaden2307.FileStoreCore"' --last 5m`, and screenshot after load. Report the numbers. If the main thread visibly stalls or the SwiftUI table cannot keep up, switch `FileTableView` to an `NSTableView` wrapper and explain why in the report (the prompt's rule).
6. The run against the real Downloads folder is left to the owner (step 7 below), because it triggers the macOS permission dialog on their screen.
7. `/code-review` on the diff; fix findings; rerun steps 1–3.

### 6. Report and wait
Report what changed, build result, test count, what was checked in the running app, and the hand-check list below. **Do not commit** until the owner says go; then `git add -A && git commit -m "Add Downloads file list"` on `main`.

---

## Files

New:
```
plans/2026-11-12-list-downloads.md
scripts/make-fake-downloads.sh
FileStoreCore/FileRecord.swift
FileStoreCore/FolderScanError.swift
FileStoreCore/FolderScanResult.swift
FileStoreCore/FolderScanner.swift
FileStoreCoreTests/Support/TemporaryFolder.swift
FileStoreCoreTests/Support/FakeDownloadsFolder.swift
FileStoreCoreTests/FolderScannerTests.swift
SmartOSFileStore/FileListModel.swift
SmartOSFileStore/ScanFailure.swift
SmartOSFileStore/FileTableView.swift
SmartOSFileStore/FileIconView.swift
SmartOSFileStore/RevealInFinder.swift
SmartOSFileStore/ScanErrorView.swift
SmartOSFileStore/StatusBar.swift
```
Changed:
```
SmartOSFileStore/ContentView.swift          (placeholder → real screen)
SmartOSFileStore/SmartOSFileStoreApp.swift  (window size, Reveal in Finder command)
SmartOSFileStore/Localizable.xcstrings      (rewritten by the build; stale placeholder strings removed)
FileStoreCoreTests/ScanLocationTests.swift  (uses the shared TemporaryFolder helper)
README.md                                   (one line pointing at scripts/make-fake-downloads.sh)
```
No change to `project.yml`: all new Swift files sit in folders XcodeGen already globs, and `scripts/` and `plans/` are not sources.

## Hand checks for the owner (final report will repeat these with exact paths)
1. **Fake folder:** run `scripts/make-fake-downloads.sh`, then `open build/Build/Products/Debug/SmartOSFileStore.app --args -ScanFolder <printed path>`. Expect the table sorted by Date Added newest first, folders and `Fake.app`-style packages with a dash in Size, `report-link.pdf` shown as "Alias", no `.hidden-file`, nothing from inside `Subfolder`, and the grey debug line naming the fake folder with "(launch argument)".
2. **Sorting:** click each column header twice; the arrow flips and rows reorder. Rows with no date sort to the end.
3. **Quick Look:** select `report.pdf`, press Space; the preview opens. Press Space again to close. Double click a row does the same.
4. **Reveal:** select a row, press Command-Option-R, or right-click → Reveal in Finder; Finder opens the fake folder with the file selected. The File menu shows the item disabled when nothing is selected.
5. **Refresh:** add a file to the fake folder in Terminal, press Command-R or the toolbar button; it appears and the status line count and total update.
6. **Empty state:** `mkdir -p /tmp/empty-test` (any new empty folder), launch with `-ScanFolder` pointing at it; expect "Folder Is Empty".
7. **Real Downloads and permission:** launch with no arguments. macOS asks whether the app may access Downloads. Click **Don't Allow**: the window shows an explanation and an "Open Privacy Settings" button that lands on Privacy & Security → Files and Folders. Turn the switch on for Smart OS File Store, press Retry (or Command-R), and the real list appears. To see the dialog again later: `tccutil reset SystemPolicyDownloadsFolder com.quaden2307.SmartOSFileStore`.
8. **Keyboard only:** Tab to the table, arrows to move, Space for Quick Look, Command-A to select all, Command-R to refresh. Toggle light/dark mode in System Settings → Appearance; colours follow.
9. **5,000 rows:** `EXTRA_FILES=5000 scripts/make-fake-downloads.sh`, launch against it, scroll fast and sort by Name; it should stay smooth. Tell me if it does not.

## Risks / judgment calls during execution
- Xcode 27.2 with warnings-as-errors may raise a diagnostic the plan cannot predict (for example a new strict-concurrency note on `NSWorkspace` or on `@Observable` with a stored `Task`). Rule stays: fix the cause; any silencing annotation carries a comment explaining why it is safe.
- `onKeyPress(.space)` only fires while the table has keyboard focus. If a focused-but-empty table swallows Space, fall back to a hidden `Button` with `.keyboardShortcut(.space, modifiers: [])` scoped to the table view.
- If the String Catalog is not rewritten by `xcodebuild` (it was in segment 0), add the strings to `Localizable.xcstrings` by hand; the file is plain JSON.
- The privacy pane URL is the long-standing one; if macOS 26 ignores the anchor, the button still opens Privacy & Security and the message tells the owner which row to open.
