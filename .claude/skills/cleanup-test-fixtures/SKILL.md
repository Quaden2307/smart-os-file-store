---
name: cleanup-test-fixtures
description: Use when testing or manually trying any file cleanup feature of Smart OS File Store; builds a throwaway folder of fake files (duplicates, bad names, installers, zips) so real folders are never touched.
---

# Test folder for cleanup features

Smart OS File Store renames, moves and removes real files. Every cleanup feature is developed and tested against a throwaway folder first. Never run unfinished cleanup code against the real Downloads folder, the Desktop, Documents or any other real user folder.

## Rules

- Automated tests create their own folder under the system temporary directory and delete it when they finish.
- For hand testing, create the folder with the script below and point the app at it. The app needs a debug-only way to choose the folder it scans (for example a launch argument or environment variable). If it does not have one yet, add that first.
- When a new cleanup action is added, add the files that exercise it to both the script and the test helper, including its edge cases.

## Create a hand-testing folder

Run `scripts/make-fake-downloads.sh`. It makes a fresh `mktemp` folder holding `FakeDownloads/` and, beside it, `FakeApplications/`, prints both paths, and prints the command that removes the whole thing again (two files are locked, so it runs `chflags -R nouchg` first). `EXTRA_FILES=5000 scripts/make-fake-downloads.sh` adds thousands of tiny files for performance checks.

`FakeDownloads/` holds, by action (each "must not" item is a case the action has to leave alone):

- **Duplicates:** five identical `report` files (`report (3).pdf` is locked), `IMG_4021.jpg` and an identical `beach.jpg`, and `receipt.pdf` with an identical `receipt (1).pdf`. Must not: `notes.txt` / `notes (1).txt` (same name pattern, different content), `same-size-a.bin` / `same-size-b.bin` (same size, different content), two empty files.
- **Failed downloads:** `movie.mp4.crdownload` and `partial.part`, three days old, and a Safari package `presentation.key.download/` (a partial `presentation.key` and an `Info.plist`), three days old inside and out. Must not: `setup.dmg.crdownload`, still fresh.
- **Unpacked zips:** `project.zip` with its whole `project/` folder beside it, and `contract.zip` (one file) with `contract.docx` beside it. Must not: `photos.zip`, whose `photos/` folder lacks `c.jpg`, and `archive-2023.zip` with nothing beside it.
- **Used installers:** `SomeApp-2.1.dmg`, a real disk image holding `SomeApp.app` (bundle id `com.example.SomeApp`, version 2.1, build 210), installed as `FakeApplications/SomeApp.app`. Must not: `OtherApp-1.4.zip`, holding `OtherApp.app` (`com.example.OtherApp`, 1.4), which is not installed; `Tool.pkg`, a name only.
- **Messy names:** `manual (2).pdf`, `budget copy.xlsx`, `file%20name%20with%20junk.txt`, `brochure.pdf_dl=1`, `slides.pdf.pdf`. Must not overwrite: `invoice (1).pdf`, whose clean name belongs to a different `invoice.pdf`, and `receipt (1).pdf`, whose clean name belongs to an identical `receipt.pdf`.
- **Near-duplicates:** `notes.txt` / `notes (1).txt`. Must not: `todo.txt` / `todo.md`, nearly the same text with different extensions.
- **Age and origin:** `old-receipt.pdf` (modified and added 2025-01-01 09:00 UTC, last opened 2025-02-01), `old-manual.pdf` (2024-06-01, never opened), `tax-form-2024.pdf` (2025-01-01 but last opened a day before the folder was made), and `statement.pdf`, which records where it was downloaded from (`com.apple.metadata:kMDItemWhereFroms`). Last opened is the `com.apple.lastuseddate#PS` attribute Launch Services writes when a file is opened.
- **Review lists:** `Empty Folder/`, `Folder With DS_Store/` holding only `.DS_Store`, and `disk-backup.img`, a sparse 600 MB file that takes almost no disk space.
- **The archive:** `Old downloads/` holding a copy of `report.pdf`. Neither the folder nor anything in it is ever a candidate.
- **Awkward cases:** a hidden file, a unicode name, `LICENSE` without an extension, `Subfolder/` with a copy of the report, a symlink, `locked.txt` (locked, unique content) and `big-video.mov` (200 MB).

Every item that should be a candidate is dated two hours back, both its modification date and its Date Added, one second apart in the order the items were made, so the one-hour grace period does not hide it and the keep rule's "oldest first" sees the same order as before. The age cases are older still, and the fresh `.crdownload` is left as it is. No command-line tool sets Date Added, so the script does it with `scripts/set-dates.swift`. To try an action on files made seconds ago, launch a debug build with `-GracePeriodSeconds 0`.

The script is the single source of truth for the fixture's contents. The test helper `FileStoreCoreTests/Support/FakeDownloadsFolder.swift` mirrors it case for case, with two documented differences: `big-video.mov` is 1 MiB, and the disk image is built only when a test asks for it (`FakeDownloadsFolder.make(includingDiskImage: true)`), because building one takes a second or two. Only ever delete a folder whose path came from `mktemp`.

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
