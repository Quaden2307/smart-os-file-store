# Smart OS File Store

Smart OS File Store is a native macOS file browser that will replace Finder, starting with a self-cleaning Downloads folder. It lists what is in Downloads and, only when asked, proposes cleanups such as removing exact duplicates, shows a preview you can edit, and sends confirmed files to the Trash. It is built with Swift 6, SwiftUI and XcodeGen for macOS 26 on Apple silicon, with all file logic in the `FileStoreCore` framework and the app as a thin interface on top.

## What version 0.1 does

- **Lists the top level of your Downloads folder**: name, kind, size, date added and date modified, sortable by any column, with Quick Look and Reveal in Finder.
- **Finds exact duplicates** (Find Duplicates, ⇧⌘D): files with identical content, whatever their names. Files are grouped by size first and only files that share a size are read, in streamed chunks, so memory stays flat however large the files are. In each group the copy with the cleanest name is kept (no ` (1)` or ` copy` suffix), the oldest on a tie. Empty files, folders, packages, symbolic links, hidden files, downloads still in progress, anything in a folder named Old downloads, and files added or modified in the last hour are never candidates.
- **Previews before anything happens**: every duplicate has a checkbox, the kept copy is marked Keep, and files that could not be checked are listed with the reason. Move to Trash asks for confirmation; only the ticked files move.
- **Rechecks every file right before it moves**: it must still be a regular file directly inside the folder, with the size, date and content the scan saw, and its kept copy must still be there with the same content. Anything that changed is skipped and reported. Locked files fail with a message and are never unlocked.
- **Moves files to the Trash only**, never deletes them. The summary says what moved and what did not, and why; files can be put back from the Trash. Running Find Duplicates again right afterwards finds nothing.

## What version 0.2 adds so far

- **Last Opened column**: the date macOS records when a file is opened (the `com.apple.lastuseddate#PS` attribute Launch Services writes), read from the file itself, so it shows at once in any folder, indexed by Spotlight or not. Files never opened show "Never" and sort as the oldest. Folders, apps, links and Finder aliases, which macOS does not date when they are opened, show a dash unless a date is recorded, as does an item whose date could not be read.
- **Marks**, as small badges after the name: Never opened (no last-opened date, added more than 30 days ago), Unused (last opened more than 30 days ago) and Old (added more than 90 days ago, opened or not). Folders, apps, links, aliases, hidden items and downloads in progress get none.
- **A filter** above the table and in the View menu (All, Never opened, Unused, Old). The status line shows how many items match and their total size.
- **Download source**: hover over a row to see the site a file was downloaded from and the app that downloaded it. Copy Download Source, in the context menu and the Edit menu, copies the file's address.

The two thresholds live in the app's defaults. There is no settings window yet; to change them for good, or for one launch:

```bash
defaults write com.quaden2307.SmartOSFileStore CleanupUnusedAfterDays -int 7   # default 30
defaults write com.quaden2307.SmartOSFileStore CleanupOldAfterDays -int 60     # default 90
open build/Build/Products/Debug/SmartOSFileStore.app --args -CleanupUnusedAfterDays 1
```

## What it does not do yet

- Only the top level of Downloads. No other folders and no subfolders.
- Only exact duplicates. No other cleanup actions.
- No undo beyond the Trash's Put Back, and no activity log.
- No watching of the folder: the list refreshes on launch, with ⌘R, and after Move to Trash.
- No Stop button while files move; each move is quick, and closing the window stops between files.
- Columns sort by clicking their headers only.
- English only. Every string is in a String Catalog, ready for translation.
- The build is signed to run locally. It runs on the Mac that built it; another Mac's Gatekeeper will block it until it is signed with a Developer ID and notarized (Hardened Runtime is already on).

## Keyboard

