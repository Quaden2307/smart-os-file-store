import FileStoreCore
import FileStoreIntelligence
import SwiftUI

/// The main window: a sidebar of places (Downloads, Activity) and the chosen place beside it, with
/// the toolbar, the status line and, along the bottom, the chat bar. Downloads is the file table,
/// or the loading, empty and error states in its place; Activity is every confirmed cleanup.
struct ContentView: View {
    @Environment(ActivityLogModel.self) private var activity
    /// One file list per managed folder.
    @State private var lists = FolderListsModel()
    @State private var search = CleanupSearchModel()

    // Watched only, so marks follow a threshold changed in Settings at once; the list reads them itself.
    @AppStorage(CleanupSettings.unusedAfterDaysKey) private var unusedAfterDays = CleanupSettings.defaultUnusedAfterDays
    @AppStorage(CleanupSettings.oldAfterDaysKey) private var oldAfterDays = CleanupSettings.defaultOldAfterDays
    /// Each folder's selected rows, kept while another place is shown.
    @State private var selections: [FolderPlace: Set<FileRecord.ID>] = [:]
    @State private var section: SidebarSection = .downloads

    /// The folder shown last: Activity keeps it as the folder a cleanup acts on and the status line
    /// and the chat describe.
    @State private var lastFolderPlace: FolderPlace = .standard(.downloads)

    /// The custom folder being renamed, if any.
    @State private var renaming: RenamingFolder?

    /// Why the folder the user chose was not added, while that is shown.
    @State private var addFolderRefusal: String?

    /// True while the folder picker is up.
    @State private var isChoosingFolder = false
    @State private var activityList = ActivityListModel()

    /// The Storage place's numbers.
    @State private var storage = StorageModel()
    @State private var activitySelection: Set<ActivityRowID> = []
    @State private var undo = UndoModel()

    /// The Tidy Now on screen, if any.
    @State private var tidyNow: PresentedTidyNow?

    /// A run the cleanup summary asked to undo, started once its sheet has gone.
    @State private var runToUndoAfterSheet: ActivityRun.ID?

    /// True while Stop Keeping All asks for confirmation.
    @State private var isConfirmingStopKeepingAll = false

    /// True while the welcome is up, the first time the window opens. The folder is read once it
    /// closes.
    @State private var isShowingWelcome = FirstRun.needsWelcome(in: UserDefaults.standard)

    /// The folders the welcome's switches asked to turn on as it closes.
    @State private var welcomeTurnsOn: Set<ManagedFolder.Kind> = []

    /// Which place's list has keyboard focus, when the View menu moves it there.
    @FocusState private var focusedPlace: SidebarSection?

    /// The place whose list takes focus once it is shown, after a switch from the View menu.
    @State private var placeToFocus: SidebarSection?

    /// The chat bar's conversation. It reads the list and holds the plans of its cleanup cards;
    /// a plan is carried out only from here, by the user's Confirm.
    @State private var chat = ChatModel()

    /// The cleanup card whose Confirm is asking its one question, if any.
    @State private var confirmingCard: ConfirmingCard?

    /// True while the cursor is in the chat bar's field.
    @FocusState private var isChatFocused: Bool

    /// The file a chat row asked the list to show.
    @State private var fileToReveal: FileTableView.Reveal?

    /// The folder a cleanup, the status line and the chat are about.
    private var currentPlace: FolderPlace { section.folderPlace ?? lastFolderPlace }

    /// The list of the folder on screen, or of the last folder shown. Downloads when that folder is
    /// off or cannot be found.
    private var model: FileListModel { lists.list(at: currentPlace) ?? lists.downloads }

    /// True when the folder place on screen has a list to show.
    private var showsList: Bool {
        guard let place = section.folderPlace else { return false }
        return lists.list(at: place) != nil
    }

    private var selection: Set<FileRecord.ID> {
        get { selections[model.place] ?? [] }
        nonmutating set { selections[model.place] = newValue }
    }

    private var selectionBinding: Binding<Set<FileRecord.ID>> {
        let place = model.place
        return Binding(get: { selections[place] ?? [] }, set: { selections[place] = $0 })
    }

    var body: some View {
        observingSettings(observingFolders(observingChanges(publishingCommandTargets(splitView))))
            // Every number in the window and its sheets, so counts, sizes and dates line up.
            .monospacedDigit()
    }

