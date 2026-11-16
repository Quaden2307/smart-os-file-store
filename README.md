# Smart OS File Store

Smart OS File Store is a native macOS file browser that will replace Finder, starting with a self-cleaning Downloads folder. It lists what is in Downloads and, only when asked, proposes cleanups such as removing exact duplicates, shows a preview you can edit, and sends confirmed files to the Trash. It is built with Swift 6, SwiftUI and XcodeGen for macOS 26 on Apple silicon, with all file logic in the `FileStoreCore` framework and the app as a thin interface on top.

## What version 0.1 does

- **Lists the top level of your Downloads folder**: name, kind, size, date added and date modified, sortable by any column, with Quick Look and Reveal in Finder.
- **Finds exact duplicates** (Find Duplicates, ⇧⌘D): files with identical content, whatever their names. Files are grouped by size first and only files that share a size are read, in streamed chunks, so memory stays flat however large the files are. In each group the copy with the cleanest name is kept (no ` (1)` or ` copy` suffix), the oldest on a tie. Empty files, folders, packages, symbolic links, hidden files, downloads still in progress, anything in a folder named Old downloads, and files added or modified in the last hour are never candidates.
- **Previews before anything happens**: every duplicate has a checkbox, the kept copy is marked Keep, and files that could not be checked are listed with the reason. Move to Trash asks for confirmation; only the ticked files move.
- **Rechecks every file right before it moves**: it must still be a regular file directly inside the folder, with the size, date and content the scan saw, and its kept copy must still be there with the same content. Anything that changed is skipped and reported. Locked files fail with a message and are never unlocked.
- **Moves files to the Trash only**, never deletes them. The summary says what moved and what did not, and why; files can be put back from the Trash. Running Find Duplicates again right afterwards finds nothing.

## What version 0.2 adds

