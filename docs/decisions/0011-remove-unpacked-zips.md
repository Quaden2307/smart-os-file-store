# 0011. Remove Unpacked Zips: the matching rule and the zip reader

Date: 2026-11-15 · Segment: version 0.2, segment 8 (Remove Unpacked Zips)

## Decision

**Which zips.** A candidate is a regular file whose type is exactly `public.zip-archive`, both as the scan read it (`FileRecord.contentType`) and as its name gives it (`UnpackedZipPlanner.isZipName`). The executor can read the name again without a cached value, so requiring both keeps the planner and the executor in agreement. `.jar` conforms to the zip type and `.docx`, `.epub`, `.ipa` and `.key` are zips inside; none of them is a candidate. The shared rules apply: hidden, the archive, downloads in progress, the hour, Kept.

**Where to look,** as Archive Utility unpacks:
- One top-level item `T`: that item beside the zip.
- Several: a folder named after the zip without its last extension.
- A taken name gets a number: `"<name> N"` and, for a name with an extension, `"<base> N.<ext>"`, with N ≥ 2 in plain digits (`project 2`, `contract 2.docx`).

The exact name is tried first, then N ascending. The first place that holds everything is the one the reason names.

**What must be there.** Every entry, by its path relative to that place:
- a file must be a file of the same uncompressed size;
- a folder must be a real folder;
- a link must be a link of the same size (the length of its target), never followed;
- a device or pipe in a zip matches nothing.

Extra items are fine. The system's own entries are left out first: `__MACOSX` (Finder's Compress adds it when items have extended attributes), `.DS_Store`, and AppleDouble `._` files. Archive Utility applies their contents as attributes, or drops them; it does not unpack them as files.

**Never a match:**
- a zip with no file or link (empty, or holding folders only);
- a zip holding an `.app` at any depth: an installer, left to Remove Used Installers;
- an entry path that is absolute or has a `..`, `.` or empty part, or NUL or a `/` inside a part. `/` and NUL are looked for among Unicode scalars, so a `/` fused with a combining mark into one Swift character still counts. A backslash is an ordinary character;
- a path given twice, other than a folder, even at the same size or in another Unicode form. Unpacking keeps one of the two, so the other would be beside nothing;
- a file that is also another entry's folder.

**Too much to check.** Paths can imply far more folders than there are entries: a 1,024-byte name can be 512 folders deep. So the expected tree stops at 200,000 items or 32 MiB of paths. A zip that implies more is listed under Not checked, as one over the reader's limits is.

**Names** match in exact letter case, in any Unicode form. Each folder the zip names is listed, and its children are found by Swift string equality, which treats NFC and NFD as one name and keeps case. Looking a name up through the file system instead would find `readme.md` for `README.md` on a case-insensitive disk, and so let a zip holding both count as unpacked when only one exists.

**The copy itself:**
- **Settled, by what the disk says when it is read,** at planning and again at execution, never by the scan's dates. A copy unpacked again since the list was loaded is new. Settled means the shared rules apply to the copy: not hidden, not the archive, not a download in progress.
- **Its own Date Added more than an hour ago, and nothing it holds written within the hour.** "Written" is the newest modification date of what the zip names as files and links. Folders' own dates are left out, since they move whenever anything is added inside. Opening the copy in Finder, which writes a `.DS_Store` into it, therefore does not hold the zip back. A file still being written, even one whose full size was set first, does.
- **A Kept copy counts.** It stays, which is decision 0009's sense of a Kept file taking part.
- **A zip never counts as the copy.** This action could move that zip too, and a zip holding a zip would stop being idempotent.
- **Anything in iCloud only means no match.** A copy that cannot be read is left out silently.
- **Only what the zip names is read.** Each folder is opened from the copy's root with `O_NOFOLLOW_ANY | O_RESOLVE_BENEATH`, one descriptor at a time. Extras are listed, never described, up to 250,000 names.

**At execution** the match is made again from disk, through the folder handle:
1. The listing is read from the very file just checked: its identity, size and date.
2. The copy the plan names must be the expectation's name or one of its numbered forms. It is checked by the planner's own check: every entry read again, and settled.
3. After the activity log's row, the last look checks that the zip and the copy's root are unchanged (identity, kind, size and date), and that the copy is neither hidden nor in iCloud only. For a zip of one file, that file is the only evidence. What is inside a copied folder is read just before the row; like a kept duplicate's content, it is not read again in the moment the row takes.

**Skip reasons:**
- **New:** `unpackedCopyMissing(name)`, `unpackedCopyNotVerified(name)` and `unpackedCopyRecentlyChanged(name)`. The last says the copy may still be unpacking and when the zip can go.
- **A zip changed since the list was loaded:** the advice is to refresh first, since starting a cleanup plans from the list as it is.
- **Not checked:** a zip that cannot be read or listed, with its reason (`zipUnlistable`).
- **Passwords:** a password-protected zip whose listing is readable is like any other.

The last two are the owner's decisions of 2026-11-15.

