import FileStoreIntelligence
import SwiftUI

/// The chat at the bottom of the main window: the conversation, while it is open, and under it the
/// bar to ask in. When Apple Intelligence cannot answer, the bar is one line saying why instead.
struct ChatSection: View {
    @Bindable var chat: ChatModel
    let files: FileListModel
    var isFocused: FocusState<Bool>.Binding
    let showInList: @MainActor (URL) -> Void

    @AppStorage(IntelligenceAvailability.enabledKey) private var usesAppleIntelligence = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    /// False until the window has been the key window once. A window gives the keyboard to its
    /// first text field when it opens; the field stays out of that choice, so the keyboard starts
    /// in the sidebar as it did before the chat bar, and the model is not loaded at every launch.
    @State private var canTakeKeyboard = false

    var body: some View {
        // Read here, in the body, so the bar is drawn again when the system's side changes.
        let availability = IntelligenceAvailability.current(enabledInSettings: usesAppleIntelligence)
        VStack(spacing: 0) {
            if chat.isPanelOpen, !chat.messages.isEmpty {
                ConversationPanel(chat: chat, files: files, showInList: showInList)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                Divider()
            }
            if availability == .available {
                ChatBar(chat: chat, isFocused: isFocused, canTakeKeyboard: canTakeKeyboard)
            } else {
                ChatUnavailableBar(availability: availability)
            }
        }
        .clipped()
        .animation(reduceMotion ? nil : .default, value: chat.isPanelOpen)
        // Escape, with the cursor in the bar or the conversation, puts the conversation away.
        .onExitCommand {
            chat.isPanelOpen = false
        }
        .onChange(of: availability) { _, availability in
            // Switched off, here or in System Settings, while a reply was arriving: the bar that
            // replaces this one has no Stop, so the reply stops with it.
            if availability != .available {
                chat.stop()
            }
        }
        .onChange(of: controlActiveState, initial: true) { _, state in
            guard state == .key, !canTakeKeyboard else { return }
            // On the next turn: by then the window has chosen what starts with the keyboard.
            Task { @MainActor in
                canTakeKeyboard = true
            }
        }
    }
}

/// The field to ask in, with Send, or Stop while a reply is arriving. Until the first question,
/// three example questions sit above it. (Not only while the field has the cursor: a button that
/// goes away when the keyboard moves to it could never be pressed from the keyboard.)
struct ChatBar: View {
    @Bindable var chat: ChatModel
    var isFocused: FocusState<Bool>.Binding

    /// False while the window is opening, when the field must not be handed the keyboard.
    var canTakeKeyboard = true

    private static let examples = [
        String(localized: "What’s taking the most space?"),
        String(localized: "What did I download last week and never open?"),
        String(localized: "How many files have I never opened?"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if chat.messages.isEmpty {
                HStack(spacing: 8) {
                    Text("Try asking:")
                        .foregroundStyle(.secondary)
                    ForEach(Self.examples, id: \.self) { example in
                        Button(example) {
                            chat.ask(example)
                        }
                        .controlSize(.small)
                        .disabled(!chat.canAsk)
                        .help("Ask this question")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Example questions")
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Ask about your Downloads", text: $chat.draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused(isFocused)
                    .disabled(!canTakeKeyboard)
                    .onSubmit(chat.send)
                    .accessibilityLabel("Question about your Downloads")
                    .help("Ask about the files in this folder (⌘K). Answers are worked out on this Mac.")
                if !chat.messages.isEmpty, !chat.isPanelOpen {
                    Button {
                        chat.isPanelOpen = true
                    } label: {
                        Label("Show Conversation", systemImage: "chevron.up")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Show the conversation")
                }
                if chat.isResponding {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Answering")
                    Button("Stop", action: chat.stop)
                        .help("Stop the reply")
                } else {
                    Button("Send", action: chat.send)
                        .disabled(!chat.canSend)
                        .help("Send the question (Return)")
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onChange(of: isFocused.wrappedValue) { _, isFocused in
            if isFocused {
                chat.prewarm()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat")
    }
}

/// The bar while the chat cannot answer: the reason, and the way to change it where there is one.
/// The rest of the window works as it does without the chat.
struct ChatUnavailableBar: View {
    let availability: IntelligenceAvailability

    @Environment(\.openURL) private var openURL

    /// The Apple Intelligence & Siri pane of System Settings.
    private static let systemSettingsPane = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(availability.reason ?? "")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            if availability.isChangedInSystemSettings, let pane = Self.systemSettingsPane {
                Button("Open System Settings") {
                    openURL(pane)
                }
                .help("Open Apple Intelligence & Siri in System Settings")
            } else if availability == .turnedOffInSettings {
                SettingsLink {
                    Text("Open Settings")
                }
                .help("Open this app’s Settings (⌘,)")
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat")
    }
}
