#!/bin/bash
# Builds a throwaway "FakeDownloads" folder with the cases every cleanup feature must handle, and a
# "FakeApplications" folder beside it standing in for /Applications (see
# .claude/skills/cleanup-test-fixtures/SKILL.md). Both live under a fresh mktemp directory, so this
# script cannot touch Downloads or any other real folder.
#
# Usage:
#   scripts/make-fake-downloads.sh                   # the standard set of files
#   EXTRA_FILES=5000 scripts/make-fake-downloads.sh  # plus 5,000 tiny files for table performance checks
#
# Then launch a debug build against it:
#   open build/Build/Products/Debug/SmartOSFileStore.app --args -ScanFolder "<printed path>"
set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(mktemp -d)"
F="$ROOT/FakeDownloads"; APPS="$ROOT/FakeApplications"; STAGE="$ROOT/Staging"
mkdir -p "$F" "$APPS" "$STAGE"; cd "$F"

# Every item is dated at the end, in the order it was made: SETTLED two hours back, STALE (failed
# downloads) three days back. The app leaves anything added or modified in the last hour alone.
SETTLED=(); STALE=(); BULK=()
settled() { SETTLED+=("$@"); }
stale() { STALE+=("$@"); }

# A minimal app bundle: path, bundle id, version, build.
write_app() {
  local app="$1" name; name="$(basename "$1" .app)"
  mkdir -p "$app/Contents/MacOS"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>$name</string>
	<key>CFBundleIdentifier</key><string>$2</string>
	<key>CFBundleName</key><string>$name</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$3</string>
	<key>CFBundleVersion</key><string>$4</string>
</dict>
</plist>
PLIST
  printf '#!/bin/sh\nexit 0\n' > "$app/Contents/MacOS/$name"; chmod +x "$app/Contents/MacOS/$name"
}

# A zip as Finder's Compress makes it, without extended attributes so sizes do not vary.
zip_item() { ditto -c -k --norsrc --noextattr --noqtn --noacl "$@"; }

# Eight bytes, little-endian, as hex: for the 16-byte last-opened timestamp.
le64() { local h; h="$(printf '%016x' "$1")"; echo "${h:14:2}${h:12:2}${h:10:2}${h:8:2}${h:6:2}${h:4:2}${h:2:2}${h:0:2}"; }

# Exact duplicates with typical browser names. The fourth copy is locked (see the end), so moving
# the duplicates to the Trash has one failure to show.
printf 'quarterly report body' > "report.pdf"
cp "report.pdf" "report (1).pdf"
cp "report.pdf" "report (2).pdf"
cp "report.pdf" "report (3).pdf"
cp "report.pdf" "report copy.pdf"
settled "report.pdf" "report (1).pdf" "report (2).pdf" "report (3).pdf" "report copy.pdf"

# Same content, unrelated names
printf 'holiday photo bytes' > "IMG_4021.jpg"; cp "IMG_4021.jpg" "beach.jpg"
settled "IMG_4021.jpg" "beach.jpg"

# Same name pattern, DIFFERENT content: must never be treated as duplicates
printf 'draft one' > "notes.txt"; printf 'draft two, edited' > "notes (1).txt"
settled "notes.txt" "notes (1).txt"

# Same size, different content: catches size-only comparison bugs
printf 'AAAA' > "same-size-a.bin"; printf 'BBBB' > "same-size-b.bin"
settled "same-size-a.bin" "same-size-b.bin"

# Empty files: all identical by content, never duplicate candidates
: > "empty-a.txt"; : > "empty-b.txt"
settled "empty-a.txt" "empty-b.txt"

# A duplicate whose messy name's clean form is the identical original
printf 'receipt for order 1042' > "receipt.pdf"; cp "receipt.pdf" "receipt (1).pdf"
settled "receipt.pdf" "receipt (1).pdf"

