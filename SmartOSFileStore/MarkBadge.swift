import FileStoreCore
import SwiftUI

/// A mark shown as a small labelled capsule after a file's name. The text carries the meaning, so
/// it reads the same in light and dark mode and to VoiceOver.
struct MarkBadge: View {
    let mark: FileMark

    var body: some View {
        Text(mark.title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.fill.tertiary, in: .capsule)
            .fixedSize()
    }
}