    private var splitView: some View {
        NavigationSplitView {
            Sidebar(
                selection: $section,
                folders: sidebarFolders,
                // A closed log has no count: the list keeps its last runs until a log opens again.
                cleanupCount: activity.log == nil ? 0 : activityList.runs.count { !$0.isUndo },
                canChangeFolders: canChangeFolders,
                actions: SidebarFolderActions(
                    turnOn: turnOn, add: { isChoosingFolder = true }, addDropped: addFolders, startRenaming: startRenaming, remove: removeFolder
                )
            )
            .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 280)
        } detail: {
            detail
        }
        .sheet(item: presentedPlan, onDismiss: undoRunAfterSheet) { presented in
            PresentedPlanSheet(
                plan: presented.plan,
                eligibility: model.eligibility,
                applicationFolders: model.applicationFolders,
                activity: activity,
                markKept: { records, onFinish in
                    model.keep(records, onFinish: onFinish)
                },
                onExecuted: {
                    // Files moved, so the rows on screen are stale.
                    model.refresh()
                },
                onUndo: { runID in
                    runToUndoAfterSheet = runID
                }
            )
            // A later plan must start with its own ticks and its own log, never an earlier sheet's.
            .id(presented.id)
        }
        .sheet(item: $tidyNow, onDismiss: undoRunAfterSheet) { presented in
            TidyNowSheet(
                model: presented.model,
                eligibility: model.eligibility,
                applicationFolders: model.applicationFolders,
                log: presented.log,
                activity: activity,
                markKept: { records, onFinish in
                    model.keep(records, onFinish: onFinish)
                },
                onUndo: { runID in
                    runToUndoAfterSheet = runID
                }
            )
            .id(presented.id)
        }
        .sheet(isPresented: $isConfirmingStopKeepingAll) {
            StopKeepingAllSheet(itemCount: model.keptItems.count) {
                model.stopKeepingAll()
            }
        }
        .sheet(item: $confirmingCard) { card in
            TidyNowConfirmationSheet(totals: card.model.totals) {
                carryOut(card)
            }
        }
        .sheet(isPresented: $isShowingWelcome, onDismiss: startAfterWelcome) {
            WelcomeSheet(turnOn: $welcomeTurnsOn)
        }
        .sheet(item: $renaming) { folder in
            RenameFolderSheet(name: folder.name) { name in
                Task { await activity.setDisplayName(of: folder.id, to: name) }
            }
        }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                addFolders([url])
            }
        }
        .alert(
            "Folder can’t be added",
            isPresented: Binding(get: { addFolderRefusal != nil }, set: { if !$0 { addFolderRefusal = nil } }),
            presenting: addFolderRefusal
        ) { _ in
            Button("OK") {}
        } message: { sentence in
            Text(sentence)
        }
    }

    /// What the menu bar's commands act on. While a preview sheet is up, they must not act on the
    /// window behind it; otherwise each acts on the place on screen.
    private func publishingCommandTargets(_ view: some View) -> some View {
        publishingCleanupTargets(publishingFileTargets(view))
    }

    /// The commands that act on files or places: one helper apart from the cleanup ones, so each
    /// chain stays small enough for the type checker.
    private func publishingFileTargets(_ view: some View) -> some View {
        view
            .focusedSceneValue(\.selectedFileURLs, actsOnWindow ? selectedURLs : nil)
            .focusedSceneValue(
                \.selectedDownloadAddresses,
                actsOnWindow && showsList ? model.downloadAddresses(for: selection) : nil
            )
            .focusedSceneValue(\.fileListFilter, filterTarget)
            .focusedSceneValue(\.placeSwitcher, placeSwitcher)
            // Not while typing in the chat bar: there Command-Z must never start undoing a cleanup.
            .focusedSceneValue(\.undoCommands, actsOnWindow && !isChatFocused ? undoCommands : nil)
            .focusedSceneValue(\.keepCommands, actsOnWindow && showsList ? keepCommands : nil)
    }

    private var filterTarget: Binding<FileListFilter>? {
        guard actsOnWindow, showsList else { return nil }
        let model = model
        return Binding(get: { model.filter }, set: { model.filter = $0 })
    }

    private var placeSwitcher: PlaceSwitcher? {
        guard actsOnWindow else { return nil }
        let choosing = $isChoosingFolder
        let addFolder: (@MainActor @Sendable () -> Void)? = canChangeFolders ? { @MainActor @Sendable in choosing.wrappedValue = true } : nil
        return PlaceSwitcher(show: show, addFolder: addFolder)
    }

    private func publishingCleanupTargets(_ view: some View) -> some View {
        view
            // From either place, as the toolbar's menu: a cleanup always acts on the listed files.
            .focusedSceneValue(\.cleanUpCommands, actsOnWindow ? cleanUpCommands : nil)
            .focusedSceneValue(\.chatCommands, actsOnWindow ? ChatCommandTarget(focus: focusChat) : nil)
    }

    /// The welcome closed, by its button or by Escape: it is never shown again, and the folder is read.
    private func startAfterWelcome() {
        FirstRun.markWelcomeShown(in: UserDefaults.standard)
        lists.downloads.refresh()
        lists.sync(readingNew: false)
        for list in lists.all where list.place != .standard(.downloads) {
            list.refresh()
        }
        // Turning a folder on is what makes macOS ask about it, so it waits for the welcome.
        for kind in welcomeTurnsOn.sorted(by: { $0 == .desktop && $1 == .documents }) {
            turnOn(kind)
        }
        welcomeTurnsOn = []
    }

    private func observingChanges(_ view: some View) -> some View {
        view
            .onAppear {
                if let start = DebugSnapshot.startPlace() {
                    section = start
                }
                lists.connect(to: activity)
                chat.connect(files: model, lists: lists, activity: activity, hashCache: search.hashCache)
                activity.open()
                // The first time, the welcome comes before the folder is read, and so before the
                // Mac asks about Downloads.
                if !isShowingWelcome {
                    lists.downloads.refresh()
                }
                // Makes the folder disk images are read in, and detaches what a crashed run left
                // mounted there. Once per launch; a search waits for it.
                Task { await DiskImageMounts.shared.prepare() }
            }
            .onChange(of: model.isLoading) { _, isLoading in
                // A refresh replaces the rows a running search was given, so its plan would describe
                // files the table no longer shows. Stop it; the user can run it again on the new list.
                if isLoading, search.isRunning {
                    search.cancel()
                }
                // The list was read again: a waiting cleanup card whose files changed is out of date.
                if !isLoading {
                    chat.checkCards()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                // Back from another app, where a file of a waiting cleanup card may have been
                // changed: the folder is read again, and the card is checked against it. Not for
                // a sheet or the Settings window closing, which change no file.
                if chat.hasWaitingCard, canStartCleanup {
                    model.refresh()
                }
                for list in lists.all where list.failure?.isPermissionDenied == true && list.canRefresh && list !== model {
                    // Back from the privacy settings, where access may have been turned on.
                    list.refresh()
                }
                if model.failure?.isPermissionDenied == true, model.canRefresh, !chat.hasWaitingCard {
                    model.refresh()
                }
                // A folder that was away may be back, or one that was there may be gone.
                activity.reloadFolders()
            }
    }

    /// The folder list's changes: a disk connected or gone, a folder added, taken off or renamed.
    private func observingFolders(_ view: some View) -> some View {
        view
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
                activity.reloadFolders()
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
                activity.reloadFolders()
            }
            .onChange(of: activity.folderRevision) {
                // Behind the welcome nothing is read; it reads every folder as it closes.
                lists.sync(readingNew: !isShowingWelcome)
                // A folder taken off the list leaves its place; Downloads is always there.
                if case .folder(.custom(let id)) = section, activity.entry(at: .custom(id)) == nil {
                    section = .downloads
                }
                if case .custom(let id) = lastFolderPlace, activity.entry(at: .custom(id)) == nil {
                    lastFolderPlace = .standard(.downloads)
                }
                chat.show(files: model)
            }
    }

    private func observingSettings(_ view: some View) -> some View {
        view
            .onChange(of: lists.all.map(\.scanGeneration)) {
                // A folder was read again: what it holds and could get back may have changed.
                if section == .storage {
                    refreshStorage()
                }
            }
            .onChange(of: model.scanGeneration) {
                // The listing was replaced: drop selected rows that are gone, so menu commands never
                // act on files that are no longer listed, and forget per-file icons.
                keepSelectionVisible()
                FileIconCache.shared.removeAll()
            }
            .onChange(of: model.filter) {
                // Rows the filter hides must not stay selected, or menu commands would act on them.
                keepSelectionVisible()
            }
            .onChange(of: unusedAfterDays) {
                lists.all.forEach { $0.applySettings() }
            }
            .onChange(of: oldAfterDays) {
                lists.all.forEach { $0.applySettings() }
            }
            .onChange(of: model.marksRevision) {
                // Marks changed with the Kept list, so the Kept filter may hide selected rows now,
                // and a waiting cleanup card that names a file now Kept is out of date.
                keepSelectionVisible()
                chat.checkCards()
            }
            .onChange(of: activity.openings) {
                // Another log: its runs and items are not the ones that were selected, and its Kept
                // list is the one that counts.
                activitySelection = []
                // Behind the welcome nothing looks into the folder; the first scan reloads both.
                guard !isShowingWelcome else { return }
                for list in lists.all {
                    list.reloadKeptItems()
                    // Its installer facts are the ones the Installed marks come from.
                    list.reloadInstalledMarks()
                }
            }
            .onChange(of: section) { _, section in
                if let place = section.folderPlace {
                    lastFolderPlace = place
                }
                if section == .storage {
                    refreshStorage()
                }
                // The chat answers about the folder on screen.
                chat.show(files: model)
                guard placeToFocus == section else { return }
                placeToFocus = nil
                // On the next turn, once the place is usable again.
                Task { @MainActor in
                    focusedPlace = section
                }
            }
    }

    /// The chosen place, with what every place shares below it: a cleanup search's progress,
    /// the activity log's notices and the status line.
    private var detail: some View {
        VStack(spacing: 0) {
            // Both places stay alive, so each keeps its scroll position, column widths, selection
            // and open cleanups while the other is shown.
            ZStack {
                content
                    .placeShown(section.folderPlace != nil)
                ActivityView(
                    activity: activity,
                    model: activityList,
                    selection: $activitySelection,
                    isShown: section == .activity,
                    focus: $focusedPlace,
                    canUndo: canStartUndo,
                    undo: startUndo,
                    tidyNow: canStartTidyNow ? startTidyNow : nil
                )
                .placeShown(section == .activity)
                StorageView(model: storage, review: reviewFromStorage, showInList: showInList)
                    .placeShown(section == .storage)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(item: presentedUndo) { presented in
                UndoSheet(model: undo)
                    .id(presented.id)
            }
            if let running = search.running {
                Divider()
                CleanupProgressView(action: running.action, progress: running.progress, cancel: search.cancel)
            }
            ActivityLogNotices(activity: activity)
            Divider()
            StatusBar(model: model, activity: activity, showsFileCounts: showsList)
            Divider()
            ChatSection(chat: chat, files: model, lists: lists, isFocused: $isChatFocused, showInList: showInList, cardActions: cardActions)
        }
        // Narrower than the six columns at their ideal widths: the table then scrolls sideways, as
        // Finder's does, the filter becomes a menu and the toolbar puts what does not fit in its
        // overflow menu.
        .frame(minWidth: 720, minHeight: 480)
        // The conversation leaves room for a few rows of the list, the status line and the bar.
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { chat.panelRoom = $0 - 260 }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // The first step of a cleanup: every action at once. Its shortcut is in the Clean Up menu.
                Button {
                    startTidyNow()
                } label: {
                    Label("Tidy now", systemImage: "checklist")
                }
                // The window's one primary action: filled with the accent, its title showing.
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderedProminent)
                .help(
                    activity.failure == nil
                        ? Text("Check the folder with every cleanup at once (⌘T)")
                        : Text("Nothing can be cleaned up until the activity log works")
                )
                .disabled(!canStartTidyNow)
            }
            ToolbarItem(placement: .primaryAction) {
                // Every action, as in the menu bar's Clean Up menu, which holds their shortcuts.
                Menu {
                    ForEach(offeredActions, id: \.self) { action in
                        let display = action.display
                        Button {
                            startCleanup(action)
                        } label: {
                            Label(display.commandTitle, systemImage: display.symbol)
                        }
                        .help(display.explanation)
                        .accessibilityHint(display.explanation)
                    }
                } label: {
                    Label("Clean up", systemImage: "ellipsis.circle")
                }
                .help(
                    activity.failure == nil
                        ? Text("Clean up this folder")
                        : Text("Nothing can be cleaned up until the activity log works")
                )
                .disabled(!canStartCleanup)
            }
            ToolbarItem(placement: .primaryAction) {
                // Refreshes the place on screen.
                Button {
                    refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help(section.folderPlace != nil ? Text("Refresh the list (⌘R)") : Text("Read the activity log again (⌘R)"))
                .disabled(isShowingWelcome || (section.folderPlace != nil ? !(showsList && model.canRefresh) : activity.log == nil))
            }
        }
    }

    /// True while menu commands may act on the window: no preview, undo or confirmation sheet is up
    /// in front of it.
    private var actsOnWindow: Bool {
        search.presentedPlan == nil && tidyNow == nil && undo.presented == nil && !isConfirmingStopKeepingAll
            && confirmingCard == nil && !isShowingWelcome
    }

    // MARK: - Kept

    /// True while the Kept list may be changed from the window: the log works, and no duplicate
    /// search is running (it read the list when it started, so a file Kept now could still appear in
    /// its preview) and no earlier change is still being written.
    private var canChangeKept: Bool {
        model.canChangeKept && !search.isRunning && !model.isChangingKept
    }

    /// File > Keep This File or Stop Keeping for the selection, and Stop Keeping All.
    private var keepCommands: KeepCommandTarget {
        let toggle = model.keepToggle(for: selection)
        return KeepCommandTarget(
            toggle: toggle,
            canToggle: canChangeKept && toggle != nil,
            toggleSelection: {
                model.toggleKept(selection)
            },
            canStopKeepingAll: canChangeKept && !model.keptItems.isEmpty,
            stopKeepingAll: {
                isConfirmingStopKeepingAll = true
            }
        )
    }

    // MARK: - Undo

    /// True while an undo may start: the log works, the folder is known, and nothing else that
    /// reads or moves files is under way or on screen.
    private var canStartUndo: Bool {
        activity.log != nil && model.folder != nil && !search.isRunning && search.presentedPlan == nil && tidyNow == nil
            && !undo.isBusy && confirmingCard == nil && !chat.isCleaningUp
    }

    private func startUndo(_ target: UndoTarget) {
        guard canStartUndo, let log = activity.log else { return }
        undo.start(target, log: log, activity: activity) {
            // Files moved back, into whichever folder their run was made in.
            lists.all.forEach { $0.refresh() }
        }
    }

    /// The cleanup summary's Undo, once its sheet has gone, so one sheet never covers another.
    private func undoRunAfterSheet() {
        guard let runID = runToUndoAfterSheet else { return }
        runToUndoAfterSheet = nil
        startUndo(.run(runID))
    }

    /// Edit > Undo: the newest cleanup run, while it has something left to undo. Edit > Undo
    /// Selected: the run or item selected in Activity.
    private var undoCommands: UndoCommandTarget {
        let latest = activity.latestCleanupRun.flatMap { $0.hasChangesLeftToUndo ? $0 : nil }
        let selectionTarget = section == .activity ? activityList.undoTarget(for: activitySelection) : nil
        return UndoCommandTarget(
            title: latest.map { UndoPlan.title(undoingCode: $0.actionCode) } ?? String(localized: "Undo"),
            canUndo: canStartUndo && latest != nil,
            undo: {
                if let latest {
                    startUndo(.run(latest.id))
                }
            },
            canUndoSelection: canStartUndo && selectionTarget != nil,
            undoSelection: {
                if let selectionTarget {
                    startUndo(selectionTarget)
                }
            }
        )
    }

    /// `.sheet(item:)` reports that the sheet was closed by setting this to nil.
    private var presentedUndo: Binding<UndoModel.Presented?> {
        Binding(
            get: { undo.presented },
            set: { presented in
                if presented == nil {
                    undo.dismiss()
                }
            }
        )
    }

    /// Shows `place` from the View menu and gives its list keyboard focus, so the arrow keys work at
    /// once. The sidebar changes `section` itself and keeps focus.
    private func show(_ place: SidebarSection) {
        if section == place {
            focusedPlace = place
        } else {
            placeToFocus = place
            section = place
        }
    }

    private func refresh() {
        switch section {
        case .folder:
            if showsList {
                model.refresh()
            }
            activity.reloadFolders()
        case .activity:
            activityList.reload(activity: activity)
        case .storage:
            lists.all.forEach { $0.refresh() }
        }
    }

    /// What File > Reveal in Finder acts on: the selected files, or the selected cleanup items whose
    /// files are still where the log says.
    private var selectedURLs: [URL] {
        switch section {
        case .folder:
            showsList ? Array(selection) : []
        case .activity:
            activityList.revealableURLs(for: activitySelection)
        case .storage:
            []
        }
    }

    /// A cleanup looks at every listed file, whatever the filter shows (the preview names each file
    /// it proposes), so the list must be settled first, and a new search must never replace a
    /// preview the user is still looking at. Without a working activity log that knows Downloads
    /// nothing may be cleaned up, so nothing is searched for either.
    private var canStartCleanup: Bool {
        model.isSettled && !search.isRunning && search.presentedPlan == nil && tidyNow == nil && model.logFolder != nil
            && !undo.isBusy && !model.isChangingKept && !isConfirmingStopKeepingAll
            && confirmingCard == nil && !chat.isCleaningUp
    }

    /// The Clean Up menu: every action, under the same rule as the toolbar's menu.
    private var cleanUpCommands: CleanUpCommandTarget {
        CleanUpCommandTarget(
            canStart: canStartCleanup, offered: Set(offeredActions), canTidyNow: canStartTidyNow, start: startCleanup,
            startTidyNow: startTidyNow
        )
    }

    /// The actions the folder on screen offers, in menu order.
    private var offeredActions: [CleanupAction] {
        let rules = model.logFolder?.rules ?? FolderRules.defaults(for: model.folder?.kind ?? .downloads)
        return CleanupAction.menuActions.filter(rules.offers)
    }

    /// Tidy Now, where the folder's rules put any action in it.
    private var canStartTidyNow: Bool {
        canStartCleanup && model.logFolder?.rules.tidyNowActions.isEmpty == false
    }

    /// `.sheet(item:)` keeps showing the plan while the sheet animates away; setting it to nil
    /// is how the sheet reports that it was dismissed.
    private var presentedPlan: Binding<CleanupSearchModel.PresentedPlan?> {
        Binding(
            get: { search.presentedPlan },
            set: { presented in
                if presented == nil {
                    search.dismissPlan()
                }
            }
        )
    }

    private func keepSelectionVisible() {
        selection = selection.intersection(Set(model.visibleRecords.map(\.id)))
    }

    // MARK: - Chat

    /// View > Ask About Downloads: the cursor goes to the chat bar, and the conversation so far shows.
    private func focusChat() {
        isChatFocused = true
        chat.isPanelOpen = true
    }

    /// A file clicked in the conversation: Downloads is shown with that file selected. A filter that
    /// hides it is cleared first, since a hidden row must never be the selection.
    private func showInList(_ id: FileRecord.ID) {
        // A row of an answer about several folders: its own folder is shown.
        if model.record(for: id) == nil, let list = lists.all.first(where: { $0.record(for: id) != nil }) {
            section = .folder(list.place)
        }
        let model = lists.all.first { $0.record(for: id) != nil } ?? model
        guard model.record(for: id) != nil else { return }
        if !model.visibleRecords.contains(where: { $0.id == id }) {
            model.filter = .all
        }
        selection = [id]
        fileToReveal = FileTableView.Reveal(id: id)
        show(.folder(model.place))
    }

    // MARK: - Cleanup cards in the chat

    private var cardActions: ChatCardActions {
        // Not while a reply arrives: it could put a newer card in this one's place.
        ChatCardActions(canStart: canStartCleanup && chat.canAsk, review: reviewCard, confirm: confirmCard, undo: { startUndo(.run($0)) })
    }

    /// Review on a card: the Tidy Now preview, on the card's plan and with its ticks.
    private func reviewCard(_ id: CleanupProposal.ID) {
        guard canStartCleanup, let log = activity.log, let card = chat.confirmable(id) else { return }
        tidyNow = PresentedTidyNow(model: card, log: log)
    }

    /// Confirm on a card: the one question Tidy Now asks, for what the card has ticked.
    private func confirmCard(_ id: CleanupProposal.ID) {
        guard canStartCleanup, let card = chat.confirmable(id), card.canTidyUp else { return }
        confirmingCard = ConfirmingCard(id: id, model: card)
    }

    /// The answer to that question was yes. The card must still be the one that may be confirmed;
    /// the executor then checks every file again, as for any run.
    private func carryOut(_ card: ConfirmingCard) {
        guard chat.confirmable(card.id) === card.model else { return }
        card.model.execute()
    }

    private func startCleanup(_ action: CleanupAction) {
        guard canStartCleanup, let log = activity.log, let folder = model.logFolder else { return }
        search.start(
            action,
            records: model.records,
            folder: folder,
            eligibility: model.eligibility,
            applicationFolders: model.applicationFolders,
            log: log,
            activity: activity,
            onInstallersRead: model.reloadInstalledMarks
        )
    }

    /// Starts Tidy Now over the listed files, under the same rule as any cleanup.
    private func startTidyNow() {
        guard canStartTidyNow, let log = activity.log, let folder = model.logFolder else { return }
        let model = model
        let tidy = TidyNowModel(
            actions: folder.rules.tidyNowActions,
            eligibility: model.eligibility,
            applicationFolders: model.applicationFolders,
            log: log,
            activity: activity,
            onPlanned: { plan in
                model.showDuplicateMarks(plan.duplicateURLs)
                model.reloadInstalledMarks()
            },
            onExecuted: {
                // Files moved, so the rows on screen are stale.
                model.refresh()
            }
        )
        tidyNow = PresentedTidyNow(model: tidy, log: log)
        tidy.start(
            records: model.records,
            folder: folder,
            eligibility: model.eligibility,
            applicationFolders: model.applicationFolders,
            hashCache: search.hashCache,
            log: log
        )
    }

    @ViewBuilder
    private var content: some View {
        if let place = section.folderPlace, place != .standard(.downloads), lists.list(at: place) == nil {
            folderNotShown(place)
        } else {
            listContent
        }
    }

    /// A folder place with no list: Desktop or Documents not turned on yet, or a folder that cannot
    /// be found now.
    @ViewBuilder
    private func folderNotShown(_ place: FolderPlace) -> some View {
        if let entry = activity.entry(at: place), case .failure(let error) = entry.state {
            let failure = ScanFailure(error, kind: entry.kind, name: entry.storedName)
            ScanErrorView(failure: failure, retry: activity.reloadFolders)
        } else if case .standard(let kind) = place, activity.log == nil {
            StateView(title: Text(kind.standardName), symbol: kind.systemImage, message: Text("Waiting for the activity log."))
        } else if case .standard(let kind) = place {
            StateView(
                title: Text("\(kind.standardName) is off"),
                symbol: kind.systemImage,
                message: Text("Turn it on to list and clean up its files. Your Mac may ask once whether Smart OS File Store can read it.")
            ) {
                Button("Turn on \(kind.standardName)") {
                    turnOn(kind)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canChangeFolders)
            }
        } else {
            StateView.loading
        }
    }

    @ViewBuilder
    private var listContent: some View {
        if let failure = model.failure {
            ScanErrorView(failure: failure, retry: model.canRefresh ? model.refresh : nil)
        } else if isShowingWelcome {
            // Nothing is read until the welcome closes.
            Color.clear
        } else if !model.hasLoadedOnce {
            StateView.loading
        } else if model.isEmpty {
            StateView(
                title: Text("Folder is empty"),
                symbol: "folder",
                message: model.place == .standard(.downloads) ? Text("Files you download are listed here.") : Text("Files you put in this folder are listed here.")
            )
        } else {
            VStack(spacing: 0) {
                FileFilterBar(filter: Bindable(model).filter)
                Divider()
                FileTableView(
                    model: model, selection: selectionBinding, isShown: section.folderPlace != nil, canChangeKept: canChangeKept,
                    reveal: fileToReveal
                )
                .focused($focusedPlace, equals: .folder(model.place))
                // Each folder's table is its own, with its own columns and scroll position.
                .id(model.place)
            }
        }
    }

    // MARK: - Storage

    /// A "get back" row's Review: its folder is shown, and the plan that was counted opens as that
    /// cleanup's own preview, so it shows exactly the files counted.
    private func reviewFromStorage(_ plan: CleanupPlan, _ place: FolderPlace) {
        guard canStartCleanup || lists.list(at: place)?.isSettled == true, activity.isListed(plan.folder) else { return }
        lastFolderPlace = place
        search.present(plan)
    }

    private func refreshStorage() {
        storage.refresh(lists: lists, activity: activity, hashCache: search.hashCache)
    }

    // MARK: - Folders

    /// False until the activity log is open, and while something that reads or moves files is under
    /// way: the folder list lives in the log, and a run's folder must stay on it.
    private var canChangeFolders: Bool {
        activity.log != nil && !search.isRunning && search.presentedPlan == nil && tidyNow == nil && !undo.isBusy
            && !chat.isCleaningUp && !isShowingWelcome
    }

    /// Downloads, Desktop and Documents, each shown or offered, then the folders the user added.
    private var sidebarFolders: [SidebarFolderRow] {
        var rows: [SidebarFolderRow] = []
        for place in FolderPlace.standardPlaces {
            guard case .standard(let kind) = place else { continue }
            rows.append(SidebarFolderRow(place: place, name: kind.standardName, kind: kind, state: rowState(place)))
        }
        for entry in activity.folderEntries where entry.kind == .custom {
            let place = FolderPlace(entry)
            let name = entry.folder?.displayName ?? entry.storedName ?? ManagedFolder.Kind.custom.standardName
            rows.append(SidebarFolderRow(place: place, name: name, kind: .custom, state: rowState(place)))
        }
        return rows
    }

    private func rowState(_ place: FolderPlace) -> SidebarFolderRow.State {
        if let list = lists.list(at: place) {
            return .shown(count: list.itemCount)
        }
        if let entry = activity.entry(at: place), entry.folder == nil {
            return .unavailable
        }
        return .off
    }

    /// Turns on Desktop or Documents and shows it. Its list is read once the log has it, which is
    /// when macOS asks.
    private func turnOn(_ kind: ManagedFolder.Kind) {
        guard canChangeFolders || isShowingWelcome else { return }
        section = .folder(.standard(kind))
        Task {
            if let error = await activity.turnOn(kind) {
                addFolderRefusal = error.addFolderSentence
            }
        }
    }

    /// Adds folders the user chose or dragged in, one after another; the first refused one says why.
    private func addFolders(_ urls: [URL]) {
        guard canChangeFolders else { return }
        Task {
            for url in urls {
                if let error = await activity.addFolder(at: url) {
                    addFolderRefusal = error.addFolderSentence
                    return
                }
                if let added = activity.folderEntries.last(where: { $0.kind == .custom }) {
                    section = .folder(FolderPlace(added))
                }
            }
        }
    }

    private func startRenaming(_ place: FolderPlace) {
        guard case .custom(let id) = place, let entry = activity.entry(at: place) else { return }
        renaming = RenamingFolder(id: id, name: entry.folder?.displayName ?? entry.storedName ?? "")
    }

    /// Takes a folder off the sidebar: nothing on disk changes, and its runs stay in Activity.
    private func removeFolder(_ place: FolderPlace) {
        guard canChangeFolders, let entry = activity.entry(at: place), entry.kind != .downloads else { return }
        if section == .folder(place) {
            section = .downloads
        }
        Task { await activity.remove(entry) }
    }
}