- **Last Opened column**: the date macOS records when a file is opened (the `com.apple.lastuseddate#PS` attribute Launch Services writes), read from the file itself, so it shows at once in any folder, indexed by Spotlight or not. Files never opened show "Never" and sort as the oldest. Folders, apps, links and Finder aliases, which macOS does not date when they are opened, show a dash unless a date is recorded, as does an item whose date could not be read.
- **Marks**, as small badges after the name: Never opened (no last-opened date, added more than 30 days ago), Unused (last opened more than 30 days ago) and Old (added more than 90 days ago, opened or not). Folders, apps, links, aliases, hidden items and downloads in progress get none.
- **A filter** above the table and in the View menu (All, Kept, Failed download, Installed, Never opened, Unused, Old). The status line shows how many items match and their total size.
- **Download source**: hover over a row to see the site a file was downloaded from and the app that downloaded it. Copy Download Source, in the context menu and the Edit menu, copies the file's address.
- **Rename and move in the engine**: exclusive, so nothing is ever replaced, through a handle on the folder, so no link is followed. Fix Messy Names renames; nothing moves files yet.
- **An activity log**: every confirmed cleanup is recorded as it happens, one row per file, in a local database. A row that says a change was started is written before the file changes and completed right after, so if the app crashes or is force-quit, no moved file is missing from the log. If the log cannot be written, the cleanup stops with the file untouched.
- **Activity**, in the main window's sidebar beside Downloads (also View > Activity, ⇧⌘A): every cleanup, newest first. Open one to see each file with what was to be done, why, what happened and when. Reveal in Finder works for a file that is still where the log says it went.
- **Moved to the Trash**: the summary says how much a cleanup moved to the Trash, and the status line shows the total so far. The space is free once you empty the Trash.
- **Undo**: Edit > Undo (⌘Z) undoes the newest cleanup; Activity undoes any cleanup or single file that can still be put back.
- **A Clean Up menu**, in the toolbar and the menu bar, with two more cleanups. **Clear Failed Downloads** (⇧⌘F) proposes partial downloads that stopped more than an hour ago and never finished. **Remove Unpacked Zips** (⇧⌘U) proposes a zip whose every file already sits next to it, unpacked, at the same size, where Archive Utility puts it (one item beside the zip, several in a folder named after it, or a numbered name such as `project 2`). The unpacked copy is never touched, and zips are only ever read, never extracted.
- **Remove Used Installers** (⇧⌘I, in the Clean Up menu) proposes a disk image (`.dmg`), installer package (`.pkg`) or zip holding an app at its top level once that app is in `/Applications` or `~/Applications`. It is ticked when the app's identifier matches and the installed version is the same or newer; it is proposed unticked, as a **Possible match**, when only the name matches (the file name without version numbers and words like `arm64`). An installed version older than the installer's is never proposed, and neither is a disk image someone has open. Installers are only read: a zip's `Info.plist` in memory, a package's own description without its payload, and a disk image attached read-only and hidden, checked by macOS's checker, and always ejected. Nothing is run, nothing is written into them, and an image that asks for a password or a licence is never opened. What was read is kept in the activity log, so the next search reads none of them again, and the file list marks strong matches **Installed**.
- **Fix Messy Names** (⇧⌘M, in the Clean Up menu) proposes clean names for files with copy numbers or leftover junk in their names: it decodes `%20` and the like, removes a web address's leftover such as `_dl=1` or `@download` after the extension, a doubled extension (`slides.pdf.pdf`) and copy suffixes (` (1)`, ` copy`, ` copy 2`), then tidies the spaces, dots and underscores that leaves. Nothing else about a name changes: not its letter case, dates, version numbers or words, and never its extension. When the clean name belongs to a file with the same content, nothing is proposed (that is a duplicate); when it belongs to a different file, the file's date is added (`invoice 2026-11-13.pdf`, then ` v2`). The preview strikes out what each name loses and shows what it gains in bold; Rename asks first, and Undo gives the old names back.
- **Review Near-Duplicates** (⇧⌘R, in the Clean Up menu) lists files whose cleaned names match, extension included, but whose content differs ("Similar names, different content"). Nothing is ticked and nothing is chosen to stay; each row shows size, Date Added, Date Modified and Last Opened, with Newest and Largest as facts. One file of each group always stays. Space with two rows selected shows them side by side in Quick Look.
- **Archive Old Downloads** (⇧⌘O, in the Clean Up menu) moves files marked Never opened or Unused into a folder named **Old downloads** at the top of the folder, made on first use, under their own name ("Not opened since 1 Feb 2025", "Never opened, downloaded 1 Jun 2024"). When the name is taken there by a different file, the file's Date Added goes in its name (`report 2025-01-01.pdf`, then ` v2`); when it is taken by an identical file, this copy goes to the Trash instead and the reason says so. Nothing is deleted, and moving keeps the file's dates, last-opened date and download source, so Undo puts it back exactly as it was. If something called Old downloads is a file or a link, nothing is archived and the preview says why. Double-click Old downloads in the list to open it in Finder.
- **Review Large Downloads** (⇧⌘L, in the Clean Up menu) lists the files and packages taking at least 500 MB on disk, largest first, with size on disk, kind, Date Added, Last Opened and download source. The size is what each really occupies, so sparse files and cloud files that are not downloaded are not overstated. Nothing is ticked; tick what you want in the Trash. The footer says what share of the space taken by the folder's files they account for.
- **Remove Empty Folders** (⇧⌘E, in the Clean Up menu) proposes, ticked, the folders that hold nothing but `.DS_Store`, `.localized` and empty folders. A folder holding any other item at any depth, one the app cannot read, Old downloads, apps, links, hidden and Kept folders are never proposed, and each folder is checked again right before it goes to the Trash.
- **Tidy Now** (⌘T, first in the toolbar and the Clean Up menu) runs every cleanup over one scan and shows an overview: one row per cleanup that found something, with its count and the space it would move to the Trash, the review lists (possible installer matches, near-duplicates, large downloads) apart and unticked, and the cleanups with nothing to do at the bottom. Each file is in one row only, by priority: failed downloads, used installers, unpacked zips, duplicates, empty folders, archive, messy names. A row opens that cleanup's own preview; Back to Tidy Now keeps the ticks. One Tidy Up asks once ("Move 14 items to the Trash, archive 2, rename 9?", Cancel the default), then moves to the Trash, archives and renames, in that order, as one run that one Undo reverses. After the scan, the copies Find Duplicates would remove carry a Duplicate mark until the next refresh.
- **Settings** (⌘,): "Treat files as unused after" 30, 60 or 90 days, "Mark files as old after" 90, 180 or 365 days, and "List downloads as large from" 500 MB, 1 GB or 5 GB; the marks in the list change at once. It also shows where the activity log is stored, its size, and a button to reveal it in Finder.
- **Keep This File** (⌘K, File menu and context menu): marks files and folders Kept, so no cleanup ever proposes them. Kept items show a Kept badge and a Kept choice in the filter; File > Stop Keeping All clears them, after asking. In the preview, Keep This File takes a file out of the plan and marks it Kept. Kept follows the file through renames and moves; editing it in an app that saves a new copy makes it a new, unkept file. When one copy of a duplicate is Kept, that copy is the one kept.

