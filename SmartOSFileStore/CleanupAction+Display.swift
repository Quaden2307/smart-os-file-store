import FileStoreCore
import SwiftUI

/// How the app shows one cleanup action: in the Clean Up menus, the progress line, the preview and
/// Activity. Each action has exactly one, in `CleanupAction.display`, so adding an action means
/// adding its entry there.
struct CleanupActionDisplay {
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

    /// True when the action reads file content, and the progress line shows how much is read.
    let showsReadingProgress: Bool

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
                showsReadingProgress: true,
                emptyTitle: String(localized: "No Duplicates Found"),
                emptyDescription: String(
                    localized: "No two of the files checked have the same content. Files added or changed in the last hour are checked once they are an hour old."
                )
            )
        case .clearFailedDownloads:
            CleanupActionDisplay(
                title: String(localized: "Failed Downloads"),
                commandTitle: String(localized: "Clear Failed Downloads"),
                explanation: String(localized: "Move downloads that stopped and never finished to the Trash."),
                symbol: "arrow.down.circle",
                shortcutKey: "f",
                progressLabel: String(localized: "Looking for failed downloads"),
                cancelHelp: String(localized: "Stop looking for failed downloads (Esc)"),
                showsReadingProgress: false,
                emptyTitle: String(localized: "No Failed Downloads Found"),
                emptyDescription: String(
                    localized: "No partial download has gone untouched for more than an hour. One that changed in the last hour may still be downloading, so it is left alone."
                )
            )
        case .fixMessyNames:
            CleanupActionDisplay(
                title: String(localized: "Messy Names"),
                commandTitle: String(localized: "Fix Messy Names"),
                explanation: String(localized: "Give files with copy numbers or leftover junk in their names a clean name."),
                symbol: "textformat",
                shortcutKey: "m",
                progressLabel: String(localized: "Looking for messy names"),
                cancelHelp: String(localized: "Stop looking for messy names (Esc)"),
                showsReadingProgress: false,
                emptyTitle: String(localized: "No Messy Names Found"),
                emptyDescription: String(
                    localized: "Every file checked already has a clean name. Files added or changed in the last hour are checked once they are an hour old."
                )
            )
        case .archiveOldDownloads:
            CleanupActionDisplay(
                title: String(localized: "Old Downloads"),
                commandTitle: String(localized: "Archive Old Downloads"),
                explanation: String(localized: "Move old downloads into the Old downloads folder."),
                symbol: "archivebox",
                shortcutKey: "o",
                progressLabel: String(localized: "Looking for old downloads"),
                cancelHelp: String(localized: "Stop looking for old downloads (Esc)"),
                showsReadingProgress: false,
                emptyTitle: String(localized: "No Old Downloads Found"),
                emptyDescription: String(localized: "None of the files checked is old enough to archive.")
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
