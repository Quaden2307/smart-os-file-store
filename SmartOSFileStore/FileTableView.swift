import AppKit
import FileStoreCore
import QuickLook
import SwiftUI

/// The sortable file table, showing the rows the filter lets through. Space, Command-Y or a double
/// click opens Quick Look (on the Old downloads folder alone, each opens it in Finder); the context menu and the File menu reveal the selection in Finder and
/// keep it (Keep This File, Shift-Command-K), and the context menu copies where a file was downloaded
/// from. Hovering anywhere on a row shows the site and app it came from.
struct FileTableView: View {
    @Bindable var model: FileListModel
    @Binding var selection: Set<FileRecord.ID>

    /// False while another place of the window is shown. The table stays, out of sight, so it keeps
    /// its scroll position and column widths; Quick Look closes, since nothing on screen would own it.
    var isShown = true

    /// False while the Kept list cannot be changed: Keep This File is then shown disabled.
    var canChangeKept = false

    /// A request to bring one row into view. A new value each time, so asking for the same file
    /// twice scrolls twice.
    struct Reveal: Equatable {
        let id: FileRecord.ID
        private let request = UUID()
    }

    /// The row the chat asked to show, already selected by the window.
    var reveal: Reveal?

    @State private var previewItem: URL?
    @State private var previewItems: [URL] = []

    var body: some View {
        ScrollViewReader { proxy in
            table
                .onChange(of: reveal) { _, reveal in
                    guard let reveal else { return }
                    // On the next turn: a filter cleared with the request has put the row back by then.
                    Task { @MainActor in
                        proxy.scrollTo(reveal.id, anchor: .center)
                    }
                }
        }
    }

    private var table: some View {
        Table(model.visibleRecords, selection: $selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", sortUsing: FileListSort.name) { record in
                HStack(spacing: Design.Space.s) {
                    FileIconView(record: record)
                    Text(record.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ForEach(model.marks(for: record), id: \.self) { mark in
                        Badge(Text(mark.title))
                    }
                }
                // One element for VoiceOver: "old-manual.pdf, Never opened, Old".
                .accessibilityElement(children: .combine)
                .rowHelp(record.downloadSourceTooltip)
            }
            .width(min: 200, ideal: 280)

            TableColumn("Kind", sortUsing: FileListSort.kind) { record in
                Text(record.kindDescription)
                    .lineLimit(1)
                    .rowHelp(record.downloadSourceTooltip)
            }
            .width(min: 88, ideal: 132)

            TableColumn("Size", sortUsing: FileListSort.size) { record in
                Group {
                    if let size = record.formattedSize {
                        Text(size)
                    } else {
                        NoValueCell(label: "No size")
                    }
                }
                .rowHelp(record.downloadSourceTooltip, alignment: .trailing)
            }
            .width(min: 64, ideal: 72)
            .alignment(.numeric)

            TableColumn("Date added", sortUsing: FileListSort.dateAdded) { record in
                DateCell(date: record.dateAdded)
                    .rowHelp(record.downloadSourceTooltip)
            }
            .width(min: 144, ideal: 164)

            TableColumn("Date modified", sortUsing: FileListSort.dateModified) { record in
                DateCell(date: record.dateModified)
                    .rowHelp(record.downloadSourceTooltip)
            }
            .width(min: 144, ideal: 164)

            TableColumn("Last opened", sortUsing: FileListSort.lastOpened) { record in
                LastOpenedCell(record: record)
                    .rowHelp(record.downloadSourceTooltip)
            }
            .width(min: 144, ideal: 164)
        }
        // Finder's density, without its stripes: the selected row is the only filled one.
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: FileRecord.ID.self) { ids in
            Button("Quick Look") {
                preview(ids)
            }
            Button("Reveal in Finder") {
                RevealInFinder.reveal(urls(for: ids))
            }
            Divider()
            let toggle = model.keepToggle(for: ids)
            Button((toggle ?? .keep).title) {
                model.toggleKept(ids)
            }
            .disabled(!canChangeKept || toggle == nil)
            Divider()
            Button("Copy Download Source") {
                Clipboard.copy(model.downloadAddresses(for: ids).joined(separator: "\n"))
            }
            .disabled(model.downloadAddresses(for: ids).isEmpty)
        } primaryAction: { ids in
            preview(ids)
        }
        .onKeyPress(.space) {
            guard toggleQuickLook() else { return .ignored }
            return .handled
        }
        .onKeyPress(phases: .down) { press in
            // Command-Y, as in Finder. Handled by the table itself, so it works wherever the
            // table has focus and needs no menu item to be enabled first.
            guard press.key == "y", press.modifiers == .command, toggleQuickLook() else { return .ignored }
            return .handled
        }
        .quickLookPreview($previewItem, in: previewItems)
        .onChange(of: isShown) { _, isShown in
            if !isShown {
                previewItem = nil
            }
        }
        .accessibilityLabel("Files")
        .overlay {
            if model.visibleRecords.isEmpty, case .marked(let mark) = model.filter {
                ContentUnavailableView(
                    "No matching files",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text(mark.emptyFilterDescription)
                )
            }
        }
    }

    /// Opens Quick Look for the selection, or closes it when it is showing, as in Finder: the panel
    /// sets the binding back to nil when it closes. False when there was nothing to do.
    private func toggleQuickLook() -> Bool {
        if previewItem != nil {
            previewItem = nil
            return true
        }
        guard !selection.isEmpty else { return false }
        preview(selection)
        return true
    }

    /// The selected URLs in the table's display order.
    private func urls(for ids: Set<FileRecord.ID>) -> [URL] {
        model.visibleRecords.filter { ids.contains($0.id) }.map(\.url)
    }

    private func preview(_ ids: Set<FileRecord.ID>) {
        // The archive is a folder to look in, not a file to look at: it opens in Finder.
        if ids.count == 1, let id = ids.first, let record = model.record(for: id), record.isArchiveFolder {
            NSWorkspace.shared.open(record.url)
            return
        }
        let urls = urls(for: ids)
        guard !urls.isEmpty else { return }
        previewItems = urls
        previewItem = urls.first
    }
}

private extension View {
    /// Shows `text` as the row's tooltip. The cell is filled first, so the tooltip appears wherever
    /// the pointer is on the row, not only over the text. SwiftUI offers no tooltip for a whole row.
    @ViewBuilder
    func rowHelp(_ text: String?, alignment: Alignment = .leading) -> some View {
        let filled = frame(maxWidth: .infinity, alignment: alignment)
        if let text {
            filled.help(text)
        } else {
            filled
        }
    }
}
