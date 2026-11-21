#!/bin/bash
# Builds a throwaway, fictional home folder for recording a demo of Smart OS File Store: about 60
# files in Downloads, 25 on Desktop and 40 in Documents, with believable names, kinds, sizes and
# dates over six months, plus a fake Applications folder. Every run makes the same files. No real
# names, companies, emails or addresses, and nothing copied from your folders.
#
# Usage:
#   scripts/make-demo-home.sh [path]     # default: $TMPDIR/SmartOSDemo
#   DEMO_DRY_RUN=1 scripts/make-demo-home.sh [path]   # only the path checks, then stop
#
# The path must be under the temporary directory, or an empty folder or a new one anywhere else
# that is not your home, a folder in it such as Downloads, Desktop or Documents, or the top of a
# disk. A folder that holds files this script did not make is refused. The script deletes only
# what it made: the folder is marked with .smartos-demo-home, and only a marked folder is cleared.
#
# Large files are APFS clones of one 256 MB file with a short tail of their own, so each reports
# its full size and the whole home takes about 270 MB of real disk.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
TMP="${TMPDIR:-/tmp}"; ROOT="${1:-${TMP%/}/SmartOSDemo}"
MARK=".smartos-demo-home"

refuse() { echo "make-demo-home: $1" >&2; exit 1; }

# --- Path checks ------------------------------------------------------------------------------
case "$ROOT" in /*) ;; *) ROOT="$PWD/$ROOT" ;; esac
REAL_HOME="$(cd "$HOME" && pwd -P)"
PARENT="$(dirname "$ROOT")"
[ -d "$PARENT" ] || refuse "the folder above $ROOT does not exist"
REAL_ROOT="$(cd "$PARENT" && pwd -P)/$(basename "$ROOT")"
case "$REAL_ROOT" in
  /|/System*|/Library*|/Applications*|/Users|/Volumes|/Volumes/*/) refuse "$ROOT is a system location or the top of a disk" ;;