| Where | Keys | Action |
|---|---|---|
| Main window | ⇧⌘D | Find Duplicates |
| Main window | ⌘R | Refresh the list |
| Main window | Space, ⌘Y, double-click | Quick Look the selection (press again to close) |
| Main window | ⌥⌘R | Reveal the selection in Finder |
| Preview | ↑ ↓ | Move between rows |
| Preview | Space | Tick or untick the selected duplicate |
| Preview | ⌘Y, double-click | Quick Look the selected row |
| Preview | ⌘A, ⇧⌘A | Select all, select none |
| Preview | Return | Move to Trash (opens the confirmation) |
| Preview | Esc | Close the preview |
| Confirmation | Return, Esc | Cancel |
| Confirmation | ⌘⌫ | Move to Trash |
| Summary | Return, Esc | Done |

## Build, test and run

Requirements: Xcode 27 or newer and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
# Generate SmartOSFileStore.xcodeproj from project.yml (rerun after adding or moving files)
xcodegen generate

# Build
xcodebuild -scheme SmartOSFileStore -destination 'platform=macOS' -derivedDataPath build build

# Run the unit tests (about 170 tests; the scale suite adds a few seconds)
xcodebuild -scheme SmartOSFileStore -destination 'platform=macOS' -derivedDataPath build test

# Launch the app
open build/Build/Products/Debug/SmartOSFileStore.app
```

The Release configuration is what would ship. It is built with Hardened Runtime and without the debug-only folder override, and the tests run against it too. The engine is a separate framework target but is linked into the app statically: an app signed to run locally has no Team ID, and Hardened Runtime refuses to load an embedded framework without one, so there is nothing to embed.

```bash
xcodebuild -scheme SmartOSFileStore -destination 'platform=macOS' -configuration Release -derivedDataPath build build
xcodebuild -scheme SmartOSFileStore -destination 'platform=macOS' -configuration Release -derivedDataPath build test
open build/Build/Products/Release/SmartOSFileStore.app
```

### Benchmark

A benchmark times the scan (with and without reading last-opened dates and download sources), the marks, the table's sort and Find Duplicates on 10,000 small files and three sparse multi-gigabyte files, with peak memory. It is kept out of the normal test run (the default test plan leaves it out) and takes about a minute. Run it in the Release configuration, which is what ships, and copy the `BENCHMARK` lines into [docs/benchmarks.md](docs/benchmarks.md):

```bash
xcodebuild -scheme SmartOSFileStore -destination 'platform=macOS' -configuration Release -derivedDataPath build test -testPlan Benchmark 2>&1 | grep BENCHMARK
```

The tests only ever touch folders they create under the system temporary directory. The executor tests send their own small fixture files to the Trash, because that is the only place `FileManager.trashItem` can put them, and remove them again when the runner is allowed into the Trash.

## Hand testing against a fake folder

Debug builds can be pointed at a folder other than Downloads, so cleanup features are never tried on real files. Build a throwaway folder with `scripts/make-fake-downloads.sh` (set `EXTRA_FILES=10000` to add thousands of small files for performance checks; each carries a download source, and every other one is Unused). It prints the path of `FakeDownloads`, of a `FakeApplications` folder beside it, and the command that removes both. Then launch the app with either of these. The launch argument wins when both are set. Release builds ignore both.

```bash
open build/Build/Products/Debug/SmartOSFileStore.app --args -ScanFolder /path/to/FakeDownloads

SMARTOS_SCAN_FOLDER=/path/to/FakeDownloads open build/Build/Products/Debug/SmartOSFileStore.app
```

Cleanup actions leave anything added or modified in the last hour alone. The script dates its files two hours back, so they are candidates straight away. To try an action on files you have just made, also pass `-GracePeriodSeconds 0` (a debug-only launch argument; Release builds ignore it):

```bash
open build/Build/Products/Debug/SmartOSFileStore.app --args -ScanFolder /path/to/FakeDownloads -GracePeriodSeconds 0
```

Design decisions are recorded in [docs/decisions/](docs/decisions/).

## VS Code

After generating the project, bind the Swift extension to it so indexing and jump-to-definition work:

```bash
xcode-build-server config -scheme SmartOSFileStore -project SmartOSFileStore.xcodeproj
```

This writes `buildServer.json`, which holds local paths and is not committed.