The thresholds live in the app's defaults, which Settings writes. To set another value, or one for one launch:

```bash
defaults write com.quaden2307.SmartOSFileStore CleanupUnusedAfterDays -int 7   # default 30
defaults write com.quaden2307.SmartOSFileStore CleanupOldAfterDays -int 60     # default 90
defaults write com.quaden2307.SmartOSFileStore CleanupLargeDownloadMegabytes -int 100   # default 500
open build/Build/Products/Debug/SmartOSFileStore.app --args -CleanupUnusedAfterDays 1
```

## What it does not do yet

- Only the top level of Downloads. No other folders and no subfolders.
- All six cleanups are here: Find Duplicates, Clear Failed Downloads, Remove Unpacked Zips, Remove Used Installers, Fix Messy Names, Review Near-Duplicates and Archive Old Downloads, Remove Empty Folders, and the review list Review Large Downloads, plus Tidy Now, which runs them together.
- An Activity entry cannot be opened for more detail yet. That is planned for later, perhaps with an Apple Intelligence summary.
- No watching of the folder: the list refreshes on launch, with ⌘R, and after Move to Trash.
- No Stop button while one cleanup's files move (Tidy Now has one); each move is quick, and closing the window stops between files.
- Columns sort by clicking their headers only.
- English only. Every string is in a String Catalog, ready for translation.
- The build is signed to run locally. It runs on the Mac that built it; another Mac's Gatekeeper will block it until it is signed with a Developer ID and notarized (Hardened Runtime is already on).

## Keyboard

| Where | Keys | Action |
|---|---|---|
| Main window | ⇧⌘D | Find Duplicates |
| Main window | ⇧⌘F | Clear Failed Downloads |
| Main window | ⇧⌘U | Remove Unpacked Zips |
| Main window | ⇧⌘I | Remove Used Installers |
| Main window | ⇧⌘M | Fix Messy Names |
| Main window | ⇧⌘R | Review Near-Duplicates |
| Main window | ⇧⌘O | Archive Old Downloads |
| Main window | ⇧⌘L | Review Large Downloads |
| Main window | ⇧⌘E | Remove Empty Folders |
| Main window | ⌘T | Tidy Now |
| Any | ⌘, | Settings |
| Main window | ⌘R | Refresh the list |
| Main window | Space, ⌘Y, double-click | Quick Look the selection (press again to close); double-click opens Old downloads in Finder |
| Main window | ⌥⌘R | Reveal the selection in Finder |
| Main window | ⌘K | Keep the selection, or stop keeping it when all of it is Kept |
| Preview | ↑ ↓ | Move between rows |
| Preview | Space | Tick or untick the selected duplicate |
| Preview | ⌘Y, double-click | Quick Look the selected row |
| Preview | ⌘A, ⌥⌘A | Select all, select none |
| Preview | ⌘K | Keep the selected file: take it out of the plan and mark it Kept |
| Preview | Return | Move to Trash or Rename (opens the confirmation) |
| Preview | Esc | Close the preview |
| Trash confirmation | Return, Esc | Cancel |
| Trash confirmation | ⌘⌫ | Move to Trash |
| Rename confirmation | Return | Rename |
| Rename confirmation | Esc | Cancel |
| Summary | Return, Esc | Done |
| Main window | ⇧⌘A | Show Activity |
| Sidebar | ↑ ↓ | Move between Downloads and Activity (Tab moves into the sidebar) |
| Activity | ↑ ↓ | Move between cleanups and their files |
| Activity | → ←, Return, double-click | Open or close the selected cleanup |
| Activity | ⌥⌘R | Reveal the selected files in Finder |

