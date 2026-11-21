import SwiftUI

/// The design tokens: every type role, spacing step, radius, colour, size and animation the views
/// use. Views take their values from here, and `DesignTokenTests` fails when one does not. The
/// rules behind the values, and when to use which, are in docs/design.md.
enum Design {
    /// Five roles on the system's text styles, so they follow the user's text size. Each has
    /// monospaced digits, so sizes, counts and dates line up wherever they appear.
    enum Typography {
        /// 17 pt semibold: the title of a sheet or a result.
        static let windowTitle = Font.title2.weight(.semibold).monospacedDigit()
        /// 13 pt semibold: the question of a confirmation, a group's heading.
        static let sectionTitle = Font.headline.monospacedDigit()
        /// 13 pt: file names and everything not named below.
        static let body = Font.body.monospacedDigit()
        /// 12 pt: status lines, explanations, the second line of a row.
        static let secondary = Font.callout.monospacedDigit()
        /// 11 pt: badges and notes beside a value.
        static let caption = Font.subheadline.monospacedDigit()
    }

    /// Steps of the 4 point grid.
    enum Space {
        /// Half a step, for three places only: between the lines of one block of text, inside a
        /// badge, and above and below a list row.
        static let tight: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let badge: CGFloat = 4
        static let card: CGFloat = 12
    }

    /// Colour carries meaning only. Text uses the system's `.primary`, `.secondary` and `.tertiary`;
    /// the accent on the primary button and the selected row is the system's. A colour with a
    /// meaning (destructive, warning) is added here when a view first needs one.
    enum Colour {
        static let badgeFill = HierarchicalShapeStyle.quaternary
        static let hairline = SeparatorShapeStyle()
    }

    enum Icon {
        /// A file's icon and any symbol in a row.
        static let size: CGFloat = 16
        /// The column a row's symbol sits in, so the text after it starts on one edge.
        static let column: CGFloat = 20
    }

    enum Size {
        static let progressBar: CGFloat = 240
        /// The bar of one row in a list of several things in progress.
        static let progressBarCompact: CGFloat = 120
        /// A size at the end of a row, wide enough for "999.9 MB".
        static let sizeColumn: CGFloat = 72
        /// The width the system's checkbox takes in a row, for rows that leave its place empty.
        static let checkbox: CGFloat = 16
    }

    /// Every chart: greys for structure, and one small ordered palette for categories that tells
    /// apart in light and dark mode and for the common kinds of colour blindness (blue, orange,
    /// teal and pink lie far apart in each; the order matters more than the hue). Charts use these
    /// and nothing else (docs/design.md, Charts).
    enum Chart {
        static let palette: [Color] = [.blue, .orange, .teal, .pink, .yellow, .purple, .gray]
        /// Lines and tracks that only give structure.
        static let structure = Color.secondary.opacity(0.25)
        /// A bar in a row of a list, and a thin one beside a ranked file.
        static let barHeight: CGFloat = 8
        static let thinBar: CGFloat = 4
        /// One folder's stacked bar.
        static let folderBar: CGFloat = 20
        /// The width a row's bar is drawn in.
        static let rowBarWidth: CGFloat = 160
        /// The fade a chart arrives with, and nothing more.
        static let appear = Animation.easeOut(duration: 0.2)

        /// The colour of the category at `index` in the palette's order.
        static func colour(_ index: Int) -> Color {
            palette[index % palette.count]
        }
    }

    /// The About window is the system's own, and its one line of ours is AppKit text, not a view:
    /// the small system font, centred, in the label colour so it reads in light and dark mode.
    enum About {
        static var creditsAttributes: [NSAttributedString.Key: Any] {
            let centred = NSMutableParagraphStyle()
            centred.alignment = .center
            return [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: centred,
            ]
        }
    }

    /// The three sizes a sheet comes in. Apply with `sheetSize(_:)`.
    enum Sheet {
        /// A question, a short notice, the welcome: a fixed width, as tall as its content.
        case small
        /// A list to review and its result.
        case medium
        /// Two files side by side.
        case large
    }

    /// Use through `motion(_:value:)`, which honours Reduce Motion, as the chat's animations do.
    enum Motion {
        /// A selection or another small change of state.
        static let quick = Animation.easeOut(duration: 0.15)
        /// A panel opening or closing, rows arriving or leaving.
        static let standard = Animation.easeInOut(duration: 0.25)
    }

    /// The chat bar's own values, kept as they were when the tokens were introduced (decision
    /// 0024). The one place where values off the grid are allowed; nothing else uses them.
    enum Chat {
        static let columnWidth: CGFloat = 720
        static let bubbleWidth: CGFloat = 520
        static let cardWidth: CGFloat = 560

        static let caption = Font.caption.monospacedDigit()
        static let sendGlyph = Font.system(size: 12, weight: .bold)
        static let thinkingGlyph = Font.system(size: 14)

        static let barVertical: CGFloat = 10
        static let fieldLeading: CGFloat = 14
        static let fieldInset: CGFloat = 5
        static let rowGap: CGFloat = 6
        static let messageGap: CGFloat = 18
        static let copyIndent: CGFloat = 22
        static let sendButton: CGFloat = 26
        static let thinkingHeight: CGFloat = 22

        static let fieldRadius: CGFloat = 14
        static let bubbleRadius: CGFloat = 16
        static let glowBlur: CGFloat = 5

        static let panel = Animation.default
        static let glowFade = Animation.easeInOut(duration: 0.3)
        static let glowPulse = Animation.easeInOut(duration: 1.2)
        static let scroll = Animation.smooth(duration: 0.3)
        static let replyFade = Animation.easeOut(duration: 0.2)
        static let thinking = Animation.smooth(duration: 0.55)
    }
}

extension View {
    /// Animates changes of `value` with a `Design.Motion` animation, or not at all when the user
    /// asked for reduced motion.
    func motion(_ animation: Animation, value: some Equatable) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }

    /// Gives a sheet one of the three sizes every sheet uses.
    @ViewBuilder
    func sheetSize(_ size: Design.Sheet) -> some View {
        switch size {
        case .small:
            frame(width: 400)
        case .medium:
            frame(minWidth: 620, idealWidth: 700, minHeight: 420, idealHeight: 540)
        case .large:
            frame(minWidth: 820, idealWidth: 1_000, minHeight: 520, idealHeight: 640)
        }
    }

    /// The inset every bar of the window shares: filter bar, progress line, notices, status bar.
    func barInset() -> some View {
        padding(.horizontal, Design.Space.m)
            .padding(.vertical, Design.Space.xs)
    }
}

private struct MotionModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}
