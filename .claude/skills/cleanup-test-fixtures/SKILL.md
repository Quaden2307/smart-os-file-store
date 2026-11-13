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

Run `scripts/make-fake-downloads.sh`. It builds the folder under a fresh `mktemp` directory (exact duplicates with browser-style names, same-size and same-name decoys, empty files, installers, a zip next to its folder, in-progress downloads, a hidden file, a unicode name, a subfolder, a symlink, a locked file, a 200 MB file and an old file), prints the path, and prints the command that removes it again (the locked file has to be unlocked first with `chflags nouchg`). `EXTRA_FILES=5000 scripts/make-fake-downloads.sh` adds thousands of tiny files for performance checks.

The script is the single source of truth for the fixture's contents. The test helper `FileStoreCoreTests/Support/FakeDownloadsFolder.swift` mirrors it case for case, with a smaller large file so tests stay fast. Only ever delete a folder whose path came from `mktemp`.

## What a cleanup feature must get right on this folder

- The four `report` files and the two photo files are found as duplicates; the `notes` and `same-size` pairs are not.
- The kept copy is the one with the cleanest name, with the oldest file as the tiebreak.
- Hidden files, the subfolder's contents and the symlink are left alone unless the feature explicitly covers them.
- The locked file produces a clear error for that one file and everything else still completes.
- Running the same cleanup a second time changes nothing.

## In automated tests

Keep one shared test helper that builds these same cases in a fresh temporary folder per test and removes it afterwards. Tests assert on the plan (what would change) as well as the result on disk.
