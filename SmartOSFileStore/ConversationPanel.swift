import FileStoreCore
import FileStoreIntelligence
import SwiftUI

/// The conversation above the chat bar: each question, the reply to it, and under a reply what its
/// lookups were and what they found. Those lines and lists come from the app's own code
/// (`TurnEffects`), never from the model's sentence, and clicking a file selects it in the list.
struct ConversationPanel: View {
    let chat: ChatModel
    let files: FileListModel
    let showInList: @MainActor (URL) -> Void

    /// The newest question, which is where the panel scrolls to: the reply and what it found then
    /// read downwards from the top, however long the list under it is.
    private var newestQuestion: ChatMessage.ID? {
        chat.messages.last { $0.role == .question }?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(chat.messages) { message in
                        switch message.role {
                        case .question:
                            Text(message.text)
                                .fontWeight(.semibold)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel(Text("You asked: \(message.text)"))
                        case .reply:
                            ChatReplyView(message: message, files: files, showInList: showInList)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // When a question is asked, and again when its reply and list have arrived.
            .onChange(of: chat.isResponding, initial: true) {
                guard let newestQuestion else { return }
                // On the next turn, once the new rows are laid out.
                Task { @MainActor in
                    proxy.scrollTo(newestQuestion, anchor: .top)
                }
            }
        }
        .frame(height: 240)
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
}

/// One reply: the model's sentence, a plain line when it did not end as an answer, and what the
/// lookups found.
private struct ChatReplyView: View {
    let message: ChatMessage
    let files: FileListModel
    let showInList: @MainActor (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if message.turn == nil, message.text.isEmpty {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text("Looking…")
                        .foregroundStyle(.secondary)
                }
            }
            if !message.text.isEmpty {
                Text(message.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = message.turn?.outcome.message {
                Text(note)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let turn = message.turn, turn.outcome == .answered || turn.outcome == .stopped {
                // Every lookup gets its line, so each number in the sentence has one from the app
                // beside it. The files are listed for the last lookup, which the reply ends on.
                let results = turn.effects.results
                ForEach(Array(results.enumerated()), id: \.offset) { index, result in
                    let isLast = index == results.count - 1
                    switch result {
                    case .search(let search):
                        SearchFacts(result: search, listsFiles: isLast, files: files, showInList: showInList)
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
        }
    }
}

/// What a search was and what it found: the lookup in words, how many and how much, all worked out
/// in code, then the files.
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
            if listsFiles {
                ForEach(result.files) { file in
                    ChatFileRow(file: file, record: files.record(for: file.id), showInList: showInList)
                }
            }
        }
        .frame(maxWidth: ChatFileRow.maxWidth, alignment: .leading)
    }
}

/// The folder's totals by kind and by mark, what cleanups have moved to the Trash, and the
/// largest files.
private struct SummaryFacts: View {
    let summary: FolderSummary
    let files: FileListModel
    let showInList: @MainActor (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                .frame(maxWidth: ChatFileRow.maxWidth, alignment: .leading)
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
    let showInList: @MainActor (URL) -> Void

    /// Keeps a size beside its name in a wide window.
    static let maxWidth: CGFloat = 560

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
        .accessibilityHint(record == nil ? Text("No longer in the list") : Text("Selects the file in the list"))
    }
}