# Failed downloads, three days old (Chrome, Firefox, a Safari package), and one still in progress
printf 'partial' > "movie.mp4.crdownload"
printf 'partial' > "partial.part"
mkdir "presentation.key.download"
printf 'partial keynote' > "presentation.key.download/presentation.key"
cat > "presentation.key.download/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>DownloadEntryProgressBytesSoFar</key><integer>15</integer>
	<key>DownloadEntryProgressTotalToLoad</key><integer>4096</integer>
	<key>DownloadEntryURL</key><string>https://example.com/files/presentation.key</string>
</dict>
</plist>
PLIST
stale "movie.mp4.crdownload" "partial.part" "presentation.key.download" \
  "presentation.key.download/presentation.key" "presentation.key.download/Info.plist"
printf 'partial' > "setup.dmg.crdownload"   # fresh: never dated back

# Zips: unpacked beside, unpacked with a file missing, a single file beside, nothing beside
mkdir "project"; printf '# Project\n' > "project/readme.md"; printf 'print("hello")\n' > "project/main.swift"
zip_item --keepParent "project" "project.zip"
settled "project" "project/readme.md" "project/main.swift" "project.zip"
printf 'signed contract text' > "contract.docx"; zip_item "contract.docx" "contract.zip"
settled "contract.docx" "contract.zip"
mkdir "photos"; printf 'photo 1 pixels' > "photos/a.jpg"; printf 'photo 2 pixels' > "photos/b.jpg"; printf 'photo 3 pixels' > "photos/c.jpg"
zip_item --keepParent "photos" "photos.zip"; rm "photos/c.jpg"
settled "photos" "photos/a.jpg" "photos/b.jpg" "photos.zip"
printf 'year,total\n2023,42\n' > "$STAGE/old-data.csv"; zip_item "$STAGE/old-data.csv" "archive-2023.zip"
settled "archive-2023.zip"

# Installers: a real disk image holding an app that is installed (made without mounting anything),
# a zip holding an app that is not installed, and a file only named like an installer
mkdir "$STAGE/SomeApp"; write_app "$STAGE/SomeApp/SomeApp.app" com.example.SomeApp 2.1 210
hdiutil makehybrid -quiet -hfs -default-volume-name SomeApp -o "$STAGE/raw.dmg" "$STAGE/SomeApp"
hdiutil convert -quiet "$STAGE/raw.dmg" -format UDZO -o "SomeApp-2.1.dmg"
write_app "$STAGE/OtherApp.app" com.example.OtherApp 1.4 140; zip_item --keepParent "$STAGE/OtherApp.app" "OtherApp-1.4.zip"
printf 'pkg' > "Tool.pkg"
settled "SomeApp-2.1.dmg" "OtherApp-1.4.zip" "Tool.pkg"
write_app "$APPS/SomeApp.app" com.example.SomeApp 2.1 210

# Messy names, each a different length so none shares a size with another file by accident
printf 'printer manual' > "manual (2).pdf"
printf 'household budget' > "budget copy.xlsx"
printf 'spaces' > "file%20name%20with%20junk.txt"
printf 'spring brochure' > "brochure.pdf_dl=1"
printf 'team slides' > "slides.pdf.pdf"
printf 'invoice 1041 total' > "invoice.pdf"
printf 'invoice 1041 draft' > "invoice (1).pdf"   # its clean name belongs to a different file
settled "manual (2).pdf" "budget copy.xlsx" "file%20name%20with%20junk.txt" "brochure.pdf_dl=1" \
  "slides.pdf.pdf" "invoice.pdf" "invoice (1).pdf"

# Near-duplicates with different extensions: nearly the same text, never identical
printf 'buy milk, eggs and bread\n' > "todo.txt"; printf 'buy milk, eggs and bread.\n' > "todo.md"
settled "todo.txt" "todo.md"

