import Darwin
import Foundation

/// Sets the two dates the grace period looks at: an item's modification date and its Date Added
/// (when it was put in its folder). A file a test writes, or copies, is new on both counts, and the
/// app leaves new items alone for an hour, so fixtures date their items back with this.
///
/// No Foundation API sets Date Added, so this uses `setattrlist(2)`, as `scripts/set-dates.swift`
/// does for the hand-testing folder.
enum FileDates {
    /// How far back `settle` dates items by default: well past the one-hour grace period.
    static let settledAge: TimeInterval = 2 * 60 * 60

    /// Sets both dates of the item at `url` to `date`. A symbolic link is changed itself, never its target.
    static func set(_ url: URL, to date: Date) throws {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_ADDEDTIME)
        let seconds = date.timeIntervalSince1970.rounded(.down)
        let time = timespec(tv_sec: Int(seconds), tv_nsec: Int((date.timeIntervalSince1970 - seconds) * 1_000_000_000))
        // Attributes are packed in the order of their bits: the modification time, then Date Added.
        var times = [time, time]
        let result = times.withUnsafeMutableBytes { buffer in
            setattrlist(url.path(percentEncoded: false), &request, buffer.baseAddress, buffer.count, UInt32(FSOPT_NOFOLLOW))
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Dates the items one second apart, in the order given, starting at `base`: the first item is
    /// the oldest, as if they had arrived in that order. Rules that prefer the older of two files
    /// then see the order in which a test made them.
    static func settle(_ urls: [URL], base: Date = Date(timeIntervalSinceNow: -settledAge)) throws {
        for (index, url) in urls.enumerated() {
            try set(url, to: base.addingTimeInterval(TimeInterval(index)))
        }
    }

    /// Writes `files` (name to text) into `folder` in name order and settles them in that order.
    static func writeSettled(_ files: [String: String], in folder: URL) throws {
        var urls: [URL] = []
        for (name, text) in files.sorted(by: { $0.key < $1.key }) {
            let url = folder.appending(path: name)
            try Data(text.utf8).write(to: url)
            urls.append(url)
        }
        try settle(urls)
    }
}
