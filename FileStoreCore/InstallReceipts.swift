import Foundation

/// Where package receipts come from: macOS's own, through `pkgutil`, or a fixed list for tests,
/// since a real receipt would mean installing something.
public struct InstallReceipts: Sendable {
    private let lookup: @Sendable (Set<String>) async -> [String: InstallReceipt]

    public init(lookup: @escaping @Sendable (Set<String>) async -> [String: InstallReceipt]) {
        self.lookup = lookup
    }

    /// The receipts this Mac has: `pkgutil --pkgs-plist` once, then `pkgutil --pkg-info-plist` for
    /// each identifier asked for that the list holds. Only identifiers from macOS's own list reach
    /// the command line, never one read from a package.
    public static let system = InstallReceipts { identifiers in
        await systemReceipts(for: identifiers, tool: SystemTool())
    }

    public static func fixed(_ receipts: [InstallReceipt]) -> InstallReceipts {
        let byIdentifier = Dictionary(receipts.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        return InstallReceipts { identifiers in byIdentifier.filter { identifiers.contains($0.key) } }
    }

    /// The receipts filed under `identifiers`, by identifier. One that cannot be read is missing.
    public func receipts(for identifiers: Set<String>) async -> [String: InstallReceipt] {
        identifiers.isEmpty ? [:] : await lookup(identifiers)
    }

    /// The identifiers `pkgutil --pkgs-plist` lists.
    public static func parseIdentifiers(_ data: Data) -> [String]? {
        (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String]
    }

    /// The receipt `pkgutil --pkg-info-plist` describes.
    public static func parseReceipt(_ data: Data) -> InstallReceipt? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let identifier = dictionary["pkgid"] as? String else {
            return nil
        }
        return InstallReceipt(identifier: identifier, version: dictionary["pkg-version"] as? String)
    }

    private static func systemReceipts(for identifiers: Set<String>, tool: SystemTool) async -> [String: InstallReceipt] {
        guard let list = try? await tool.run("/usr/sbin/pkgutil", ["--pkgs-plist"], timeout: .seconds(10)), list.succeeded,
              let installed = parseIdentifiers(list.standardOutput) else {
            return [:]
        }
        var receipts: [String: InstallReceipt] = [:]
        for identifier in installed where identifiers.contains(identifier) {
            guard let info = try? await tool.run("/usr/sbin/pkgutil", ["--pkg-info-plist", identifier], timeout: .seconds(10)),
                  info.succeeded, let receipt = parseReceipt(info.standardOutput), receipt.identifier == identifier else {
                continue
            }
            receipts[identifier] = receipt
        }
        return receipts
    }
}
