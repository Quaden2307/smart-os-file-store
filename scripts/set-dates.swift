// Sets the modification date and the Date Added of files for scripts/make-fake-downloads.sh. No
// command-line tool sets Date Added (when an item was put in its folder), so this calls
// setattrlist(2) directly, as the test helper FileStoreCoreTests/Support/FileDates.swift does.
//
// Usage: xcrun swift scripts/set-dates.swift @<epoch> <path>... [@<epoch> <path>...]
//
// Each @<epoch> starts a group. The group's first path gets that time and each later path one
// second more, so the paths' order is the order of their dates. A symbolic link is changed itself,
// never its target.
import Darwin
import Foundation

func setDates(of path: String, to seconds: Int) -> Bool {
    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.commonattr = attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_ADDEDTIME)
    // Attributes are packed in the order of their bits: the modification time, then Date Added.
    var times = [timespec(tv_sec: seconds, tv_nsec: 0), timespec(tv_sec: seconds, tv_nsec: 0)]
    let result = times.withUnsafeMutableBytes { buffer in
        setattrlist(path, &request, buffer.baseAddress, buffer.count, UInt32(FSOPT_NOFOLLOW))
    }
    if result != 0 {
        FileHandle.standardError.write(Data("set-dates: \(path): \(String(cString: strerror(errno)))\n".utf8))
        return false
    }
    return true
}

var base: Int?
var offset = 0
var succeeded = true
for argument in CommandLine.arguments.dropFirst() {
    if argument.hasPrefix("@") {
        guard let seconds = Int(argument.dropFirst()) else {
            FileHandle.standardError.write(Data("set-dates: not a time: \(argument)\n".utf8))
            exit(2)
        }
        base = seconds
        offset = 0
        continue
    }
    guard let start = base else {
        FileHandle.standardError.write(Data("usage: set-dates.swift @<epoch> <path>... [@<epoch> <path>...]\n".utf8))
        exit(2)
    }
    succeeded = setDates(of: argument, to: start + offset) && succeeded
    offset += 1
}
exit(succeeded ? 0 : 1)
