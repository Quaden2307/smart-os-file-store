import Foundation

/// Reads a component package's `PackageInfo`: its identifier and version, and the apps it installs,
/// from the bundles it lists with a path (`<bundle path="./SomeApp.app" id="…" CFBundleShortVersionString="…">`).
/// An app is a bundle whose path ends in `.app` and lies inside no other app, so a helper inside
/// an app is not one. Every value is bounded, as `BundleInfo`'s are.
enum PackageInfo {
    /// The part `bytes` describes.
    ///
    /// - Throws: `.tooLarge` when it lists more apps than one installer may hold, `.damaged` when
    ///   it is not a `PackageInfo` with an identifier.
    static func parse(_ bytes: [UInt8]) throws(InstallerFacts.Problem) -> PackageFacts {
        let parser = Parser()
        let parsed = UntrustedXML.parse(bytes, with: parser)
        if parser.tooManyApps {
            throw .tooLarge
        }
        guard parsed, let identifier = parser.identifier else {
            throw .damaged
        }
        return PackageFacts(identifier: identifier, version: parser.version, apps: parser.apps)
    }

    private final class Parser: NSObject, XMLParserDelegate {
        private(set) var identifier: String?
        private(set) var version: String?
        private(set) var apps: [BundleFacts] = []
        private(set) var tooManyApps = false
        private var isRoot = true

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            defer { isRoot = false }
            if isRoot {
                guard name == "pkg-info" else {
                    parser.abortParsing()
                    return
                }
                identifier = BundleInfo.bounded(attributes["identifier"], BundleInfo.maximumIdentifierLength)
                version = BundleInfo.bounded(attributes["version"], BundleInfo.maximumVersionLength)
                return
            }
            guard name == "bundle", let path = attributes["path"], let appName = Self.appName(atPath: path),
                  let id = BundleInfo.bounded(attributes["id"], BundleInfo.maximumIdentifierLength),
                  !apps.contains(where: { $0.identifier == id }) else {
                return
            }
            guard apps.count < InstallerFacts.maximumApps else {
                tooManyApps = true
                parser.abortParsing()
                return
            }
            apps.append(BundleFacts(
                name: appName,
                identifier: id,
                shortVersion: BundleInfo.bounded(attributes["CFBundleShortVersionString"], BundleInfo.maximumVersionLength),
                build: BundleInfo.bounded(attributes["CFBundleVersion"], BundleInfo.maximumVersionLength)
            ))
        }

        /// The app's name when `path` is an app inside no other app.
        private static func appName(atPath path: String) -> String? {
            let parts = path.split(separator: "/").map(String.init)
            guard let last = parts.last, BundleInfo.isAppName(last), !parts.dropLast().contains(where: BundleInfo.isAppName),
                  last.utf8.count <= 255 else {
                return nil
            }
            return BundleInfo.appName(ofBundleNamed: last)
        }
    }
}
