import Foundation

/// Where a file was downloaded from, as macOS recorded it: the addresses a browser stores in
/// `kMDItemWhereFroms` (Finder's "Where from") and the app named in the quarantine attribute.
public struct DownloadSource: Sendable, Hashable {
    /// The recorded addresses, in the order they were recorded. Browsers store the file's own address
    /// first, then the page it was downloaded from. Other apps store other text here (Mail stores
    /// the sender and subject), so an entry is not always a web address. Empty when only the
    /// downloading app is known.
    public let addresses: [String]

    /// The app that downloaded the file, for example "Safari". Nil when it was not recorded.
    public let downloadingApp: String?

    /// The site the file came from, for example "example.com": the site of the page it was
    /// downloaded from, or of the file's own address when no page was recorded. Nil when neither is
    /// a web address. Worked out once here, at scan time, so showing it costs nothing.
    public let site: String?

    /// Nil when there is nothing to describe: no address and no app.
    public init?(addresses: [String], downloadingApp: String?) {
        let addresses = addresses.filter { !$0.isEmpty }
        let downloadingApp = downloadingApp.flatMap { $0.isEmpty ? nil : $0 }
        guard !addresses.isEmpty || downloadingApp != nil else {
            return nil
        }
        self.addresses = addresses
        self.downloadingApp = downloadingApp
        let page = addresses.dropFirst().first.flatMap(Self.webHost)
        site = page ?? addresses.first.flatMap(Self.webHost)
    }

    /// The file's own address: the first one recorded. This is what Copy Download Source copies.
    public var fileAddress: String? { addresses.first }

    /// The host of an http or https address, without a leading "www.".
    private static func webHost(_ address: String) -> String? {
        guard let components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else {
            return nil
        }
        let lowercased = host.lowercased()
        let withoutWWW = lowercased.hasPrefix("www.") ? String(lowercased.dropFirst(4)) : lowercased
        return withoutWWW.isEmpty ? lowercased : withoutWWW
    }
}
