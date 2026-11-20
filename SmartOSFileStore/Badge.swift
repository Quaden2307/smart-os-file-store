import SwiftUI

/// A quiet tag after a name: a file's mark, "Keep", "Possible match". The text carries the
/// meaning, so it reads the same in light and dark mode and to VoiceOver.
struct Badge: View {
    let text: Text

    init(_ text: Text) {
        self.text = text
    }

    var body: some View {
        text
            .font(Design.Typography.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Design.Space.xs)
            .padding(.vertical, Design.Space.tight)
            .background(Design.Colour.badgeFill, in: .rect(cornerRadius: Design.Radius.badge))
            .fixedSize()
    }
}
