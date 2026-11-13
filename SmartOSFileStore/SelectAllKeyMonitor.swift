import AppKit

/// Sees Command-A before the key window does and hands it to `select`, which returns true when it
/// used the key. Lives as long as its owner keeps it; removing the monitor is its deinit.
///
/// AppKit, because a SwiftUI list claims Command-A as the standard Select All in the window's own
/// key-equivalent pass, ahead of any `keyboardShortcut` on a button, so a sheet that wants
/// Command-A to mean something else has to see the key first.
@MainActor
final class SelectAllKeyMonitor {
    private var monitor: Any?

    init(select: @escaping @MainActor () -> Bool) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers == .command, event.charactersIgnoringModifiers == "a" else { return event }
            return select() ? nil : event
        }
    }

    // Isolated, so it may touch the main-actor monitor handle: the sheet is gone, stop listening.
    isolated deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
