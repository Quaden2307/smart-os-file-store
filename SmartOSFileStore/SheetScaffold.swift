import SwiftUI

/// The frame every sheet shares: a title with one line saying what will happen, the content, and a
/// footer with a note or secondary actions on the left and the buttons on the right, the main one
/// last. Layout only: closing, shortcuts and button roles stay with each sheet.
struct SheetScaffold<Content: View, Status: View, Buttons: View>: View {
    let title: Text
    var subtitle: Text?
    var size: Design.Sheet = .medium
    @ViewBuilder var content: Content
    /// The footer's left side: Tick all and Tick none, a progress line, a note.
    @ViewBuilder var status: Status
    /// The footer's right side, in the order they are given.
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                title
                    .font(Design.Typography.windowTitle)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    subtitle
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Design.Space.l)
            Divider()
            if Content.self != EmptyView.self {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                Divider()
            }
            HStack(spacing: Design.Space.m) {
                status
                Spacer(minLength: 0)
                buttons
            }
            .padding(Design.Space.m)
        }
        .sheetSize(size)
    }
}

extension SheetScaffold where Status == EmptyView {
    init(
        title: Text, subtitle: Text? = nil, size: Design.Sheet = .medium,
        @ViewBuilder content: () -> Content, @ViewBuilder buttons: () -> Buttons
    ) {
        self.init(title: title, subtitle: subtitle, size: size, content: content, status: { EmptyView() }, buttons: buttons)
    }
}
