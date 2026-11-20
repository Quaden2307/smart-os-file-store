import SwiftUI

/// A screen with nothing to list: empty, loading, failed or blocked. One outline symbol, a title,
/// one sentence and at most one action, on the system's `ContentUnavailableView`.
struct StateView<Action: View>: View {
    let title: Text
    /// An outline SF Symbol. Nil while loading: a spinner takes its place.
    let symbol: String?
    var message: Text?
    @ViewBuilder var action: Action

    var body: some View {
        ContentUnavailableView {
            Label {
                title
            } icon: {
                if let symbol {
                    Image(systemName: symbol)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        } description: {
            message
        } actions: {
            action
        }
    }
}

extension StateView where Action == EmptyView {
    init(title: Text, symbol: String?, message: Text? = nil) {
        self.init(title: title, symbol: symbol, message: message) { EmptyView() }
    }

    /// The list is being read.
    static var loading: StateView { StateView(title: Text("Loading…"), symbol: nil) }
}

/// The same state where there is only room for a line: in a bar of the window, in a sheet's
/// content, under the chat. The caller adds the bar's inset.
struct StateBar<Message: View, Actions: View>: View {
    let symbol: String
    var title: Text?
    @ViewBuilder var message: Message
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: Design.Icon.column)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Design.Space.tight) {
                if let title {
                    title
                        .fontWeight(.semibold)
                }
                message
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            Spacer(minLength: Design.Space.m)
            actions
        }
        .font(Design.Typography.secondary)
    }
}

extension StateBar where Message == Text {
    init(symbol: String, title: Text? = nil, message: Text, @ViewBuilder actions: () -> Actions) {
        self.init(symbol: symbol, title: title, message: { message }, actions: actions)
    }
}

extension StateBar where Message == Text, Actions == EmptyView {
    init(symbol: String, title: Text? = nil, message: Text) {
        self.init(symbol: symbol, title: title, message: { message }, actions: { EmptyView() })
    }
}

extension StateBar where Actions == EmptyView {
    init(symbol: String, title: Text? = nil, @ViewBuilder message: () -> Message) {
        self.init(symbol: symbol, title: title, message: message, actions: { EmptyView() })
    }
}
