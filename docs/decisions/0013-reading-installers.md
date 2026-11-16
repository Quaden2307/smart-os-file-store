# 0013. Reading installers without running or changing them

Date: 2026-11-15 · Segment: version 0.2, segment 9 (Remove Used Installers)

## Decision

Everything read from an installer is untrusted. Nothing in it is run, nothing is written into it, every size and count is bounded before memory is spent, property lists go through `PropertyListSerialization` (plain values, never a class the file names), and no link is followed.

**Zips.** The strict reader of decision 0011 lists the zip. For each top-level `<Name>.app` (at most 16) it reads one entry, `<Name>.app/Contents/Info.plist`, in memory: a plain file entry, not encrypted, stored or deflated, at most 1 MiB packed and unpacked, with no link where the app or its `Contents` would be. Deflated data is inflated with the SDK's zlib into its declared size and no more; more output than declared, or a CRC-32 that disagrees, is damage.

**Packages.** A package is a xar archive. The reader is in-house and reads by ranges, never the whole file:
- the 28-byte header (big-endian), then the zlib-compressed table of contents: at most 4 MiB compressed and 16 MiB unpacked, checked before anything is allocated, and checked against the table checksum the header names (SHA-1, MD5, SHA-256 or SHA-512). A checksum detects damage; it proves nothing about who made the file;
- the table must be UTF-8, with no NUL and no UTF-16 mark, and with no `<!DOCTYPE` or `<!ENTITY`, so `XMLParser` has no entity to expand and nothing to fetch. At most 10,000 files, 32 levels deep. A file's own `<name>` counts; the same words inside an extended attribute (`<ea>`) do not;
- only `PackageInfo` is read: the top-level one of a component package, or each top-level `<name>.pkg/PackageInfo` of a product archive (at most 64, each at most 1 MiB), stored or zlib ("gzip"), with both checksums checked. From each: `identifier`, `version`, and the apps it installs (bundles with a path ending in `.app`, not inside another app);
- the payload, the scripts and `Distribution`, which can hold JavaScript, are never read;
- receipts come from `pkgutil --pkgs-plist`, then `pkgutil --pkg-info-plist` for identifiers taken from that list only, so no string read from a package reaches a command line.

**Disk images.** Probed on macOS 27.2.1 before building:
- A plain `hdiutil attach` writes `com.apple.diskimages.fsck` and `com.apple.diskimages.recentcksum` into a downloaded image: the results of the checksum verification and the file-system check it runs. That changes the user's file before they confirm anything. A `diskutil image attach` writes nothing.
- `hdiutil` is deprecated as a whole in macOS 27 ("Use diskutil image instead"). `diskutil image attach` of an image already attached makes a second attachment of its own; `hdiutil attach` hands back the first one, user's mounts included. `hdiutil info` still reports a renamed image under its old path.
- `diskutil image info` waited minutes on an encrypted image even with empty input, and ended "cancelled by the user": it is never used. Attach with `--stdinpassphrase` and empty input fails at once ("Passphrase cannot be empty"); on an image with a licence it fails at once too ("Operation canceled"). No window appeared for either.

So, for each image (the owner chose "check, write nothing"):
1. Not an iCloud placeholder; not attached already, matched by device and inode (`hdiutil info`, the only listing). An attached image whose path no longer leads anywhere means "could not tell", so every disk image is then left alone. Hard links of one image are read once.
2. From the file's own bytes: an encrypted image starts with `encrcdsa`; a licence is an `LPic` resource in the property list the 512-byte `koly` trailer points to. Either skips the image without running any tool.
3. `diskutil image attach --readOnly --noMount --stdinpassphrase --plist`, with empty input. Not mounting means neither the system's verification nor its file-system check runs, so nothing is recorded in the file.
4. The system's own checker, read-only: `fsck_hfs -fn` on the HFS+ volume, or `fsck_apfs -n` on the APFS container's physical store. A failure is `damaged`; another file system has no checker and is never mounted (`unsupported`). One mountable volume only.
5. `diskutil mount readOnly nobrowse -mountPoint <slot>`: hidden from Finder, never opened, and mounted `nodev`, `nosuid`, `noowners`, quarantined like any disk image.
6. Only the top level is listed (at most 1,000 items). Each `*.app` that is a real folder has its `Contents/Info.plist` read through one descriptor, beneath the volume, with no link followed (`O_NOFOLLOW_ANY | O_RESOLVE_BENEATH`), so the usual `Applications` link leads nowhere.
7. `diskutil eject`, always: three tries half a second apart, then forced, in a step a cancel does not stop. After a timeout or a cancel during attach, attached images are listed in a step a cancel does not stop either, and any attachment of this file with no volume mounted is ejected. A new search waits until the last one's images are ejected before it lists what is attached, so it never takes its own leftovers for someone else's.
8. The file's identity, size, modification date and status-change time are compared before and after; anything changed drops what was read.

