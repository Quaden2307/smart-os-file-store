import Foundation

/// What a disk image says about itself before anything attaches it: whether it is encrypted, and
/// whether it asks to accept a licence agreement. Both are read from the file's own bytes, in
/// process, so no tool runs and nothing can ask for a password (decision record 0013).
///
/// - An encrypted image (version 2) starts with `encrcdsa`.
/// - A UDIF image ends in a 512-byte `koly` trailer, big-endian, pointing to a property list.
///   A licence agreement is an `LPic` resource in its `resource-fork` dictionary.
enum DiskImageHeader {
    enum Finding: Sendable, Hashable {
        case encrypted
        case licenseAgreement
        /// Neither: attach decides the rest.
        case plain
        /// A `koly` trailer that points outside the file or to something that is not a property list.
        case damaged
        /// The trailer's property list is larger than this reads.
        case tooLarge
    }

    static let trailerLength = 512
    static let maximumPlistLength = 16 << 20

    /// Reads the image open as `file`.
    static func inspect(_ file: ZipArchiveFile) throws(ZipListing.Failure) -> Finding {
        let size = file.byteCount
        guard size >= UInt64(trailerLength) else {
            return .plain
        }
        let head = try file.bytes(at: 0, count: 8)
        if isEncrypted(head: head) {
            return .encrypted
        }
        let trailer = try file.bytes(at: size - UInt64(trailerLength), count: trailerLength)
        switch plist(inTrailer: trailer, fileSize: size) {
        case .none:
            return .plain
        case .refused(let finding):
            return finding
        case .at(let offset, let length):
            return licenseFinding(inPlist: try file.bytes(at: offset, count: length))
        }
    }

    static func isEncrypted(head: [UInt8]) -> Bool {
        head.starts(with: Array("encrcdsa".utf8))
    }

    /// Where a trailer says its property list is.
    enum TrailerPlist: Sendable, Hashable {
        /// No `koly` trailer: a raw image, which has no licence.
        case none
        /// A trailer this does not read.
        case refused(Finding)
        case at(offset: UInt64, length: Int)
    }

    static func plist(inTrailer trailer: [UInt8], fileSize: UInt64) -> TrailerPlist {
        guard trailer.count == trailerLength, fileSize >= UInt64(trailerLength), trailer.starts(with: Array("koly".utf8)) else {
            return .none
        }
        let offset = bigEndian(trailer, at: 216)
        let length = bigEndian(trailer, at: 224)
        let dataEnd = fileSize - UInt64(trailerLength)
        guard bigEndian32(trailer, at: 4) == 4, bigEndian32(trailer, at: 8) == UInt32(trailerLength),
              length > 0, offset <= dataEnd, length <= dataEnd - offset else {
            return .refused(.damaged)
        }
        guard length <= UInt64(maximumPlistLength) else {
            return .refused(.tooLarge)
        }
        return .at(offset: offset, length: Int(length))
    }

    /// Whether the trailer's property list holds a licence agreement.
    static func licenseFinding(inPlist bytes: [UInt8]) -> Finding {
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(bytes), options: [], format: nil),
              let dictionary = plist as? [String: Any] else {
            return .damaged
        }
        let resources = dictionary["resource-fork"] as? [String: Any]
        let licenses = resources?["LPic"] as? [Any]
        return licenses?.isEmpty == false ? .licenseAgreement : .plain
    }

    private static func bigEndian(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        bytes[offset..<(offset + 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }

    private static func bigEndian32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }
}