esac
[ "$REAL_ROOT" = "$REAL_HOME" ] && refuse "$ROOT is your home folder"
case "$REAL_HOME/" in "$REAL_ROOT"/*) refuse "$ROOT holds your home folder" ;; esac
for real in Downloads Desktop Documents Library Pictures Movies Music; do
  case "$REAL_ROOT/" in "$REAL_HOME/$real/"*) refuse "$ROOT is inside your real $real folder" ;; esac
done
if [ -e "$REAL_ROOT" ]; then
  [ -d "$REAL_ROOT" ] || refuse "$ROOT is a file"
  if [ ! -f "$REAL_ROOT/$MARK" ] && [ -n "$(ls -A "$REAL_ROOT")" ]; then
    refuse "$ROOT already holds files this script did not make"
  fi
fi
if [ -n "${DEMO_DRY_RUN:-}" ]; then echo "ok: $REAL_ROOT"; exit 0; fi

# --- Start clean, deleting only what this script made ------------------------------------------
if [ -f "$REAL_ROOT/$MARK" ]; then
  chflags -R nouchg "$REAL_ROOT" 2>/dev/null || true
  rm -rf "$REAL_ROOT"
fi
mkdir -p "$REAL_ROOT"
touch "$REAL_ROOT/$MARK"
HOME_DIR="$REAL_ROOT/Home"; APPS="$REAL_ROOT/Applications"; STAGE="$REAL_ROOT/.staging"
DL="$HOME_DIR/Downloads"; DT="$HOME_DIR/Desktop"; DC="$HOME_DIR/Documents"
mkdir -p "$DL" "$DT" "$DC" "$APPS" "$STAGE"

NOW="$(date +%s)"
DATES=()        # @epoch path pairs for set-dates.swift
OPENS=()        # "epoch|path" for last-opened dates
# dated <path> <days ago> [opened days ago]: when it arrived, and when it was last opened.
dated() {
  local path="$1"; case "$path" in /*) ;; *) path="$PWD/$path" ;; esac
  DATES+=("@$((NOW - $2 * 86400 - 7200))" "$path")
  if [ -n "${3:-}" ]; then OPENS+=("$((NOW - $3 * 86400 - 3600))|$path"); fi
}
# text <path> <content> <days ago> [opened]: the content, then padding to a believable size worked
# out from the name (40 KB to 3 MB), so every run makes the same sizes.
text() {
  printf '%s\n' "$2" > "$1"
  local kb=$(( $(printf '%s' "$1" | cksum | cut -d' ' -f1) % 3000 + 40 ))
  dd if=/dev/zero bs=1k count="$kb" status=none >> "$1"
  dated "$1" "$3" "${4:-}"
}

# A minimal app bundle: path, bundle id, version.
write_app() {
  local app="$1" name; name="$(basename "$1" .app)"
  mkdir -p "$app/Contents/MacOS"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>CFBundleExecutable</key><string>$name</string>
	<key>CFBundleIdentifier</key><string>$2</string>
	<key>CFBundleName</key><string>$name</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$3</string>
	<key>CFBundleVersion</key><string>$3</string>
</dict></plist>
PLIST
  printf '#!/bin/sh\nexit 0\n' > "$app/Contents/MacOS/$name"; chmod +x "$app/Contents/MacOS/$name"
}
zip_item() { ditto -c -k --norsrc --noextattr --noqtn --noacl "$@"; }
le64() { local h; h="$(printf '%016x' "$1")"; echo "${h:14:2}${h:12:2}${h:10:2}${h:8:2}${h:6:2}${h:4:2}${h:2:2}${h:0:2}"; }

# Big files: clones of one written base, each with a tail of its own so none is a duplicate.
dd if=/dev/zero of="$STAGE/base-big" bs=1m count=256 status=none
dd if=/dev/zero of="$STAGE/base-medium" bs=1m count=8 status=none
big() { cp -c "$STAGE/base-$2" "$1"; printf '%s' "$1" >> "$1"; dated "$1" "$3" "${4:-}"; }

# --- Downloads (60) --------------------------------------------------------------------------
cd "$DL"
# Exact duplicates, as browsers name them
big "Quarterly Report Q3.pdf" medium 40 38
cp -c "Quarterly Report Q3.pdf" "Quarterly Report Q3 (1).pdf"; dated "Quarterly Report Q3 (1).pdf" 39
cp -c "Quarterly Report Q3.pdf" "Quarterly Report Q3 copy.pdf"; dated "Quarterly Report Q3 copy.pdf" 21
big "team-offsite-photo.jpg" medium 75 70
cp -c "team-offsite-photo.jpg" "team-offsite-photo (1).jpg"; dated "team-offsite-photo (1).jpg" 74
big "Weeknight Recipes.pdf" medium 120
cp -c "Weeknight Recipes.pdf" "Weeknight Recipes (1).pdf"; dated "Weeknight Recipes (1).pdf" 119
text "invoice-2207.pdf" "Invoice 2207, Northwind Studio (fictional), design retainer" 33 33
cp "invoice-2207.pdf" "invoice-2207 (1).pdf"; dated "invoice-2207 (1).pdf" 33
# Installers for apps the fake Applications folder has installed
mkdir -p "$STAGE/sk"; write_app "$STAGE/sk/Sketchpad.app" com.example.Sketchpad 3.2
hdiutil makehybrid -quiet -hfs -default-volume-name Sketchpad -o "$STAGE/sk.dmg" "$STAGE/sk"
hdiutil convert -quiet "$STAGE/sk.dmg" -format UDZO -o "Sketchpad-3.2.dmg"; dated "Sketchpad-3.2.dmg" 58 58
write_app "$STAGE/NoteNest.app" com.example.NoteNest 1.8
zip_item --keepParent "$STAGE/NoteNest.app" "NoteNest-1.8-mac.zip"; dated "NoteNest-1.8-mac.zip" 90 90
mkdir -p "$STAGE/pk"; write_app "$STAGE/pk/Tasker.app" com.example.Tasker 2.0
pkgbuild --quiet --root "$STAGE/pk" --identifier com.example.Tasker.pkg --version 2.0 --install-location /Applications "Tasker-2.0.pkg"
dated "Tasker-2.0.pkg" 25 25
write_app "$APPS/Sketchpad.app" com.example.Sketchpad 3.2
write_app "$APPS/NoteNest.app" com.example.NoteNest 1.8
write_app "$APPS/Tasker.app" com.example.Tasker 2.0
# Zips next to what they were unpacked to
mkdir "brand-assets"; text "brand-assets/logo.svg" "<svg>logo</svg>" 64; text "brand-assets/colors.txt" "navy, sand, coral" 64
zip_item --keepParent "brand-assets" "brand-assets.zip"; dated "brand-assets.zip" 64 64; dated "brand-assets" 64
mkdir "course-materials"; text "course-materials/week1.pdf" "Week one reading" 101; text "course-materials/week2.pdf" "Week two reading" 101
zip_item --keepParent "course-materials" "course-materials.zip"; dated "course-materials.zip" 101 101; dated "course-materials" 101
# Failed downloads, days old
big "conference-keynote.mp4.crdownload" big 3
text "open-dataset-2026.csv.part" "partial dataset" 5
# Messy names
text "presentation%20final.pdf" "Pitch deck, final version" 18 17
text "Meeting Notes (2).docx" "Notes from the planning meeting" 12 12
text "employee-handbook.pdf.pdf" "Handbook, chapter one to nine" 140
text "spring-flyer.pdf_dl=1" "Spring market flyer" 55
text "travel budget copy.xlsx" "Flights, hotel, food" 44 40
# Large videos and a disk image
big "Product Demo 4K.mov" big 27 26
big "Travel Vlog Lisbon.mp4" big 95
big "Webinar Recording.mp4" big 160
big "photo-library-backup.zip" medium 150
# Ordinary downloads, some never opened
n=0
for item in \
  "boarding-pass-LIS.pdf" "lease-renewal-form.pdf" "wallpaper-mountains.jpg" "wallpaper-coast.jpg" "podcast-episode-41.mp3" \
  "font-specimen.pdf" "insurance-card.pdf" "concert-tickets.pdf" "garden-plan.png" "bike-manual.pdf" \
  "ebook-sample.epub" "tax-checklist.pdf" "map-of-trails.pdf" "warranty.pdf" "moving-checklist.docx" \
  "sourdough-starter.pdf" "cover-letter-template.docx" "cat-vaccination-record.pdf" "theme-music.m4a" "slides-workshop.key" \
  "community-newsletter.pdf" "parking-permit.pdf" "yoga-schedule.pdf" "museum-floorplan.pdf" "spreadsheet-export.csv" \
  "headshot.png" "logo-draft.png" "volunteer-form.pdf" "event-poster.png" "release-notes.txt" \
  "sample-photos.zip" ; do
  age=$(( (n * 37) % 178 + 1 ))
  if [ $((n % 3)) -eq 0 ]; then text "$item" "Demo file $item" "$age"; else text "$item" "Demo file $item" "$age" "$((age > 2 ? age - 2 : 1))"; fi
  n=$((n + 1))
done
# Two old files in a folder nobody uses any more, and an empty folder
mkdir "Old Projects"; dated "Old Projects" 170
mkdir "Untitled Folder"; dated "Untitled Folder" 80

# --- Desktop (25) ----------------------------------------------------------------------------
cd "$DT"
for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
  name="$(printf 'Screenshot 2026-%02d-%s at 09.%s.22.png' $((8 + 10#$i % 4)) "$i" "$i")"
  text "$name" "screenshot pixels $i" "$((10#$i * 6))" "$((10#$i * 6))"
done
cp "Screenshot 2026-09-01 at 09.01.22.png" "Screenshot 2026-09-01 at 09.01.22 copy.png"; dated "Screenshot 2026-09-01 at 09.01.22 copy.png" 5
cp "Screenshot 2026-10-02 at 09.02.22.png" "Screenshot 2026-10-02 at 09.02.22 (1).png"; dated "Screenshot 2026-10-02 at 09.02.22 (1).png" 11
cp "$DL/Sketchpad-3.2.dmg" "Sketchpad-3.2.dmg"; dated "Sketchpad-3.2.dmg" 57
text "todo.txt" "call the landlord, renew passport, buy plant food" 2 1
text "todo (1).txt" "call the landlord, renew passport" 9
text "ideas.md" "# Ideas\n- weekend market stall\n- photo zine" 30 4
text "draft-blog-post.txt" "Why I switched to a paper planner" 22 20
text "coffee-receipt.jpg" "receipt pixels" 47
text "Untitled.png" "blank canvas" 66
big "screen-recording.mov" big 14 14
big "Screen Recording 2026-11-02.mov" medium 19
text "Meeting Notes.txt" "Agenda: budget, garden rota, newsletter" 8 8
mkdir "Untitled Folder"; dated "Untitled Folder" 50

# --- Documents (40) --------------------------------------------------------------------------
cd "$DC"
text "report-final.pdf" "Annual community garden report, final" 60 30
text "report-final-v2.pdf" "Annual community garden report, final, with treasurer notes" 58 29
text "Project Plan.docx" "Project plan: timeline, budget, owners" 80 15
text "Project Plan (1).docx" "Project plan: timeline, budget, owners, revised dates" 45 15
big "Lease.pdf" medium 170 100
cp -c "Lease.pdf" "Lease copy.pdf"; dated "Lease copy.pdf" 110
text "Resume.pdf" "Resume, two pages" 150 20
cp "Resume.pdf" "Resume (1).pdf"; dated "Resume (1).pdf" 149
big "Wedding Photos Export.zip" medium 175 120
big "Portfolio 2026.pdf" medium 70 10
big "Thesis Draft.pdf" medium 130 60
n=0
for item in \
  "Taxes 2025.pdf" "Budget 2026.xlsx" "Car Insurance.pdf" "Health Plan Summary.pdf" "Passport Scan.pdf" \
  "Recipes.docx" "Reading List.txt" "Garden Layout.pdf" "Meeting Minutes Sept.docx" "Meeting Minutes Oct.docx" \
  "Volunteer Roster.xlsx" "Bike Service History.pdf" "Pet Records.pdf" "Home Inventory.xlsx" "Warranty Cards.pdf" \
  "Letter to Council.docx" "Cover Letter.docx" "Course Certificate.pdf" "Family Tree.pdf" "Travel Itinerary.pdf" \
  "Utilities Oct.pdf" "Utilities Nov.pdf" "Notes on Photography.txt" "Workshop Feedback.docx" "Book Club Schedule.pdf" \
  "Emergency Contacts.txt" "Vaccination Card.pdf" "Gym Contract.pdf" "Insurance Claim.pdf" ; do
  age=$(( (n * 23) % 175 + 3 ))
  text "$item" "Document $item, written by a fictional person" "$age" "$((age > 5 ? age - 5 : 1))"
  n=$((n + 1))
done

# --- Dates, last-opened dates, clean-up ------------------------------------------------------
cd "$REAL_ROOT"
xcrun swift "$SCRIPTS/set-dates.swift" "${DATES[@]}"
for entry in "${OPENS[@]}"; do
  xattr -wx 'com.apple.lastuseddate#PS' "$(le64 "${entry%%|*}")$(le64 0)" "${entry#*|}"
done
rm -rf "$STAGE"

count() { find "$1" -mindepth 1 -maxdepth 1 ! -name '.*' | wc -l | tr -d ' '; }
echo "Demo home: $HOME_DIR"
echo "Fake Applications: $APPS"
echo "Downloads $(count "$DL"), Desktop $(count "$DT"), Documents $(count "$DC") items; real disk use $(du -sh "$REAL_ROOT" | cut -f1)"
