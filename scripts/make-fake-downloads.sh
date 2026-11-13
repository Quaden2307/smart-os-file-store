#!/bin/bash
# Builds a throwaway "FakeDownloads" folder with the cases every cleanup feature must handle
# (see .claude/skills/cleanup-test-fixtures/SKILL.md). The folder always lives under a fresh
# mktemp directory, so this script cannot touch Downloads or any other real folder.
#
# Usage:
#   scripts/make-fake-downloads.sh                   # the standard set of files
#   EXTRA_FILES=5000 scripts/make-fake-downloads.sh  # plus 5,000 tiny files for table performance checks
#
# Then launch a debug build against it:
#   open build/Build/Products/Debug/SmartOSFileStore.app --args -ScanFolder "<printed path>"
set -euo pipefail

F="$(mktemp -d)/FakeDownloads"; mkdir -p "$F"; cd "$F"

# Exact duplicates with typical browser names. The fourth copy is locked (see the end), so moving
# the duplicates to the Trash has one failure to show.
printf 'quarterly report body' > "report.pdf"
cp "report.pdf" "report (1).pdf"
cp "report.pdf" "report (2).pdf"
cp "report.pdf" "report (3).pdf"
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
printf 'partial' > "partial.part"

# Awkward cases
printf 'no extension' > "LICENSE"
printf 'hidden' > ".hidden-file"
printf 'unicode' > "résumé – final ✓.pdf"
printf 'spaces' > "file%20name%20with%20junk.txt"
mkdir "Subfolder"; cp "report.pdf" "Subfolder/report.pdf"
ln -s "report.pdf" "report-link.pdf"
printf 'locked' > "locked.txt"

# One large file so hashing is exercised off the main thread
mkfile -n 200m "big-video.mov"

# An old file for age-based rules
printf 'old' > "old-receipt.pdf"

# Optional bulk files, for checking the table with thousands of rows
count="${EXTRA_FILES:-0}"
if [ "$count" -gt 0 ]; then
  for ((i = 1; i <= count; i++)); do
    printf '%d' "$i" > "$(printf 'bulk-%05d.txt' "$i")"
  done
fi

# Cleanup actions skip files modified in the last few seconds, and this folder is usually scanned
# right after it is made, so every entry is backdated by a minute. The old receipt is then made old
# (09:00 UTC, matching the test helper), and the locked files are locked last because an immutable
# file's date cannot be changed.
find "$F" -mindepth 1 -maxdepth 1 -exec touch -h -t "$(date -v-60S +%Y%m%d%H%M.%S)" {} +
TZ=UTC touch -t 202501010900 "old-receipt.pdf"
chflags uchg "locked.txt" "report (3).pdf"

echo "Test folder: $F"
echo "Remove with: chflags -R nouchg \"$F\" && rm -rf \"$F\""
