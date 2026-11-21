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

    /// `-SkipWelcome`: the welcome is not shown, and nothing is stored about it.
    static var skipsWelcome: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-SkipWelcome")
        #else
        false
        #endif
    }

    /// `-WindowSize 1440x900`: the main window at that size, centred on its screen, for recording.
    @MainActor
    static func applyWindowSize(arguments: [String] = ProcessInfo.processInfo.arguments) {
        #if DEBUG
        guard let index = arguments.firstIndex(of: "-WindowSize"), arguments.index(after: index) < arguments.endIndex else { return }
        let parts = arguments[arguments.index(after: index)].split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return }
        // On the next turn, once the window is on screen with its restored frame.
        Task { @MainActor in
            guard let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
                  let screen = window.screen ?? NSScreen.main else { return }
            let visible = screen.visibleFrame
            let size = NSSize(width: parts[0], height: parts[1])
            let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
            window.setFrame(NSRect(origin: origin, size: size), display: true)
        }
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
        // Off screen the window draws no background of its own: one appearance throughout, so text
        // and the background behind it match.
        let dark = ProcessInfo.processInfo.arguments.contains("-SnapshotDark")
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(.background))
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
