import SwiftUI

/// The one line every piece of work in progress is shown as: a bar once the total is known and a
/// small spinner until then, the count in words, and the work's own Stop button where it can be
/// stopped.
struct ProgressLine<Stop: View>: View {
    /// Nil until a total is known.
    let fraction: Double?
    /// What is happening, with the count: "Moving file 3 of 12 to the Trash…".
    let text: Text
    /// VoiceOver's name for the bar.
    let label: Text
    @ViewBuilder var stop: Stop

    var body: some View {
        HStack(spacing: Design.Space.m) {
            Group {
                if let fraction {
                    ProgressView(value: fraction)
                        .frame(maxWidth: Design.Size.progressBar)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .accessibilityLabel(label)
            text
                .font(Design.Typography.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 0)
            stop
        }
    }
}

extension ProgressLine where Stop == EmptyView {
    init(fraction: Double?, text: Text, label: Text) {
        self.init(fraction: fraction, text: text, label: label) { EmptyView() }
    }
}
