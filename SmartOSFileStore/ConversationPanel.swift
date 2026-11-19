import FileStoreCore
import FileStoreIntelligence
import SwiftUI

/// Sizes the chat shares: one centred column, as wide as reads well.
enum ChatLayout {
    static let columnWidth: CGFloat = 720
    static let bubbleWidth: CGFloat = 520
}

/// The conversation above the chat bar: each question in a bubble on the right, the reply under it
/// on the left, and under a reply a card with what its lookups were and what they found. The card
/// comes from the app's own code (`TurnEffects`), never from the model's sentence, and clicking a
/// file selects it in the list. The panel's height is the user's, kept between launches.
struct ConversationPanel: View {
    let chat: ChatModel
    let files: FileListModel
    /// The most the window has room for. A smaller window draws the panel shorter without
    /// changing the height kept for it.
    let maxHeight: CGFloat
    let showInList: @MainActor (URL) -> Void

    static let minHeight: CGFloat = 160
    @AppStorage("ChatPanelHeight") private var storedHeight = 280.0
    @State private var position = ScrollPosition(idType: ChatMessage.ID.self, edge: .bottom)
    /// True while the view keeps the newest text in sight. Scrolling up stops it; scrolling back to
    /// the bottom, or asking, starts it again.
    @State private var isFollowing = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var heights: ClosedRange<CGFloat> {
        Self.minHeight...max(Self.minHeight, maxHeight)
    }

    /// The kept height as drawn: inside `heights`, or the least of them when what was kept is not
    /// a number (clamping passes NaN through, and the handle's VoiceOver value would trap on it).
    static func height(_ stored: Double, in heights: ClosedRange<CGFloat>) -> CGFloat {
        stored.isFinite ? CGFloat(stored).clamped(to: heights) : heights.lowerBound
    }

