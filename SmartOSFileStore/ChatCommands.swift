import SwiftUI

/// What the View menu's chat item acts on in the frontmost main window.
struct ChatCommandTarget {
    /// Puts the cursor in the chat bar and shows the conversation so far.
    let focus: @MainActor () -> Void
}

extension FocusedValues {
    /// The frontmost main window's chat bar. Nil while a sheet is up.
    @Entry var chatCommands: ChatCommandTarget?
}

/// View menu: Ask About Downloads (Command-K), which moves to the chat bar from anywhere in the window.
struct ChatCommands: Commands {
    @FocusedValue(\.chatCommands) private var target

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Ask About This Folder") {
                target?.focus()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(target == nil)
            Divider()
        }
    }
}
