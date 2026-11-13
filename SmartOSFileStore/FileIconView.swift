import AppKit
import FileStoreCore
import SwiftUI
import UniformTypeIdentifiers

/// The icon macOS shows for an item, as Finder would.
struct FileIconView: View {
    let record: FileRecord

    var body: some View {
        Image(nsImage: FileIconCache.shared.icon(for: record))
            .resizable()
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }
}

/// Icons looked up so far.
///
/// Ordinary files, folders and links share one icon per type, which needs no disk access and keeps
/// the cache to a few dozen entries however many rows there are. Packages (apps, installers) carry
/// their own icon, so those are looked up per file; `removeAll()` after each scan keeps them fresh.
@MainActor
final class FileIconCache {
    static let shared = FileIconCache()

    private var iconsByType: [UTType: NSImage] = [:]
    private var iconsByURL: [URL: NSImage] = [:]

    func icon(for record: FileRecord) -> NSImage {
        switch record.kind {
        case .package:
            return perFileIcon(for: record.url)
        case .file, .folder, .symlink:
            return typeIcon(for: record.contentType ?? Self.fallbackType(for: record.kind))
        }
    }

    /// Forgets per-file icons. Type icons never go stale, so they are kept.
    func removeAll() {
        iconsByURL.removeAll()
    }

    private func typeIcon(for type: UTType) -> NSImage {
        if let icon = iconsByType[type] {
            return icon
        }
        let icon = NSWorkspace.shared.icon(for: type)
        iconsByType[type] = icon
        return icon
    }

    private func perFileIcon(for url: URL) -> NSImage {
        if let icon = iconsByURL[url] {
            return icon
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
        iconsByURL[url] = icon
        return icon
    }

    private static func fallbackType(for kind: FileRecord.Kind) -> UTType {
        switch kind {
        case .folder:
            .folder
        case .symlink:
            .symbolicLink
        case .file, .package:
            .data
        }
    }
}
