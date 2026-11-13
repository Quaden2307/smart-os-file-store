import Foundation
import Testing

/// A URL's path with symlinks resolved and without a trailing slash, so two spellings of the same
/// folder compare equal. The temporary directory lives under a symlinked `/var`, which is why
/// plain URL equality is not enough.
func canonicalPath(_ url: URL) -> String {
    var path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    while path.count > 1, path.hasSuffix("/") {
        path.removeLast()
    }
    return path
}

func expectSameFolder(
    _ actual: URL,
    _ expected: URL,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(canonicalPath(actual) == canonicalPath(expected), sourceLocation: sourceLocation)
}
