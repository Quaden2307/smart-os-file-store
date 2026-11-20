import FileStoreCore
import SwiftUI

/// How the app shows one cleanup action: in the Clean Up menus, the progress line, the preview and
/// Activity. Each action has exactly one, in `CleanupAction.display`, so adding an action means
/// adding its entry there.
struct CleanupActionDisplay {
    /// What the progress line shows while the action looks for things to change.
    enum ProgressStyle {
        /// A bar by bytes read, and the counts: an action that reads whole files (Find Duplicates).
        case bytesRead
        /// A bar by zips checked, and the count.
        case zipsChecked
        /// A bar by installers checked, and the count.
        case installersChecked
        /// A small spinner and the progress label: an action that reads no files.
        case spinner
    }

    /// The preview's title: "Duplicates".
    let title: String

    /// The action as a command, as the Clean Up menus name it: "Find Duplicates". An undo is named
    /// after it ("Undo Find Duplicates").
    let commandTitle: String

    /// One sentence on what the action does, shown as the menu item's help.
    let explanation: String

    /// The SF Symbol shown beside the command.
    let symbol: String

    /// The Clean Up menu's shortcut, with Shift and Command: each action has its own letter.
    let shortcutKey: KeyEquivalent

    /// The progress line's words while the action looks for things to change: "Finding duplicates".
    let progressLabel: String

    /// Cancel's help on the progress line: "Stop finding duplicates (Esc)".
    let cancelHelp: String

    /// How the progress line shows how far the action has got.
    let progressStyle: ProgressStyle

    /// What the preview says when the action found nothing to change.
    let emptyTitle: String

    let emptyDescription: String

    var shortcut: KeyboardShortcut {
        KeyboardShortcut(shortcutKey, modifiers: [.command, .shift])
    }
}

