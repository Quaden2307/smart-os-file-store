import Foundation

/// What is taking space in a managed folder, as pure functions over one scan's records. Sizes are
/// the files' sizes on disk at the top level the app manages; a cloud-only file takes no local
/// space and counts as zero, with a count of its own so the screen can say so.
public enum StorageReport {
    public struct Total: Sendable, Equatable {
        public var count = 0
        /// Space on this Mac.
        public var bytes: Int64 = 0
        /// Files whose content is in the cloud only, counted as zero bytes.
        public var cloudOnlyCount = 0

        public init(count: Int = 0, bytes: Int64 = 0, cloudOnlyCount: Int = 0) {
            self.count = count
            self.bytes = bytes
            self.cloudOnlyCount = cloudOnlyCount
        }

        mutating func add(_ record: FileRecord) {
            count += 1
            bytes += StorageReport.localBytes(of: record)
            if record.isDataless { cloudOnlyCount += 1 }
        }
    }

    /// The space `record` takes on this Mac: none for a cloud placeholder, its allocated size where
    /// the scan read one, else its size.
    public static func localBytes(of record: FileRecord) -> Int64 {
        guard !record.isDataless else { return 0 }
        return record.allocatedSizeInBytes ?? record.sizeInBytes ?? 0
    }

    public static func total(of records: [FileRecord]) -> Total {
        var total = Total()
        records.forEach { total.add($0) }
        return total
    }

    /// Totals per group, with the grouping the caller gives (the app's type groups).
    public static func totals<Group: Hashable>(of records: [FileRecord], by group: (FileRecord) -> Group) -> [Group: Total] {
        var totals: [Group: Total] = [:]
        for record in records {
            totals[group(record), default: Total()].add(record)
        }
        return totals
    }

    /// The `count` records taking the most space here, largest first, ties by name.
    public static func largest(_ records: [FileRecord], count: Int = 10) -> [FileRecord] {
        Array(records.filter { localBytes(of: $0) > 0 }.sorted {
            let (left, right) = (localBytes(of: $0), localBytes(of: $1))
            return left != right ? left > right : $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }.prefix(count))
    }
}

/// What each cleanup a folder offers would move to the Trash, as its preview would tick it. Planned
/// by the real planners under the folder's rules, overlap resolved as Tidy Now resolves it, so a
/// file two actions want is counted once, for the higher-ranked one.
public struct ReclaimableSpace: Sendable {
    public struct Row: Sendable, Equatable {
        public let action: CleanupAction
        /// The ticked changes that go to the Trash.
        public let count: Int
        public let bytes: Int64
    }

    public let folder: ManagedFolder

    /// Per action, its plan narrowed to what is counted: what its preview ticks by default. The
    /// storage view opens exactly this plan, so the preview shows the files that were counted.
    public let plans: [CleanupPlan]

    public init(folder: ManagedFolder, resolved: [CleanupPlan]) {
        self.folder = folder
        plans = resolved.map { plan in
            plan.removing(Set(plan.changes.map(\.id)).subtracting(plan.defaultTickedIDs))
        }
    }

    /// One row per action whose counted plan moves something to the Trash, most space first.
    public var rows: [Row] {
        plans.compactMap { plan in
            let trashed = plan.changes.filter { if case .moveToTrash = $0.operation { true } else { false } }
            guard !trashed.isEmpty else { return nil }
            return Row(action: plan.action, count: trashed.count, bytes: trashed.reduce(0) { $0 + StorageReport.localBytes(of: $1.record) })
        }
        .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.count > $1.count }
    }

    public var totalBytes: Int64 { rows.reduce(0) { $0 + $1.bytes } }

    /// Plans every action the folder offers over `records` and counts what would be ticked.
    @concurrent
    public static func plan(
        records: [FileRecord],
        in folder: ManagedFolder,
        eligibility: CandidateEligibility,
        keptItems: KeptItems,
        installers: InstallerSources,
        settings: CleanupSettings = CleanupSettings(),
        hashCache: ContentHashCache = ContentHashCache(),
        now: Date = .now
    ) async throws(CleanupPlanningError) -> ReclaimableSpace {
        let planner = TidyNowPlanner(
            actions: TidyNowPlan.order.filter(folder.rules.offers), eligibility: eligibility, keptItems: keptItems,
            installers: installers, settings: settings, records: records, folder: folder, now: now
        )
        return ReclaimableSpace(folder: folder, resolved: try await planner.plan(hashCache: hashCache).plans)
    }
}
