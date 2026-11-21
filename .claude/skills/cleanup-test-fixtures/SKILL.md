---
name: cleanup-test-fixtures
description: Use when testing or manually trying any file cleanup feature of Smart OS File Store; builds a throwaway folder of fake files (duplicates, bad names, installers, zips) so real folders are never touched.
---

# Test folder for cleanup features

Smart OS File Store renames, moves and removes real files. Every cleanup feature is developed and tested against a throwaway folder first. Never run unfinished cleanup code against the real Downloads folder, the Desktop, Documents or any other real user folder.

## Rules

- Automated tests create their own folder under the system temporary directory and delete it when they finish.
- For hand testing, create the folder with the script below and point the app at it with `-ScanFolder <path>`, or a whole fake home with `-DemoHome <path>` (both debug only).
- When a new cleanup action is added, add the files that exercise it to both the script and the test helper, including its edge cases.

## Create a hand-testing folder

Run `scripts/make-fake-downloads.sh`. It makes a fresh `mktemp` folder holding `FakeDownloads/` and, beside it, `FakeApplications/`, prints both paths, and prints the command that removes the whole thing again (two files are locked, so it runs `chflags -R nouchg` first). `EXTRA_FILES=5000 scripts/make-fake-downloads.sh` adds thousands of tiny files for performance checks. Each carries the statement's download source and quarantine attribute, and every other one a last-opened date of 2025-02-01, so about half are Unused.

`FakeDownloads/` holds, by action (each "must not" item is a case the action has to leave alone):

- **Duplicates:** five identical `report` files (`report (3).pdf` is locked), `IMG_4021.jpg` and an identical `beach.jpg`, and `receipt.pdf` with an identical `receipt (1).pdf`. Must not: `notes.txt` / `notes (1).txt` (same name pattern, different content), `same-size-a.bin` / `same-size-b.bin` (same size, different content), two empty files.
- **Failed downloads:** `movie.mp4.crdownload` and `partial.part`, three days old, and a Safari package `presentation.key.download/` (a partial `presentation.key` and an `Info.plist`), three days old inside and out. `movie.mp4`, the finished download beside the first, is named in its reason. It is made last, two hours old, and its 47 bytes are a size nothing else has, so Find Duplicates never reads it. Must not: `setup.dmg.crdownload`, still fresh.
- **Unpacked zips:** `project.zip` with its whole `project/` folder beside it, and `contract.zip` (one file) with `contract.docx` beside it. Must not: `photos.zip`, whose `photos/` folder lacks `c.jpg`, and `archive-2023.zip` with nothing beside it.
- **Used installers** (`FakeApplications` holds `SomeApp.app`, `Widget.app`, `Gizmo.app` and `Locked.app`):
  - strong, ticked: `SomeApp-2.1.dmg`, a real disk image holding `SomeApp.app` (bundle id `com.example.SomeApp`, version 2.1, build 210), installed at the same version; `Widget-3.2-arm64.zip`, holding `Widget.app` (`com.example.Widget`, 3.2), installed at the same version;
  - possible, unticked: `Gizmo-1.5.pkg`, a real `pkgbuild` package (`com.example.Gizmo.pkg`, 1.5) installing `Gizmo.app`, which is installed, but no Mac has its receipt, so only the name matches (with a receipt injected, as tests do, it is strong); `Locked-1.0.dmg`, encrypted with the password `fixture`, beside an installed `Locked.app`: it is never attached, so nothing asks for the password;
  - must not: `OtherApp-1.4.zip`, holding `OtherApp.app` (`com.example.OtherApp`, 1.4), which is not installed; `Tool.pkg`, three bytes named like a package, listed under Not checked as damaged or not an installer; `disk-backup.img`, which the system types as a disk image but is not named `.dmg`.