extension CleanupAction {
    /// The action's display entry.
    var display: CleanupActionDisplay {
        switch self {
        case .findDuplicates:
            CleanupActionDisplay(
                title: String(localized: "Duplicates"),
                commandTitle: String(localized: "Find Duplicates"),
                explanation: String(localized: "Find files with identical content."),
                symbol: "doc.on.doc",
                shortcutKey: "d",
                progressLabel: String(localized: "Finding duplicates"),
                cancelHelp: String(localized: "Stop finding duplicates (Esc)"),
                progressStyle: .bytesRead,
                emptyTitle: String(localized: "No duplicates found"),
                emptyDescription: String(
                    localized: "No two of the files checked have the same content. Files added or changed in the last hour are checked once they are an hour old."
                )
            )
        case .clearFailedDownloads:
            CleanupActionDisplay(
                title: String(localized: "Failed downloads"),
                commandTitle: String(localized: "Clear Failed Downloads"),
                explanation: String(localized: "Move downloads that stopped and never finished to the Trash."),
                symbol: "arrow.down.circle",
                shortcutKey: "f",
                progressLabel: String(localized: "Looking for failed downloads"),
                cancelHelp: String(localized: "Stop looking for failed downloads (Esc)"),
                progressStyle: .spinner,
                emptyTitle: String(localized: "No failed downloads found"),
                emptyDescription: String(
                    localized: "No partial download has gone untouched for more than an hour. One that changed in the last hour may still be downloading, so it is left alone."
                )
            )
        case .removeUnpackedZips:
            CleanupActionDisplay(
                title: String(localized: "Unpacked zips"),
                commandTitle: String(localized: "Remove Unpacked Zips"),
                explanation: String(localized: "Move zips whose contents are already unpacked next to them to the Trash."),
                symbol: "doc.zipper",
                shortcutKey: "u",
                progressLabel: String(localized: "Checking zips"),
                cancelHelp: String(localized: "Stop checking zips (Esc)"),
                progressStyle: .zipsChecked,
                emptyTitle: String(localized: "No unpacked zips found"),
                emptyDescription: String(
                    localized: "No zip checked has everything it holds next to it at the same size. Zips, and what they were unpacked to, are checked once they have gone untouched for an hour."
                )
            )
        case .removeUsedInstallers:
            CleanupActionDisplay(
                title: String(localized: "Used installers"),
                commandTitle: String(localized: "Remove Used Installers"),
                explanation: String(localized: "Move disk images, packages and app zips whose apps are already installed to the Trash."),
                symbol: "shippingbox",
                shortcutKey: "i",
                progressLabel: String(localized: "Checking installers"),
                cancelHelp: String(localized: "Stop checking installers (Esc)"),
                progressStyle: .installersChecked,
                emptyTitle: String(localized: "No used installers found"),
                emptyDescription: String(
                    localized: "No disk image, package or app zip checked is for an app installed on this Mac. Installers added or changed in the last hour are checked once they are an hour old."
                )
            )
        case .fixMessyNames:
            CleanupActionDisplay(
                title: String(localized: "Messy names"),
                commandTitle: String(localized: "Fix Messy Names"),
                explanation: String(localized: "Give files with copy numbers or leftover junk in their names a clean name."),
                symbol: "textformat",
                shortcutKey: "m",
                progressLabel: String(localized: "Looking for messy names"),
                cancelHelp: String(localized: "Stop looking for messy names (Esc)"),
                progressStyle: .spinner,
                emptyTitle: String(localized: "No messy names found"),
                emptyDescription: String(
                    localized: "Every file checked already has a clean name. Files added or changed in the last hour are checked once they are an hour old."
                )
            )
        case .reviewNearDuplicates:
            CleanupActionDisplay(
                title: String(localized: "Similar names, different content"),
                commandTitle: String(localized: "Review Near-Duplicates"),
                explanation: String(localized: "List files with the same name and different content, so you can compare them. Nothing is ticked for you."),
                symbol: "square.on.square.dashed",
                shortcutKey: "r",
                progressLabel: String(localized: "Looking for files with the same name"),
                cancelHelp: String(localized: "Stop looking for files with the same name (Esc)"),
                progressStyle: .spinner,
                emptyTitle: String(localized: "No near-duplicates found"),
                emptyDescription: String(
                    localized: "No two files checked share a name with different content. Files with identical content are duplicates: Find Duplicates handles those. Files added or changed in the last hour are checked once they are an hour old."
                )
            )
        case .archiveOldDownloads:
            CleanupActionDisplay(
                title: String(localized: "Old downloads"),
                commandTitle: String(localized: "Archive Old Downloads"),
                explanation: String(localized: "Move files you haven’t opened in a while into the Old downloads folder. Nothing is deleted."),
                symbol: "archivebox",
                shortcutKey: "o",
                progressLabel: String(localized: "Looking for old downloads"),
                cancelHelp: String(localized: "Stop looking for old downloads (Esc)"),
                progressStyle: .spinner,
                emptyTitle: String(localized: "No old downloads found"),
                emptyDescription: String(
                    localized: "No file checked is marked Never opened or Unused. Change when files count as unused in Settings (⌘,). Files added or changed in the last hour are checked once they are an hour old."
                )
            )
        case .reviewLargeDownloads:
            CleanupActionDisplay(
                title: String(localized: "Large downloads"),
                commandTitle: String(localized: "Review Large Downloads"),
                explanation: String(localized: "List the files taking the most space on disk, largest first, so you can decide what to keep. Nothing is ticked for you."),
                symbol: "externaldrive",
                shortcutKey: "l",
                progressLabel: String(localized: "Looking for large downloads"),
                cancelHelp: String(localized: "Stop looking for large downloads (Esc)"),
                progressStyle: .spinner,
                emptyTitle: String(localized: "No large downloads found"),
                emptyDescription: String(
                    localized: "No file checked takes up as much space on disk as the size set in Settings (⌘,). Folders are not listed. Files added or changed in the last hour are checked once they are an hour old."
                )
            )
        case .removeEmptyFolders:
            CleanupActionDisplay(
                title: String(localized: "Empty folders"),
                commandTitle: String(localized: "Remove Empty Folders"),
                explanation: String(localized: "Move folders with nothing in them to the Trash. A folder holding only empty folders or Finder’s .DS_Store counts as empty."),
                symbol: "folder.badge.minus",
                shortcutKey: "e",
                progressLabel: String(localized: "Looking for empty folders"),
                cancelHelp: String(localized: "Stop looking for empty folders (Esc)"),
                progressStyle: .spinner,
                emptyTitle: String(localized: "No empty folders found"),
                emptyDescription: String(
                    localized: "Every folder checked holds at least one file. Folders added or changed in the last hour are checked once they are an hour old."
                )
            )
        }
    }

    /// The preview's title.
    var title: String { display.title }

    /// The action as a command: what the menus show and an undo is named after.
    var commandTitle: String { display.commandTitle }

    /// The actions the Clean Up menus offer: those with a planner, in declaration order.
    static var menuActions: [CleanupAction] {
        allCases.filter(CleanupPlanners.hasPlanner)
    }
}
