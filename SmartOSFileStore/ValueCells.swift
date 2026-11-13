import SwiftUI

/// A date the way the table shows one, or a dash when there is none.
struct DateCell: View {
    let date: Date?

    var body: some View {
        if let date {
            Text(date, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                .monospacedDigit()
        } else {
            NoValueCell(label: "No date")
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
