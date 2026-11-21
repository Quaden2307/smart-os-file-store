import FileStoreIntelligence
import SwiftUI

/// The chat at the bottom of the main window: the conversation, while it is open, and under it the
/// field to ask in. When Apple Intelligence cannot answer, the field is one line saying why instead.
struct ChatSection: View {
    @Bindable var chat: ChatModel
    let files: FileListModel
    /// Every folder's list, where the conversation finds the files of an answer about several.
    let lists: FolderListsModel
    var isFocused: FocusState<Bool>.Binding
    let showInList: @MainActor (URL) -> Void
    let cardActions: ChatCardActions

    @AppStorage(IntelligenceAvailability.enabledKey) private var usesAppleIntelligence = true
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
                ConversationPanel(chat: chat, files: lists, maxHeight: chat.panelRoom, showInList: showInList, cardActions: cardActions)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if availability == .available {
                ChatBar(chat: chat, isFocused: isFocused, folderName: files.displayName, canTakeKeyboard: canTakeKeyboard)
            } else {
                ChatUnavailableBar(availability: availability)
            }
        }
        .clipped()
        .motion(Design.Chat.panel, value: chat.isPanelOpen)
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

/// The rounded field to ask in, with one round button that sends, and stops while a reply is
/// arriving. Until the first question, three example questions sit above it. (Not only while the
/// field has the cursor: a button that goes away when the keyboard moves to it could never be
/// pressed from the keyboard.)
struct ChatBar: View {
    @Bindable var chat: ChatModel
    var isFocused: FocusState<Bool>.Binding

    /// The folder on screen, which the questions are about.
    var folderName: String

    /// False while the window is opening, when the field must not be handed the keyboard.
    var canTakeKeyboard = true

    private static let examples = [
        String(localized: "What’s taking the most space?"),
        String(localized: "What did I download last week and never open?"),
        String(localized: "What are the biggest files on my Desktop?"),
    ]

    var body: some View {
        VStack(spacing: Design.Space.s) {
            if chat.messages.isEmpty {
                HStack(spacing: Design.Space.s) {
                    ForEach(Self.examples, id: \.self) { example in
                        Button(example) {
                            chat.ask(example)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .disabled(!chat.canAsk)
                        .help("Ask this question")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Example questions")
            }
            HStack(alignment: .bottom, spacing: Design.Chat.rowGap) {
                TextField("Ask about \(folderName)", text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused(isFocused)
                    .disabled(!canTakeKeyboard)
                    .onSubmit(chat.send)
                    .padding(.vertical, Design.Chat.fieldInset)
                    .accessibilityLabel("Question about \(folderName)")
                    .help("Ask about the files in this folder (⌘K). Answers are worked out on this Mac.")
                if !chat.messages.isEmpty, !chat.isPanelOpen {
                    Button {
                        chat.isPanelOpen = true
                    } label: {
                        Label("Show conversation", systemImage: "chevron.up")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .padding(.bottom, Design.Chat.fieldInset)
                    .help("Show the conversation")
                }
                SendButton(chat: chat)
            }
            .padding(.leading, Design.Chat.fieldLeading)
            .padding(.trailing, Design.Chat.fieldInset)
            .padding(.vertical, Design.Space.xs)
            .background(.background, in: .rect(cornerRadius: Design.Chat.fieldRadius, style: .continuous))
            .background {
                ZStack {
                    if chat.isResponding {
                        WorkingGlow()
                            .transition(.opacity)
                    }
                }
                .motion(Design.Chat.glowFade, value: chat.isResponding)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Design.Chat.fieldRadius, style: .continuous)
                    .strokeBorder(isFocused.wrappedValue ? AnyShapeStyle(.secondary) : AnyShapeStyle(.separator))
            }
            .frame(maxWidth: Design.Chat.columnWidth)
            Label("Apple Intelligence", systemImage: "sparkles")
                .font(Design.Chat.caption)
                .foregroundStyle(.secondary)
                .help("Answers are worked out on this Mac. Nothing you type or any file name leaves it.")
        }
        .font(Design.Typography.secondary)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Design.Space.l)
        .padding(.vertical, Design.Chat.barVertical)
        .onChange(of: isFocused.wrappedValue) { _, isFocused in
            if isFocused {
                chat.prewarm()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat")
    }
}

/// A soft glow around the field while the model is working, in the text's own colour: black on
/// white, white on black. It breathes slowly; with Reduce Motion it holds still.
private struct WorkingGlow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let glow = RoundedRectangle(cornerRadius: Design.Chat.fieldRadius, style: .continuous)
            .stroke(.primary, lineWidth: 3)
            .blur(radius: Design.Chat.glowBlur)
        Group {
            if reduceMotion {
                glow.opacity(0.3)
            } else {
                glow.phaseAnimator([0.15, 0.45]) { glow, opacity in
                    glow.opacity(opacity)
                } animation: { _ in
                    Design.Chat.glowPulse
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Send, which turns into Stop while a reply is arriving: black on white, or white on black in Dark
/// Mode, and grey while there is nothing to send.
private struct SendButton: View {
    let chat: ChatModel

    private var isEnabled: Bool {
        chat.isResponding || chat.canSend
    }

    private var fill: AnyShapeStyle {
        isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)
    }

    var body: some View {
        Button {
            if chat.isResponding {
                chat.stop()
            } else {
                chat.send()
            }
        } label: {
            Image(systemName: chat.isResponding ? "stop.fill" : "arrow.up")
                .font(Design.Chat.sendGlyph)
                .foregroundStyle(.background)
                .frame(width: Design.Chat.sendButton, height: Design.Chat.sendButton)
                .background(Circle().fill(fill))
                .contentTransition(.symbolEffect(.replace))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(chat.isResponding ? Text("Stop") : Text("Send"))
        .help(chat.isResponding ? Text("Stop the reply") : Text("Send the question (Return)"))
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
        StateBar(symbol: "sparkles", message: Text(availability.reason ?? "")) {
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
        .frame(maxWidth: Design.Chat.columnWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Design.Space.l)
        .padding(.vertical, Design.Chat.barVertical)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat")
    }
}
