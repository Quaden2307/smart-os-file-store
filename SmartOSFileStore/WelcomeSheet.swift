import FileStoreCore
import SwiftUI

/// The welcome, shown once over the main window before the folder is first read: what the app does
/// in three lines, what it promises, and one button. The folder is read when it closes, so the
/// Mac's question about Downloads comes after the promise, not before it.
struct WelcomeSheet: View {
    /// Desktop and Documents, turned on as the welcome closes when their switch is on.
    @Binding var turnOn: Set<ManagedFolder.Kind>

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(
            title: Text("Welcome to Smart OS File Store"),
            subtitle: Text("A tidy Downloads folder, and you decide every change."),
            size: .small
        ) {
            VStack(alignment: .leading, spacing: Design.Space.l) {
                group(Text("What it does")) {
                    line("list.bullet", Text("Lists everything in your Downloads folder."))
                    line("magnifyingglass", Text("Finds duplicates, used installers, failed downloads and old files."))
                    line("checklist", Text("Cleans them up when you say so, from the toolbar or by asking in your own words."))
                }
                group(Text("The promise")) {
                    line("eye", Text("You see a preview before anything changes."))
                    line("trash", Text("Files go to the Trash. Nothing is deleted for good."))
                    line("arrow.uturn.backward", Text("Every change can be undone."))
                    line("lock", Text("Nothing leaves this Mac."))
                }
                group(Text("Also look after")) {
                    folderToggle(.desktop)
                    folderToggle(.documents)
                }
                Text("Next, your Mac may ask to let the app read each folder.")
                    .font(Design.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Design.Space.l)
        } buttons: {
            Button("Get started") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .help("Close this and read your folders (Return)")
        }
        .onExitCommand {
            dismiss()
        }
    }

    private func folderToggle(_ kind: ManagedFolder.Kind) -> some View {
        Toggle(
            kind.standardName,
            isOn: Binding(
                get: { turnOn.contains(kind) },
                set: { isOn in
                    if isOn { turnOn.insert(kind) } else { turnOn.remove(kind) }
                }
            )
        )
        .toggleStyle(.checkbox)
        .help("You can turn it on or off later in the sidebar")
    }

    private func group(_ title: Text, @ViewBuilder lines: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            title
                .font(Design.Typography.sectionTitle)
                .accessibilityAddTraits(.isHeader)
            lines()
        }
    }

    private func line(_ symbol: String, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: Design.Icon.column)
                .accessibilityHidden(true)
            text
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