Timeouts: attach, mount and eject 30 s, the check 120 s, everything else 10 s. Tools run by absolute path with a minimal environment, empty input and both outputs capped at 1 MiB and drained all the time; a timeout or cancel stops the tool, killed two seconds later if need be.

**Where images are mounted.** `$TMPDIR/com.quaden2307.SmartOSFileStore.mounts/<pid>/1` and `/2`, made 0700 at launch through `DiskChange` with a permit of its own; planning never makes them, and a search that finds them unprepared reads no disk image. The sweep runs before the slots are checked, since a run with the same process ID may have left a volume mounted in one. The two slots are the "two at a time" limit. The root must be a real folder of this user's with nothing for anyone else, or nothing is mounted; it is never repaired. One actor per process holds the slots and, once per launch before any attach, detaches what is mounted in the folders of processes that are gone, and nothing else, so two copies of the app or a test run never touch each other's mounts. Empty folders of gone processes stay: nothing here removes.

**The cache.** What was read is kept in the activity log (`installerFacts`, schema v5), keyed like Kept by volume UUID and file number, or the path where the volume gives none, with the size, modification date and status-change time, which `touch -r` cannot set back. A row is used only when all three are the same to the bit and the reader version is current. Lasting outcomes are kept (found apps, password, licence, damaged, too large); a timeout is not, nor a failure that says nothing about the file (`couldNotOpen`: a tool that could not start, a mount the system refused), so such an image is tried again next time. The planner writes nothing: newly read facts travel on the plan, and the app stores them after planning. Rows read more than 90 days ago are pruned with the runs. The Installed mark is worked out from the cache alone, so drawing the list attaches nothing.

## Alternatives

- **`hdiutil attach` with the requested flags:** writes two attributes into the image unless verification and the check are switched off, hands back other people's attachments, and is deprecated.
- **Skipping the file-system check:** writes nothing, but mounts unchecked file systems from the internet; the owner chose to keep the check.
- **Letting macOS write its note:** a change to the user's file before they confirm.
- **`hdiutil isencrypted` / `imageinfo`, `diskutil image info`:** a process per image; `imageinfo` is deprecated, and `diskutil image info` hung on an encrypted image.
- **`installer -pkginfo`:** evaluates the package's JavaScript.
- **`pkgutil --expand`:** copies the payload out, gigabytes for some packages.
- **The `xar` tool:** deprecated; the tests use it only as a second reader.
- **Unpacking the zip:** writes files and reads everything.
- **Attaching on every search:** a second search would mount every image again; with the cache it mounts none (benchmark: 41 ms for 130 installers).
- **Mounting under `/Volumes`, or with `-mountrandom` in the shared temporary folder:** visible to others, and leftovers could not be told from another tool's.

## Why

The owner's rules: nothing changes before the user confirms, nothing from an installer runs, and every byte is untrusted. Probing the real tools found the one route that keeps the system's check and writes nothing.

## Consequences

- A disk image whose file system has no checker (FAT, ExFAT, ISO) is never mounted, so it can be at most a possible match.
- Images that hold several volumes are not read.
- A user who renames an image while it is attached keeps every disk image out of the plan until it is ejected.
- If ejecting fails four times, the image stays attached until the next launch's sweep, and the log says so.
- `pkgutil` and `hdiutil info` remain dependencies; if Apple removes them, those steps fail safe: no receipts, and disk images left alone.
