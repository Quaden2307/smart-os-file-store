import FileStoreCore
import Foundation
import Testing
import UniformTypeIdentifiers

/// The storage view's numbers (decision record 0030): totals, per group, the largest files, and
/// what each cleanup would move to the Trash, counted as its preview ticks it and never twice.
@Suite("Storage report")
struct StorageReportTests {
    private static func record(_ name: String, bytes: Int64, allocated: Int64? = nil, cloudOnly: Bool = false, type: UTType = .pdf) -> FileRecord {
        FileRecord(
            url: URL(filePath: "/tmp/Storage/\(name)"), displayName: name, kind: .file, localizedTypeDescription: nil,
            contentType: type, sizeInBytes: bytes, dateAdded: nil, dateModified: nil, isDownloading: false,
            allocatedSizeInBytes: allocated, isDataless: cloudOnly
        )
    }

    @Test func totalsCountSpaceOnDiskAndCloudOnlyFilesAsZero() {
        let records = [
            Self.record("a.pdf", bytes: 1_000, allocated: 4_096),
            Self.record("b.pdf", bytes: 10_000),
            Self.record("cloud.pdf", bytes: 5_000_000, cloudOnly: true),
            Self.record("photo.jpg", bytes: 2_000, allocated: 4_096, type: .jpeg),
        ]
        let total = StorageReport.total(of: records)
        #expect(total == StorageReport.Total(count: 4, bytes: 4_096 + 10_000 + 4_096, cloudOnlyCount: 1))

        let byType = StorageReport.totals(of: records) { $0.contentType == .jpeg ? "images" : "documents" }
        #expect(byType["images"] == StorageReport.Total(count: 1, bytes: 4_096))
        #expect(byType["documents"]?.cloudOnlyCount == 1)
        // The groups add up to the whole.
        #expect(byType.values.reduce(0) { $0 + $1.bytes } == total.bytes)
        #expect(byType.values.reduce(0) { $0 + $1.count } == total.count)
    }

    @Test func theLargestAreBySpaceOnDiskAndLeaveOutCloudOnlyFiles() {
        let records = (1...15).map { Self.record("f\($0).pdf", bytes: Int64($0) * 1_000) } + [Self.record("cloud.pdf", bytes: 99_000_000, cloudOnly: true)]
        let largest = StorageReport.largest(records)
        #expect(largest.count == 10)
        #expect(largest.first?.displayName == "f15.pdf")
        #expect(!largest.contains { $0.isDataless })
    }

    /// Over the fixture: every row is counted from a plan's default ticks, Trash changes only, and
    /// no file is counted for two actions.
    @Test func reclaimableSpaceCountsWhatPreviewsTickOnceEach() async throws {
        try await withFakeDownloadsFolder { fixture in
            let records = try await RelocationPlans.records(in: fixture.url)
            let folder = ManagedFolder.temporary(fixture.url)
            let space = try await ReclaimableSpace.plan(
                records: records, in: folder, eligibility: CandidateEligibility(), keptItems: KeptItems(),
                installers: .testing(applications: [fixture.applicationsURL])
            )
            #expect(!space.rows.isEmpty)
            let counted = space.plans.flatMap { $0.changes.filter { if case .moveToTrash = $0.operation { true } else { false } } }
            #expect(Set(counted.map(\.id)).count == counted.count)
            for plan in space.plans {
                #expect(Set(plan.changes.map(\.id)) == plan.defaultTickedIDs)
            }
            // Each row is what its plan's preview would move to the Trash.
            for row in space.rows {
                let plan = try #require(space.plans.first { $0.action == row.action })
                #expect(row.bytes == plan.changes.reduce(0) { total, change in
                    if case .moveToTrash = change.operation { total + StorageReport.localBytes(of: change.record) } else { total }
                })
            }
            #expect(space.totalBytes == space.rows.reduce(0) { $0 + $1.bytes })
        }
    }

    /// Documents ticks nothing, so nothing is counted there; review-only actions count nothing anywhere.
    @Test func aFolderThatTicksNothingHasNothingToGetBack() async throws {
        try await withFakeDownloadsFolder { fixture in
            let records = try await RelocationPlans.records(in: fixture.url)
            let documents = ManagedFolder(kind: .documents, url: fixture.url)
            let space = try await ReclaimableSpace.plan(
                records: records, in: documents, eligibility: CandidateEligibility(), keptItems: KeptItems(), installers: .testing()
            )
            #expect(space.rows.isEmpty)
            #expect(space.plans.allSatisfy { $0.changes.isEmpty })
            #expect(space.plans.allSatisfy { documents.rules.offers($0.action) })
        }
    }
}