/// The sheet for one presented plan: its preview, with the activity log as it was when the plan was
/// presented. Read live, a log that failed during the run would swap the summary for the notice
/// below, and one that came back would rebuild the preview of a plan already carried out, with
/// every change ticked again.
private struct PresentedPlanSheet: View {
    let plan: CleanupPlan
    let eligibility: CandidateEligibility
    let applicationFolders: [URL]
    let activity: ActivityLogModel
    let markKept: @MainActor ([FileRecord], @escaping @MainActor (Bool) -> Void) -> Void
    let onExecuted: @MainActor () -> Void
    let onUndo: @MainActor (ActivityRun.ID) -> Void

    @State private var log: ActivityLog?

    init(
        plan: CleanupPlan,
        eligibility: CandidateEligibility,
        applicationFolders: [URL],
        activity: ActivityLogModel,
        markKept: @escaping @MainActor ([FileRecord], @escaping @MainActor (Bool) -> Void) -> Void,
        onExecuted: @escaping @MainActor () -> Void,
        onUndo: @escaping @MainActor (ActivityRun.ID) -> Void
    ) {
        self.plan = plan
        self.eligibility = eligibility
        self.applicationFolders = applicationFolders
        self.activity = activity
        self.markKept = markKept
        self.onExecuted = onExecuted
        self.onUndo = onUndo
        // A plan names its folder by the ID the log gave it. One made before the log was replaced
        // names a folder the open log does not hold, and cannot be carried out in it.
        _log = State(initialValue: activity.isListed(plan.folder) ? activity.log : nil)
    }

