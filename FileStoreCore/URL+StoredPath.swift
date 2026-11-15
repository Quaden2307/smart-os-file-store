import Foundation

extension URL {
    /// The path as the activity log stores it: without the `/` a folder's URL can end in (one from
    /// `contentsOfDirectory` does). `lstat` on `x/` would follow a link at `x`, so no stored path
    /// ends in one. `/` itself stays as it is.
    var storedPath: String {
        var path = path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
