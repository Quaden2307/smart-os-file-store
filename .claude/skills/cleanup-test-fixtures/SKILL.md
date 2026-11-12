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

```bash
F="$(mktemp -d)/FakeDownloads"; mkdir -p "$F"; cd "$F"

# Exact duplicates with typical browser names
printf 'quarterly report body' > "report.pdf"
cp "report.pdf" "report (1).pdf"
cp "report.pdf" "report (2).pdf"
cp "report.pdf" "report copy.pdf"

# Same content, unrelated names
printf 'holiday photo bytes' > "IMG_4021.jpg"
cp "IMG_4021.jpg" "beach.jpg"

# Same name pattern, DIFFERENT content: must never be treated as duplicates
printf 'draft one' > "notes.txt"
printf 'draft two, edited' > "notes (1).txt"

# Same size, different content: catches size-only comparison bugs
printf 'AAAA' > "same-size-a.bin"
printf 'BBBB' > "same-size-b.bin"

# Empty files: all identical by content, decide and test the intended behaviour
: > "empty-a.txt"; : > "empty-b.txt"

# Installers, archives and leftovers for later cleanup actions
printf 'dmg' > "SomeApp-2.1.dmg"
printf 'pkg' > "Tool.pkg"
printf 'zip' > "project.zip"; mkdir "project"; printf 'x' > "project/readme.md"
printf 'partial' > "movie.mp4.crdownload"
printf 'partial' > "Unconfirmed 48213.download"

# Awkward cases
printf 'no extension' > "LICENSE"
printf 'hidden' > ".hidden-file"
printf 'unicode' > "résumé – final ✓.pdf"
printf 'spaces' > "file%20name%20with%20junk.txt"
mkdir "Subfolder"; cp "report.pdf" "Subfolder/report.pdf"
ln -s "report.pdf" "report-link.pdf"
printf 'locked' > "locked.txt"; chflags uchg "locked.txt"

# One large file so hashing is exercised off the main thread
mkfile -n 200m "big-video.mov"

# An old file for age-based rules
printf 'old' > "old-receipt.pdf"; touch -t 202501010900 "old-receipt.pdf"

echo "Test folder: $F"
```

To remove it afterwards, unlock the locked file first: `chflags nouchg "$F/locked.txt" && rm -rf "$F"`. Only ever delete a folder whose path came from `mktemp`.

## What a cleanup feature must get right on this folder

- The four `report` files and the two photo files are found as duplicates; the `notes` and `same-size` pairs are not.
- The kept copy is the one with the cleanest name, with the oldest file as the tiebreak.
- Hidden files, the subfolder's contents and the symlink are left alone unless the feature explicitly covers them.
- The locked file produces a clear error for that one file and everything else still completes.
- Running the same cleanup a second time changes nothing.

## In automated tests

Keep one shared test helper that builds these same cases in a fresh temporary folder per test and removes it afterwards. Tests assert on the plan (what would change) as well as the result on disk.
