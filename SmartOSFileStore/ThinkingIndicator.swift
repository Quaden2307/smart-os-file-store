import SwiftUI

/// Shown while the model is working, until the first words of its reply: three small documents
/// shuffled like cards, the front one sliding to the back. With Reduce Motion, one document that
/// slowly fades in and out.
struct ThinkingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cards = ["doc.text.fill", "doc.fill", "doc.richtext.fill"]

    var body: some View {
        Group {
            if reduceMotion {
                Image(systemName: "doc.text")
                    .symbolEffect(.pulse, options: .repeating)
            } else {
                PhaseAnimator(Self.cards.indices) { phase in
                    ZStack(alignment: .leading) {
                        ForEach(Self.cards.indices, id: \.self) { card in
                            // 0 is the front. Each phase moves every card one place back, the
                            // back one round to the front.
                            let place = (card - phase + Self.cards.count) % Self.cards.count
                            Image(systemName: Self.cards[card])
                                .rotationEffect(.degrees(Double(place) * 7 - 7))
                                .offset(x: CGFloat(place) * 7, y: CGFloat(place) * -1.5)
                                .opacity(1 - Double(place) * 0.3)
                                .zIndex(Double(Self.cards.count - place))
                        }
                    }
                } animation: { _ in
                    .smooth(duration: 0.55)
                }
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(.secondary)
        .frame(width: 40, height: 22, alignment: .leading)
        .accessibilityElement()
        .accessibilityLabel("Looking through your files")
    }
}
