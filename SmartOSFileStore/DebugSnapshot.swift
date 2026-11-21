import AppKit
import SwiftUI
import FileStoreCore
import Foundation

/// Debug builds only: `-SnapshotTo <name>` prints a picture of each window of the app, as base64 PNG on standard
/// output, a few seconds after launch, drawn by the app itself, so a demo or a check of the layout
/// needs no screen recording permission. `-StartPlace desktop|documents|activity|storage` opens the window
/// on that place. `-TurnOnStandardFolders` turns on Desktop and Documents. Release builds ignore
/// all three.
enum DebugSnapshot {
    static func startPlace(arguments: [String] = ProcessInfo.processInfo.arguments) -> SidebarSection? {
        #if DEBUG
        guard let index = arguments.firstIndex(of: "-StartPlace"), arguments.index(after: index) < arguments.endIndex else {
            return nil
        }
        switch arguments[arguments.index(after: index)] {
        case "desktop":
            return .folder(.standard(.desktop))
        case "documents":
            return .folder(.standard(.documents))
        case "activity":
            return .activity
        case "storage":
            return .storage
        default:
            return .downloads
        }
        #else
        return nil
        #endif
    }

    /// `-TurnOnStandardFolders`: Desktop and Documents are on from the start, for a demo home.
    static var turnsOnStandardFolders: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-TurnOnStandardFolders")
        #else
        false
        #endif
    }

    /// The name pictures are printed under, when `-SnapshotTo` was given.
    static var snapshotName: String? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-SnapshotTo"), arguments.index(after: index) < arguments.endIndex else {
            return nil
        }
        return arguments[arguments.index(after: index)]
        #else
        return nil
        #endif
    }

    /// Draws `view` at 1440 by 900 points in a window of its own that is never put on screen, so
    /// it works while the Mac is locked, and prints it every few seconds as it settles.
    @MainActor
    static func renderOffscreen(_ view: some View) {
        #if DEBUG
        guard let name = snapshotName else { return }
        let size = NSSize(width: 1_440, height: 900)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.contentView = host
        offscreenWindow = window
        Task { @MainActor in
            for round in 1...4 {
                try? await Task.sleep(for: .seconds(3))
                host.layoutSubtreeIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                // The app itself writes no file: the picture goes to standard output, and a script
                // turns it into a PNG.
                guard let data = bitmap.representation(using: .png, properties: [:]) else { continue }
                print("SNAPSHOT \(name)-\(round) \(data.base64EncodedString())")
                fflush(stdout)
            }
        }
        #endif
    }

    /// Kept so the offscreen window lives while it is drawn.
    @MainActor private static var offscreenWindow: NSWindow?
}