    /// The newest question, which a finished reply scrolls to: the reply and its card then read
    /// downwards from the top, however long the list in the card is.
    private var newestQuestion: ChatMessage.ID? {
        chat.messages.last { $0.role == .question }?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelResizeHandle(height: $storedHeight, heights: heights)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(chat.messages) { message in
                        switch message.role {
                        case .question:
                            QuestionBubble(text: message.text)
                        case .reply:
                            ChatReplyView(message: message, files: files, showInList: showInList)
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .frame(maxWidth: ChatLayout.columnWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollPosition($position)
            .onScrollPhaseChange { old, new, context in
                // Only the user's own scrolling decides: text that grows moves the content, not the phase.
                guard new == .idle, old == .interacting || old == .decelerating else { return }
                let geometry = context.geometry
                isFollowing = geometry.visibleRect.maxY >= geometry.contentSize.height - 24
            }
            .onChange(of: chat.messages.count) {
                // A question was asked: show it, and the reply as it comes.
                isFollowing = true
                Task { @MainActor in
                    scroll { position.scrollTo(edge: .bottom) }
                }
            }
            .onChange(of: chat.messages.last?.text) {
                guard isFollowing else { return }
                position.scrollTo(edge: .bottom)
            }
            .onChange(of: chat.isResponding) { _, isResponding in
                guard !isResponding, isFollowing, let newestQuestion else { return }
                // On the next turn, once the card is laid out.
                Task { @MainActor in
                    scroll { position.scrollTo(id: newestQuestion, anchor: .top) }
                }
            }
        }
        .frame(height: Self.height(storedHeight, in: heights))
        .font(.callout)
        .overlay(alignment: .topTrailing) {
            Button {
                chat.isPanelOpen = false
            } label: {
                Label("Hide Conversation", systemImage: "chevron.down")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Hide the conversation (Esc)")
            .padding(8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation")
    }

    private func scroll(_ change: () -> Void) {
        if reduceMotion {
            change()
        } else {
            withAnimation(.smooth(duration: 0.3), change)
        }
    }
}

/// The top edge of the conversation, dragged to make it taller or shorter. Up and down arrows do
/// the same from the keyboard, and VoiceOver adjusts it.
private struct PanelResizeHandle: View {
    @Binding var height: Double
    let heights: ClosedRange<CGFloat>

    /// The height when the drag began. A drag is measured in the window, as the handle moves with it.
    @State private var dragStart: CGFloat?
    private static let step: CGFloat = 24

    private var current: CGFloat {
        ConversationPanel.height(height, in: heights)
    }

    private func set(_ value: CGFloat) {
        guard value.isFinite else { return }
        height = Double(value.clamped(to: heights))
    }

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity, minHeight: 12)
            .contentShape(.rect)
            .pointerStyle(.frameResize(position: .top, directions: [.inward, .outward]))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = dragStart ?? current
                        dragStart = start
                        set(start - drag.translation.height)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .focusable()
            .onKeyPress(.upArrow) {
                set(current + Self.step)
                return .handled
            }
            .onKeyPress(.downArrow) {
                set(current - Self.step)
                return .handled
            }
            .help("Drag to make the conversation taller or shorter")
            .accessibilityElement()
            .accessibilityLabel("Conversation height")
            .accessibilityValue(Text("\(Int(current)) points"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: set(current + Self.step)
                case .decrement: set(current - Self.step)
                @unknown default: break
                }
            }
    }
}

/// What the user asked, in a bubble on the right.
private struct QuestionBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary, in: .rect(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: ChatLayout.bubbleWidth, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("You asked: \(text)"))
    }
}

/// One reply on the left: the thinking animation until its first words, the model's sentence, a
/// plain line when it did not end as an answer, and the card of what the lookups found.
private struct ChatReplyView: View {
    let message: ChatMessage
    let files: FileListModel
    let showInList: @MainActor (URL) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isThinking: Bool {
        message.turn == nil && message.text.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if isThinking {
                    ThinkingIndicator()
                } else if !message.text.isEmpty {
                    Text(message.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .transition(.opacity)
            // Only beside an answer: an outcome's own line already says the conversation started again.
            if let turn = message.turn, turn.startedOver, turn.outcome.message == nil || turn.outcome == .stopped {
                Text("This was asked again in a fresh conversation, so earlier messages were set aside.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = message.turn?.outcome.message {
                Text(note)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let turn = message.turn, turn.outcome == .answered || turn.outcome == .stopped {
                let results = turn.effects.shownResults
                if !results.isEmpty {
                    LookupCard(results: results, files: files, showInList: showInList)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isThinking)
    }
}

extension TurnEffects {
    /// The results the card shows. (The engine already keeps one search per set of files.) A search
    /// for everything says what a summary's first row says, so beside a summary it is left out,
    /// unless its files are the ones the card lists.
    var shownResults: [Result] {
        let hasSummary = results.contains { if case .summary = $0 { true } else { false } }
        return results.enumerated().compactMap { index, result in
            if hasSummary, index != results.count - 1, case .search(let search) = result, search.query == FileQuery() {
                return nil
            }
            return result
        }
    }
}

/// Every lookup of a reply, in one card. Each says what was looked up and what it came to, worked
/// out in code; the files are listed for the last, which the reply ends on.
private struct LookupCard: View {
    let results: [TurnEffects.Result]
    let files: FileListModel
    let showInList: @MainActor (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(results.enumerated()), id: \.offset) { index, result in
                let isLast = index == results.count - 1
                if index > 0 {
                    Divider()
                }
                switch result {
                case .search(let search):
                    SearchFacts(result: search, listsFiles: isLast, files: files, showInList: showInList)
                case .duplicates(let scan):
                    DuplicateFacts(scan: scan, listsFiles: isLast, files: files, showInList: showInList)
                case .summary(let summary):
                    if isLast {
                        SummaryFacts(summary: summary, files: files, showInList: showInList)
                    } else {
                        Text("All items: ^[\(summary.all.count) item](inflect: true), \(summary.all.bytes.formattedFileSize)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: ChatFileRow.maxWidth, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
    }
}

/// What a search was and what it found: the lookup in words, how many and how much, then the files.
private struct SearchFacts: View {
    let result: FileSearchResult
    /// False for a lookup that was not the turn's last: its line is shown without its files.
    let listsFiles: Bool
    let files: FileListModel
    let showInList: @MainActor (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // The words may include text the model chose (a name to search for), so they go in
            // verbatim: nothing in them is read as Markdown or as a link.
            let lookedUp = Text(verbatim: result.lookedUp)
            Group {
                if result.matchCount == 0 {
                    Text("\(lookedUp): no files")
                } else if listsFiles, result.matchCount > result.files.count {
                    Text("\(lookedUp): ^[\(result.matchCount) file](inflect: true), \(result.totalBytes.formattedFileSize) · showing the first \(result.files.count)")
                } else {
                    Text("\(lookedUp): ^[\(result.matchCount) file](inflect: true), \(result.totalBytes.formattedFileSize)")
                }
            }
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(2)
            if result.query.neverOpened {
                // The model's sentence tends to say "never opened"; this says what the app can know.
                Text("macOS records an open from Finder, the Dock or an Open dialog, not from Quick Look or a drag into an app.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if result.unknownOpenCount > 0 {
                Text("Last opened unknown for ^[\(result.unknownOpenCount) more item](inflect: true), not counted")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("macOS keeps no last-opened date for folders, apps and links")
            }
            if listsFiles {
                ForEach(result.files) { file in
                    ChatFileRow(file: file, record: files.record(for: file.id), showInList: showInList)
                }
            }
        }
    }
}

/// What Find Duplicates found by reading the files: how many copies, then each file that would be
/// kept with its copies under it.
private struct DuplicateFacts: View {
    let scan: DuplicateScan
    let listsFiles: Bool
    let files: FileListModel
    let showInList: @MainActor (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Group {
                if scan.copyCount == 0 {
                    Text("Same content: no copies")
                } else {
                    Text("Same content: ^[\(scan.copyCount) copy](inflect: true) of ^[\(scan.groups.count) file](inflect: true), taking \(scan.copyBytes.formattedFileSize)")
                }
                if scan.recentCount > 0 {
                    Text("^[\(scan.recentCount) file](inflect: true) added in the last hour not checked yet")
                }
                if scan.unreadableCount > 0 {
                    Text("^[\(scan.unreadableCount) file](inflect: true) could not be read, so they are not counted")
                }
            }
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if listsFiles {
                ForEach(scan.groups, id: \.kept.id) { group in
                    ChatFileRow(file: group.kept, record: files.record(for: group.kept.id), showInList: showInList)
                    ForEach(group.copies) { copy in
                        ChatFileRow(file: copy, record: files.record(for: copy.id), copyOf: group.kept.name, showInList: showInList)
                            .padding(.leading, 22)
                    }
                }
            }
        }
    }
}

/// The folder's totals by kind and by mark, what cleanups have moved to the Trash, and the
/// largest files.
private struct SummaryFacts: View {
    let summary: FolderSummary
    let files: FileListModel
    let showInList: @MainActor (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                row(Text("All items"), summary.all)
                ForEach(FileTypeGroup.allCases, id: \.self) { group in
                    if let total = summary.byTypeGroup[group] {
                        row(Text(group.title), total)
                    }
                }
                if !summary.byMark.isEmpty {
                    Divider()
                    ForEach(FolderSnapshot.Mark.allCases, id: \.self) { mark in
                        if let total = summary.byMark[mark] {
                            row(Text(mark.fileMark.title), total)
                        }
                    }
                }
            }
            // As wide as its numbers, not as the window.
            .fixedSize()
            .foregroundStyle(.secondary)
            if let moved = summary.bytesMovedToTrash, moved > 0 {
                Text("\(moved.formattedFileSize) moved to the Trash in total")
                    .foregroundStyle(.secondary)
            }
            if !summary.largest.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Largest files")
                        .foregroundStyle(.secondary)
                    ForEach(summary.largest) { file in
                        ChatFileRow(file: file, record: files.record(for: file.id), showInList: showInList)
                    }
                }
            }
        }
    }

    private func row(_ title: Text, _ total: FolderSummary.Total) -> some View {
        GridRow {
            title
            Text("^[\(total.count) item](inflect: true)")
                .monospacedDigit()
                .gridColumnAlignment(.trailing)
            Text(total.bytes.formattedFileSize)
                .monospacedDigit()
                .gridColumnAlignment(.trailing)
        }
        // One element for VoiceOver: "Documents, 6 items, 230 MB".
        .accessibilityElement(children: .combine)
    }
}

/// A file a lookup found. Clicking it selects the file in the list; a file no longer listed is
/// shown dimmed and does nothing.
private struct ChatFileRow: View {
    let file: FolderSnapshot.File
    let record: FileRecord?
    /// The name of the file this one is a copy of, for VoiceOver.
    var copyOf: String?
    let showInList: @MainActor (URL) -> Void

    /// Keeps a size beside its name in a wide window.
    static let maxWidth: CGFloat = 560

    private var hint: Text {
        if record == nil { return Text("No longer in the list") }
        if let copyOf { return Text("A copy of \(copyOf). Selects the file in the list") }
        return Text("Selects the file in the list")
    }

    var body: some View {
        Button {
            showInList(file.id)
        } label: {
            HStack(spacing: 6) {
                if let record {
                    FileIconView(record: record)
                } else {
                    Image(systemName: "doc")
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                }
                Text(file.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                if let size = file.sizeInBytes {
                    Text(size.formattedFileSize)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(record == nil)
        .help(record == nil ? Text("This file is no longer in the list") : Text("Select this file in the list"))
        // One element for VoiceOver: "report.pdf, 2.5 MB", pressed to select it.
        .accessibilityElement(children: .combine)
        .accessibilityHint(hint)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