**The zip reader** (`ZipListing`, `ZipCentralDirectory`) is written in-house. It reads the end records, the central directory and the local headers, never file data.
- **Opening:** it uses `pread` on a file opened `O_RDONLY | O_NOFOLLOW | O_NONBLOCK`, and never opens an iCloud placeholder. A file that changes while being read is reported as changed, not damaged.
- **One reading only.** Tools differ in where they look: Info-ZIP and ditto take the last end record they find, and ditto unpacks by the local headers in the order they come. So the reader accepts an archive only when every way of reading it agrees:
  - **The last end record** in the file must be the one whose comment reaches the last byte, and the only such one.
  - **The Zip64 records:** when there is a Zip64 locator (right before the end record), the Zip64 record must end at the locator. Each of the end record's own values must be its placeholder or the Zip64 value. The locator counts one disk.
  - **The directory** sits right before the end records and holds exactly the declared entries and bytes, on disk 0.
  - **The local headers** carry the directory's names and follow one another from the first byte to the directory, each with its data and data descriptor. A descriptor's length gives its shape, and its CRC and sizes must be the directory's. Nothing can sit in between, so ditto could not unpack an entry the listing does not show.
- **Zip64:** the locator and the record are read on their own, so a long comment cannot hide them. An entry's 0xFFFFFFFF sizes and offset are read from extra field 0x0001, in its fixed order.
- **Limits:** the entry count (100,000) and the directory's size (32 MiB) are checked before anything is allocated or read. Each name's length (1,024 bytes, PATH_MAX) is checked before the name is read. Every field read is bounds-checked, so damage never traps. With the tree's own limits, a hostile archive costs a bounded amount of memory, about 100 MiB at worst, and a refusal.
- **Encryption:** encrypted entries with a readable listing are listed as usual. An archive extra data record (`PK\x06\x08`) where the directory starts is `encryptedListing`.
- **Names** are UTF-8, strictly. ditto writes UTF-8 without the UTF-8 flag. An invalid name under that flag is `damaged`; without it, it is `unreadableNames` (a legacy code page).
- **Kinds:** a trailing `/`, then a Unix or macOS maker's mode, then the DOS directory bit.

**Probed on macOS 27.2 before building:**
- **ditto:** zips have a Unix host, folder entries and data descriptors.
- **Zip64:** Info-ZIP's `zip` reading standard input writes a Zip64 end record and locator. It records a pipe as a FIFO entry, which never matches, so the test feeds it a regular file.
- **Info-ZIP's real layout:** `zip -1` of a 4.5 GiB sparse file (16.6 s) writes 0xFFFFFFFF with the 0x0001 field after its UT and ux fields. The crafted test mirrors that layout.
- **Scale:** 50,000 files give a 4 MiB directory. With every local header checked, it is listed in about 1.05 s and fully matched in about 1.6 s in a Debug build (`ScaleTests`).

**Progress.** The planner reports zips checked of the total (`CleanupPlanningProgress`, which Find Duplicates' `DuplicateScanProgress` maps into). The app shows it as a bar and "Checked N of M zips". The shortcut is ⇧⌘U.

## Alternatives

- **libarchive:** ships without headers in the SDK, and reads a whole central directory into its own structures before a caller sees an entry, so its limits are not ours to set.
- **AppleArchive and Compression:** neither lists a zip.
- **Shelling out to `zipinfo` or `unzip`:** ruled out by the owner, and parsing their text is fragile. The tests use `zipinfo` only as a second reader to compare against.
- **Extracting, or hashing the zip or its contents:** reads everything. Path and size is the decided rule. A size that the directory, the local header and the descriptor all agree on, but the data does not, makes unpacking fail rather than write something else.
- **The central directory alone:** a crafted zip can list one set of entries there and unpack another from its local headers.
- **Tolerating trailing bytes or a prefix, as Go and Python do:** leaves which listing counts open.
- **`conforms(to: .zip)`:** would take `.jar`.
- **Looking names up through the file system:** letter case, as above.
- **Holding every folder open on the way down:** one descriptor per level, with a depth cap.
- **The hour on the copy folder's own date:** opening it in Finder would hold the zip back for an hour.
- **The hour for the zip alone:** a copy still being unpacked could already look complete.

## Why

The rule is the owner's. Where the request left a choice, each one here is the one that proposes fewer zips: nothing is moved unless the disk proves, right before the move, that every entry is still beside the zip, and that the zip says the same thing to every tool that reads it. Reading is bounded, so a hostile archive costs a bounded amount and a refusal.

## Consequences

- A zip with bytes after its end, a stub before its data, or a comment holding an end-record signature shows under Not checked as damaged.
- A source zip with a built `.app` inside is never removed by this action.
- A zip whose names use a legacy encoding never matches.
- A zip put back by undo has a new Date Added, so it waits an hour before it is proposed again.
- The executor's last look reads only the copy's root again. Something removed deep inside a copied folder in the milliseconds the log's row takes would go unseen, as it would for a kept duplicate's content.