    var body: some View {
        if let log {
            CleanupPreviewSheet(
                plan: plan,
                eligibility: eligibility,
                applicationFolders: applicationFolders,
                log: log,
                activity: activity,
                markKept: markKept,
                onUndo: onUndo
            ) { _ in
                onExecuted()
            }
        } else {
            // The log stopped working, or was replaced, between the search and its preview: nothing
            // may be carried out, so there is nothing to preview.
            ActivityLogUnavailableSheet(activity: activity)
        }
    }
}

/// A custom folder whose name is being changed.
private struct RenamingFolder: Identifiable {
    let id: ManagedFolder.ID
    let name: String
}

/// A cleanup card of the chat whose Confirm is asking its question, with the card's plan.
private struct ConfirmingCard: Identifiable {
    let id: CleanupProposal.ID
    let model: TidyNowModel
}

/// A Tidy Now on screen, with the activity log as it was when it started, as a sheet's item.
private struct PresentedTidyNow: Identifiable {
    let id = UUID()
    let model: TidyNowModel
    let log: ActivityLog
}

private extension View {
    /// The place on screen, or one kept alive out of sight: invisible, and taking no clicks, no
    /// keyboard focus and no VoiceOver attention.
    func placeShown(_ isShown: Bool) -> some View {
        opacity(isShown ? 1 : 0)
            .motion(Design.Motion.quick, value: isShown)
            .allowsHitTesting(isShown)
            .disabled(!isShown)
            .accessibilityHidden(!isShown)
    }
}
