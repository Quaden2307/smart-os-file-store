import SwiftUI

/// What the Edit menu's undo items act on in the frontmost main window.
struct UndoCommandTarget {
    /// "Undo Find Duplicates" for the newest cleanup run, or "Undo" when there is nothing to undo.
    let title: String

    /// False when there is nothing to undo, or the window is busy.
    let canUndo: Bool

    let undo: @MainActor () -> Void

    /// False unless Activity shows one selected run or item that can be undone.
    let canUndoSelection: Bool

    let undoSelection: @MainActor () -> Void
}

extension FocusedValues {
    /// The frontmost main window's undo. Nil while a sheet is up.
    @Entry var undoCommands: UndoCommandTarget?
}

/// Edit menu: Undo (Command-Z), named after the newest cleanup run, and Undo Selected for what is
/// selected in Activity. They take the place of the standard Undo and Redo: there is no redo in
/// this version, and the app has no text a user edits.
struct UndoCommands: Commands {
    @FocusedValue(\.undoCommands) private var target

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(target?.title ?? String(localized: "Undo")) {
                target?.undo()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(target?.canUndo != true)
            Button("Undo Selected") {
                target?.undoSelection()
            }
            .disabled(target?.canUndoSelection != true)
        }
    }
}