- **Messy names:** `manual (2).pdf`, `budget copy.xlsx`, `file%20name%20with%20junk.txt`, `brochure.pdf_dl=1`, `slides.pdf.pdf`, and `agenda (1).docx` and `agenda copy.docx`, two different files that both want `agenda.docx`: the older `agenda (1).docx` gets it, the other gets its date added. Must not overwrite: `invoice (1).pdf` and `notes (1).txt`, whose clean names belong to different files (they get the date added), and `receipt (1).pdf` and the `report` copies, whose clean names belong to identical files (nothing proposed: they are duplicates). Must not rename: `Chapter (2) notes.pdf`, whose number is not at the very end.
- **Near-duplicates:** `notes.txt` / `notes (1).txt`, `invoice.pdf` / `invoice (1).pdf` and `agenda (1).docx` / `agenda copy.docx`: three groups, six files, none ticked. Must not: `todo.txt` / `todo.md`, nearly the same text with different extensions, and the `report` and `receipt` copies, whose content is identical (duplicates).
- **Age and origin:** `old-receipt.pdf` (modified and added 2025-01-01 09:00 UTC, last opened 2025-02-01), `old-manual.pdf` (2024-06-01, never opened), `tax-form-2024.pdf` (2025-01-01 but last opened a day before the folder was made), and `statement.pdf`, which records where it was downloaded from (`com.apple.metadata:kMDItemWhereFroms`: the file's address, then the page) and, in its quarantine attribute (`com.apple.quarantine`), that Safari downloaded it. Last opened is the `com.apple.lastuseddate#PS` attribute Launch Services writes when a file is opened. Under the default thresholds (30 and 90 days) the marks are: `old-receipt.pdf` Unused and Old, `old-manual.pdf` Never opened and Old, `tax-form-2024.pdf` Old, the three stale partial downloads Failed download, and nothing else. Everything else is two hours old, a folder, the link or a download still in progress. Every other ordinary top-level file among those was last opened ninety minutes before the folder was made, so about half the files have no open recorded, not all of them.
- **Old downloads (archive):** `old-receipt.pdf` (Unused) and `old-manual.pdf` (Never opened) move into `Old downloads/`; nothing else is marked Never opened or Unused, so nothing else is proposed. Must not: `tax-form-2024.pdf` (Old, but opened a day ago), anything in `Old downloads/`.
- **Review lists:** `Empty Folder/`, `Folder With DS_Store/` holding only `.DS_Store`, and `disk-backup.img`, a sparse 600 MB file that takes almost no disk space, so Review Large Downloads never lists it. Launched with `-CleanupLargeDownloadMegabytes 100` (or 1 in tests, where the video is 1 MiB), the only large download is `big-video.mov`.
- **The archive:** `Old downloads/` holding a copy of `report.pdf`. Neither the folder nor anything in it is ever a candidate.
- **Awkward cases:** a hidden file, a unicode name, `LICENSE` without an extension, `Subfolder/` with a copy of the report, a symlink, `locked.txt` (locked, unique content) and `big-video.mov` (200 MB, written, so it takes 200 MB on disk).

Every item that should be a candidate is dated two hours back, both its modification date and its Date Added, one second apart in the order the items were made, so the one-hour grace period does not hide it and the keep rule's "oldest first" sees the same order as before. The age cases are older still, and the fresh `.crdownload` is left as it is. No command-line tool sets Date Added, so the script does it with `scripts/set-dates.swift`. To try an action on files made seconds ago, launch a debug build with `-GracePeriodSeconds 0`.

The script is the single source of truth for the fixture's contents. The test helper `FileStoreCoreTests/Support/FakeDownloadsFolder.swift` mirrors it case for case, with two documented differences: `big-video.mov` is 1 MiB, and the two disk images (`SomeApp-2.1.dmg`, `Locked-1.0.dmg`) are built only when a test asks for them (`FakeDownloadsFolder.make(includingDiskImage: true)`), because building one takes a second or two. Launch with `-ApplicationsFolder <FakeApplications>` as well as `-ScanFolder` to try Remove Used Installers; tests that mount images use their own private mount folder (`DiskImageMounts(root:)`), never the app's. Only ever delete a folder whose path came from `mktemp`.

## A whole fake home

`DEMO_HOME=1 scripts/make-fake-downloads.sh` builds a fake home in one call: the folder above as `Home/Downloads`, with `Home/Desktop` and `Home/Documents` beside it, and `FakeApplications/` as before. It also prints `Demo home: <path>`. Launch a debug build with `-DemoHome <that path>` (plus `-ApplicationsFolder` and, for files made just now, `-GracePeriodSeconds 0`): the three folders then stand in for the user's real ones, which are never looked up. The app shows Downloads only for now; Desktop and Documents are there for the engine's tests and for later segments.

Desktop and Documents each hold a small set, in this order:

| | Desktop | Documents |
|---|---|---|
| Two exact duplicates | `screenshot.png`, `screenshot copy.png` | `contract.pdf`, `contract (1).pdf` |
| One name, different content | `todo.txt`, `todo (1).txt` | `letter.docx`, `letter (1).docx` |
| A messy name whose clean form is free | `sketch (2).pdf` | `resume copy.docx` |
| Old, never opened (2024-06-01) | `old-flyer.pdf` | `old-lease.pdf` |

In tests, `withFakeHome { home in … }` (`FakeHome`, in `FileStoreCoreTests/Support/FakeDownloadsFolder.swift`) builds the same home; `home.folders` gives the three folders by kind. For tests of which folder a plan, a run or an undo belongs to, `ManagedHome` (in `Support/ManagedFolders.swift`) gives an empty home with Downloads and Desktop on a log's list.

`-ScanFolder` still works as before and makes one folder Downloads, with no Desktop or Documents. If both are given, `-DemoHome` applies.

## What a cleanup feature must get right on this folder

- Every intended candidate for the action is found, and every "must not" case above is left alone.
- `setup.dmg.crdownload`, `Old downloads/` and anything added or modified within the grace period never appear in a plan.
- The five `report` files (one of them locked), the two photo files and the two `receipt` files are found as duplicates; the `notes`, `todo` and `same-size` pairs are not.
- The kept copy is the one with the cleanest name, with the oldest file as the tiebreak (`IMG_4021.jpg` over `beach.jpg`).
- Hidden files, the subfolder's contents and the symlink are left alone unless the feature explicitly covers them.
- The locked duplicate `report (3).pdf` produces a clear error for that one file and everything else still completes; `locked.txt` has unique content and is never proposed.
- Running the same cleanup a second time changes nothing.

## In automated tests

Keep one shared test helper that builds these same cases in a fresh temporary folder per test and removes it afterwards. Tests assert on the plan (what would change) as well as the result on disk.
