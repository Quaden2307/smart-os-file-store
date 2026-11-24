import Foundation

/// What code makes of a parsed request: the answer to look up, the cleanup to plan, or why there
/// is none. Pure: it reads the request and the snapshot and nothing else (docs/decisions/0036).
public enum ChatRequestPlanner {
    /// What a request lacks before it can be answered. The reply asks for it in one question.
    public enum Missing: Sendable, Equatable {
        /// A cleanup that names neither a cleanup nor files.
        case cleanup
        /// "Those" with no last result.
        case lastResult
        /// An age that says too little to be counted ("in" a month with no month).
        case when
        /// Slots that cannot hold together, such as at least 50 MB and at most 10 MB.
        case files
        /// A folder the app does not manage.
        case folder
    }

    public enum CannotDoReason: Sendable, Equatable {
        case asked(ChatRequest.CannotDo)
        /// A managed folder macOS has not allowed the app to read, or that cannot be found now.
        case folder(String, FolderSnapshot.Folder.State)
    }

    public enum Answer: Sendable, Equatable {
        /// A list, or only its count.
        case search(FileQuery, FileSort, limit: Int, scope: FolderScope, count: Bool)
        /// A card, one per folder of the scope.
        case cleanup(CleanupRequest, scope: FolderScope)
        case duplicates(FolderScope)
        case overview(FolderScope)
        case cannotDo(CannotDoReason)
        case chat
        case needsMore(Missing)
    }

    /// The answer to `request`.
    ///
    /// - Parameters:
    ///   - lastResult: The files the last turn ended on and their order, for "those".
    ///   - cleanupActions: The actions the app offers, as it names them.
    public static func plan(
        _ request: ChatRequest, in snapshot: FolderSnapshot, today: Date,
        lastResult: (ids: [URL], sort: FileSort?)?, cleanupActions: [String]
    ) -> Answer {
        do throws(Early) {
            return try answer(request, in: snapshot, today: today, lastResult: lastResult, cleanupActions: cleanupActions)
        } catch {
            return error.answer
        }
    }

    /// An answer reached before the request was read to its end.
    private struct Early: Error {
        let answer: Answer
    }

    private static func answer(
        _ request: ChatRequest, in snapshot: FolderSnapshot, today: Date,
        lastResult: (ids: [URL], sort: FileSort?)?, cleanupActions: [String]
    ) throws(Early) -> Answer {
        switch request.kind {
        case .cannotDo: return .cannotDo(.asked(request.cannotDo ?? .other))
        case .chat: return .chat
        case .list, .count, .cleanup, .duplicates, .overview: break
        }
        let insideLastResult = request.aboutLastResult == true && [.list, .count, .cleanup].contains(request.kind)
        if insideLastResult, lastResult == nil { throw Early(answer: .needsMore(.lastResult)) }
        // The parser was offered the names cleaned and cut short (`ChatParser.schema`): back to the real one.
        let folder = request.folder.map { name in
            snapshot.folders.first { ToolOutput.cleaned($0.name, limit: 40).caseInsensitiveCompare(name) == .orderedSame }?.name ?? name
        }
        let scope = try self.scope(folder, in: snapshot, insideLastResult: insideLastResult)
        if request.kind == .duplicates { return .duplicates(scope) }
        if request.kind == .overview { return .overview(scope) }

        var built = try query(request.files, today: today)
        if insideLastResult, let lastResult { built.withinIDs = Set(lastResult.ids) }
        // Only the user's slots narrow: an empty query is every file.
        let query = built == FileQuery() ? nil : built

        if request.kind == .cleanup {
            var actions = request.actions(offered: cleanupActions)
            if actions.isEmpty {
                // "Tidy up the PDFs" names files and no cleanup: every cleanup, on those files only.
                guard query != nil else { return .needsMore(.cleanup) }
                actions = cleanupActions
            }
            return .cleanup(CleanupRequest(actions: actions, query: query), scope: scope)
        }
        let asked: FileSort? = try? FileFilter.choice(request.sort, named: "sort")
        // "Only the big ones" keeps the order the list was in.
        let sort = asked ?? (insideLastResult ? lastResult?.sort : nil) ?? .newest
        let range = FileSearchResult.limitRange
        let limit = min(max(request.limit ?? FileSearchResult.defaultLimit, range.lowerBound), range.upperBound)
        return .search(query ?? FileQuery(), sort, limit: limit, scope: scope, count: request.kind == .count)
    }

