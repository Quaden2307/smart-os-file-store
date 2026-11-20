import FileStoreCore
import SwiftUI

/// A date the way the table shows one, or a dash when there is none.
struct DateCell: View {
    let date: Date?

    var body: some View {
        if let date {
            Text(date, format: .dateTime.year().month(.abbreviated).day().hour().minute())
        } else {
            NoValueCell(label: "No date")
        }
    }
}

/// The Last Opened column: the date, "Never" for an item macOS would have dated had it been opened,
/// or a dash for a folder, app or link, which macOS does not date.
struct LastOpenedCell: View {
    let record: FileRecord

    var body: some View {
        if let lastOpened = record.lastOpened {
            DateCell(date: lastOpened)
        } else if record.recordsLastOpened {
            Text("Never")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Never opened")
        } else {
            NoValueCell(label: "Not recorded")
        }
    }
}

/// A dash for a cell that has no value, read out meaningfully by VoiceOver.
struct NoValueCell: View {
    let label: LocalizedStringKey

    var body: some View {
        Text(verbatim: "—")
            .foregroundStyle(.secondary)
            .accessibilityLabel(label)
    }
}