## The activity log

The log is one SQLite file, `~/Library/Application Support/com.quaden2307.SmartOSFileStore/FileStore.sqlite`, made the first time the app runs and readable by your user account only. It holds records about files (paths, sizes, dates, content hashes, what was done and why), never a file's content or a copy of one, and nothing in it leaves the Mac. Cleanups older than 90 days are removed at launch, at most once a day; the totals stay.

If the file is damaged or cannot be opened, the main window says so and nothing can be cleaned up until it works: nothing is changed that cannot be recorded. Try Again opens it again. Start a Fresh Log keeps the existing file beside the new one as `FileStore.damaged-<date>-<time>.sqlite` and starts the total again from zero. It is not offered when a write failed (a full disk, or another copy of the app holding the file), since the file is most likely fine.

The database library is [GRDB](https://github.com/groue/GRDB.swift) 7.12.0, the app's only dependency, used by the engine alone and pinned in `project.yml` to the commit of that release.

## Build, test and run

Requirements: Xcode 27 or newer and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The first build downloads GRDB, so it needs a network connection.

```bash
# Generate SmartOSFileStore.xcodeproj from project.yml (rerun after adding or moving files)
xcodegen generate

# Build
xcodebuild -scheme SmartOSFileStore -destination 'platform=macOS' -derivedDataPath build build

# Run the unit tests (about 640 tests, a minute or two; the scale suite adds a few seconds)
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

A benchmark times the scan (with and without reading last-opened dates and download sources), the marks, the table's sort and Find Duplicates on 10,000 small files and three sparse multi-gigabyte files, with peak memory. It is kept out of the normal test run (the default test plan leaves it out) and takes about a minute. Run it in the Release configuration, which is what ships, and copy the `BENCHMARK` lines into [docs/benchmarks.md](docs/benchmarks.md). `TEST_RUNNER_SMARTOS_BENCHMARK_FILES` sets the number of small files (10,000 by default):

```bash
xcodebuild -scheme SmartOSFileStore -destination 'platform=macOS' -configuration Release -derivedDataPath build test -testPlan Benchmark 2>&1 | grep BENCHMARK
TEST_RUNNER_SMARTOS_BENCHMARK_FILES=50000 xcodebuild -scheme SmartOSFileStore -destination 'platform=macOS' -configuration Release -derivedDataPath build test -testPlan Benchmark 2>&1 | grep BENCHMARK
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

Remove Used Installers looks for installed apps in `/Applications` and `~/Applications`. To try it against the script's fake apps instead, also pass `-ApplicationsFolder` (debug only; a path that is not a folder means no folder at all, never the real ones):

```bash
open build/Build/Products/Debug/SmartOSFileStore.app --args -ScanFolder /path/to/FakeDownloads -ApplicationsFolder /path/to/FakeApplications
```

While the scan folder is overridden, the activity log is a separate database under the temporary directory, one per fake folder, so hand testing never opens or writes the real log. The status line of a debug build shows its path. To see how the app handles a damaged log, quit the app, overwrite that file (`head -c 8192 /dev/urandom > "<path>"`) and launch again.

Design decisions are recorded in [docs/decisions/](docs/decisions/).

## VS Code

After generating the project, bind the Swift extension to it so indexing and jump-to-definition work:

```bash
xcode-build-server config -scheme SmartOSFileStore -project SmartOSFileStore.xcodeproj
```

This writes `buildServer.json`, which holds local paths and is not committed.
