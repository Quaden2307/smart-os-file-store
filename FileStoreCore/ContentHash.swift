import CryptoKit
import Foundation

/// A SHA-256 digest of a file's bytes. Two files with equal hashes have identical content.
public struct ContentHash: Sendable, Hashable {
    /// The 32 digest bytes.
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    init(_ digest: SHA256Digest) {
        self.bytes = Array(digest)
    }

    /// Lower-case hexadecimal, for logs and tests.
    public var hexString: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
