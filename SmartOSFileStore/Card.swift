import SwiftUI

/// The one card: a result summarised, self-contained, in a flow of other content. An outline, no
/// fill and no shadow. Never inside another card, and never around a region of the window
/// (docs/design.md, Card).
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            content
        }
        .padding(Design.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).strokeBorder(Design.Colour.hairline))
    }
}

/// A card's first line: what it is, one line saying more, and at the far end its number, date or
/// button. A group or a run in a list uses the same layout without the outline.
struct CardHeader<Subtitle: View, Trailing: View>: View {
    let title: Text
    /// False where the header is a row of a list, so VoiceOver's headings stay the list's sections.
    var isHeading = true
    @ViewBuilder var subtitle: Subtitle
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.m) {
            VStack(alignment: .leading, spacing: Design.Space.tight) {
                title
                    .font(Design.Typography.sectionTitle)
                    .accessibilityAddTraits(isHeading ? .isHeader : [])
                subtitle
                    .font(Design.Typography.secondary)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Design.Space.m)
            trailing
        }
    }
}

extension CardHeader where Subtitle == Text? {
    init(title: Text, subtitle: Text? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, subtitle: { subtitle }, trailing: trailing)
    }
}

extension CardHeader where Subtitle == Text?, Trailing == EmptyView {
    init(title: Text, subtitle: Text? = nil) {
        self.init(title: title, subtitle: { subtitle }, trailing: { EmptyView() })
    }
}

/// A card's numbers, side by side: how many, how much.
struct CardFigures<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.xl) {
            content
        }
    }
}

/// One number of a card with what it counts under it. VoiceOver reads the two as one.
struct CardFigure: View {
    let value: Text
    let label: Text

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.tight) {
            value
                .font(Design.Typography.windowTitle)
            label
                .font(Design.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A card's last line: one sentence on the left, its buttons at the far end, the main one last.
struct CardActions<Status: View, Buttons: View>: View {
    @ViewBuilder var status: Status
    @ViewBuilder var buttons: Buttons

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
            status
                .font(Design.Typography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Design.Space.m)
            buttons
        }
    }
}