    private static func scope(_ name: String?, in snapshot: FolderSnapshot, insideLastResult: Bool) throws(Early) -> FolderScope {
        do throws(FilterError) {
            return try FolderScope.resolve(name, in: snapshot, insideLastResult: insideLastResult)
        } catch {
            // The parser offers only the managed folders' names, so a refusal is nearly always a
            // folder the app cannot read now.
            guard let folder = snapshot.folders.first(where: { $0.name.caseInsensitiveCompare(name ?? "") == .orderedSame }),
                  folder.state != .available else {
                throw Early(answer: .needsMore(.folder))
            }
            throw Early(answer: .cannotDo(.folder(folder.name, folder.state)))
        }
    }

    /// The slots as a checked query, through the same checks as a tool's filter.
    private static func query(_ slots: FileSlots?, today: Date) throws(Early) -> FileQuery {
        guard let slots else { return FileQuery() }
        var filter = FileFilter(
            nameContains: slots.nameContains, typeGroup: slots.kind, neverOpened: slots.neverOpened,
            largerThanMB: slots.minMB, smallerThanMB: slots.maxMB, sourceSite: slots.site, mark: slots.mark
        )
        // An age that cannot be counted is asked about: left out, it would widen a cleanup.
        if let age = slots.added {
            guard let range = age.range(today: today) else { throw Early(answer: .needsMore(.when)) }
            filter.addedSince = range.from.map(DayText.string)
            filter.addedBefore = range.before.map(DayText.string)
        }
        if let age = slots.opened {
            guard let range = age.range(today: today) else { throw Early(answer: .needsMore(.when)) }
            filter.openedSince = range.from.map(DayText.string)
            filter.openedBefore = range.before.map(DayText.string)
        }
        // "lastResult" is the tool's word for "those", not a mark the user can name.
        if filter.mark?.caseInsensitiveCompare(FileFilter.lastResultMark) == .orderedSame { filter.mark = nil }
        do throws(FilterError) {
            return try filter.validated(now: today)
        } catch {
            throw Early(answer: .needsMore(.files))
        }
    }
}

extension Age {
    /// The days this age covers, counted back from the start of `today`: `from` is included,
    /// `before` is not. Month and year steps are the calendar's, so a month back from 31 March is
    /// 28 or 29 February. Nil when the age says too little to be counted.
    public func range(today: Date) -> FileQuery.DateRange? {
        let calendar = DayText.calendar
        let start = calendar.startOfDay(for: today)
        let component: Calendar.Component = switch unit ?? .days {
        case .days: .day
        case .weeks: .weekOfYear
        case .months: .month
        case .years: .year
        }
        func back(_ amount: Int) -> Date? {
            amount >= 0 ? calendar.date(byAdding: component, value: -amount, to: start) : nil
        }
        func dayAfter(_ date: Date?) -> Date? {
            date.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
        }
        switch relation {
        case .within:
            return back(amount ?? 1).map { FileQuery.DateRange(from: $0) }
        case .olderThan:
            return back(amount ?? 1).map { FileQuery.DateRange(before: $0) }
        case .onDay:
            // With no amount, today.
            guard let day = back(amount ?? 0), let end = dayAfter(day) else { return nil }
            return FileQuery.DateRange(from: day, before: end)
        case .between:
            guard let amount, let amountTo else { return nil }
            guard let from = back(max(amount, amountTo)), let before = dayAfter(back(min(amount, amountTo))) else { return nil }
            return FileQuery.DateRange(from: from, before: before)
        case .inMonth:
            guard let month, (1...12).contains(month) else { return nil }
            let now = calendar.dateComponents([.year, .month], from: start)
            // With no year, the latest such month that is not in the future.
            let year = year ?? ((now.year ?? 0) - (month > (now.month ?? 12) ? 1 : 0))
            guard let from = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                  let before = calendar.date(byAdding: .month, value: 1, to: from) else { return nil }
            return FileQuery.DateRange(from: from, before: before)
        }
    }
}