# Age and origin: dates, last-opened dates and the download source are set below
printf 'old' > "old-receipt.pdf"
printf 'an old manual nobody opened' > "old-manual.pdf"
printf 'tax return form for 2024' > "tax-form-2024.pdf"
printf 'bank statement, october' > "statement.pdf"
settled "statement.pdf"

# Review lists: an empty folder, a folder holding only Finder's .DS_Store, a sparse 600 MB file
mkdir "Empty Folder"; mkdir "Folder With DS_Store"; printf '\0\0\0\001Bud1' > "Folder With DS_Store/.DS_Store"
mkfile -n 600m "disk-backup.img"
settled "Empty Folder" "Folder With DS_Store" "Folder With DS_Store/.DS_Store" "disk-backup.img"

# The archive folder: nothing in it is ever a candidate
mkdir "Old downloads"; cp "report.pdf" "Old downloads/report.pdf"
settled "Old downloads" "Old downloads/report.pdf"

# Awkward cases
printf 'no extension' > "LICENSE"
printf 'hidden' > ".hidden-file"
printf 'unicode' > "résumé – final ✓.pdf"
mkdir "Subfolder"; cp "report.pdf" "Subfolder/report.pdf"
ln -s "report.pdf" "report-link.pdf"
printf 'locked' > "locked.txt"
mkfile -n 200m "big-video.mov"   # large enough that hashing it takes a moment
settled "LICENSE" ".hidden-file" "résumé – final ✓.pdf" "Subfolder" "Subfolder/report.pdf" \
  "report-link.pdf" "locked.txt" "big-video.mov"

# Optional bulk files, for checking the table with thousands of rows
count="${EXTRA_FILES:-0}"
if [ "$count" -gt 0 ]; then
  for ((i = 1; i <= count; i++)); do
    name="$(printf 'bulk-%05d.txt' "$i")"; printf '%d' "$i" > "$name"; BULK+=("$name")
  done
fi
rm -rf "$STAGE"

# Dates, in one call (compiling the helper takes a few seconds). The old receipt and the tax form
# arrived 2025-01-01 09:00 UTC and the manual 2024-06-01 09:00 UTC, matching the test helper. The
# bulk files, one second apart, end two hours back however many there are.
TWO_HOURS_AGO="$(date -v-2H +%s)"
DATES=("@$TWO_HOURS_AGO" "${SETTLED[@]}" "@$(date -v-3d +%s)" "${STALE[@]}" \
  "@1735722000" "old-receipt.pdf" "tax-form-2024.pdf" "@1717232400" "old-manual.pdf")
if [ "$count" -gt 0 ]; then
  DATES+=("@$((TWO_HOURS_AGO - count))" "${BULK[@]}")
fi
xcrun swift "$SCRIPTS/set-dates.swift" "${DATES[@]}"

# Last opened, as Launch Services records it: the old receipt on 2025-02-01, the tax form yesterday.
# The manual and everything else were never opened.
xattr -wx 'com.apple.lastuseddate#PS' "$(le64 1738400400)$(le64 0)" "old-receipt.pdf"
xattr -wx 'com.apple.lastuseddate#PS' "$(le64 "$(date -v-1d +%s)")$(le64 0)" "tax-form-2024.pdf"

# Where the statement was downloaded from, as browsers record it: a binary property list of URLs
WHERE="$ROOT/where-froms.plist"
cat > "$WHERE" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
	<string>https://example.com/statements/statement.pdf</string>
	<string>https://example.com/account</string>
</array>
</plist>
PLIST
plutil -convert binary1 "$WHERE"
xattr -wx 'com.apple.metadata:kMDItemWhereFroms' "$(xxd -p "$WHERE" | tr -d '\n')" "statement.pdf"
rm "$WHERE"

# Locked last: a locked file's dates and attributes cannot be changed.
chflags uchg "locked.txt" "report (3).pdf"

echo "Test folder: $F"
echo "Fake Applications: $APPS"
echo "Remove with: chflags -R nouchg \"$ROOT\" && rm -rf \"$ROOT\""
