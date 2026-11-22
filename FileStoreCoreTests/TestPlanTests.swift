import Foundation
import Testing

/// The committed test plans point at the generated project's test targets by XcodeGen's identifiers,
/// and the .xcodeproj is regenerated, never committed. If an identifier ever changed, the plans
/// could quietly stop leaving the benchmarks out of the normal run; this catches it.
@Suite("Test plans")
struct TestPlanTests {
    private struct Plan: Decodable {
        struct Suite: Decodable { let name: String }
        struct Selection: Decodable { let suites: [Suite] }
        struct Target: Decodable { let identifier: String; let name: String }
        struct TestTarget: Decodable {
            let target: Target
            let skippedTests: Selection?
            let selectedTests: Selection?
        }
        let testTargets: [TestTarget]
    }

    private func plan(named name: String) throws -> Plan {
        let url = try SafetyTests.projectRoot().appending(path: "TestPlans/\(name).xctestplan")
        return try JSONDecoder().decode(Plan.self, from: Data(contentsOf: url))
    }

    /// Each plan's test bundles, in order.
    static let targets = [
        "SmartOSFileStore": ["FileStoreCoreTests", "FileStoreIntelligenceTests", "ChatEvals"],
        "Benchmark": ["FileStoreCoreTests", "FileStoreIntelligenceTests"],
        "Evals": ["FileStoreIntelligenceTests", "ChatEvals"],
    ]

    @Test func plansPointAtTheGeneratedTestTargets() throws {
        let project = try SafetyTests.projectRoot().appending(path: "SmartOSFileStore.xcodeproj/project.pbxproj")
        let generated = try String(contentsOf: project, encoding: .utf8)
        for (name, names) in Self.targets {
            let targets = try plan(named: name).testTargets.map(\.target)
            // Every bundle the plan is for, or one of them would never run.
            #expect(targets.map(\.name) == names, "\(name).xctestplan")
            for target in targets {
                // XcodeGen writes each target as `<identifier> /* <name> */ = {` followed by its `isa`.
                #expect(
                    generated.contains("\(target.identifier) /* \(target.name) */ = {\n\t\t\tisa = PBXNativeTarget;"),
                    "\(name).xctestplan names \(target.identifier), which is not the generated \(target.name) target"
                )
            }
        }
    }

    /// Swift Testing honours only the structured `{"suites": [{"name": …}]}` form, by type name.
    /// The default plan runs everything but the benchmark, the chat's measurements and its
    /// real-model evals; the Benchmark plan runs only the first two, the Evals plan only the evals.
    @Test func eachPlanRunsItsOwnSuitesAndTheDefaultPlanNoneOfThem() throws {
        let benchmark = [["BenchmarkTests"], ["ChatMeasurementTests"]]
        let evals = [["ChatEvalTests", "FolderChatEvalTests"], ["ChatEvalRun"]]
        let normal = try plan(named: "SmartOSFileStore").testTargets
        #expect(normal.map { $0.skippedTests?.suites.map(\.name) } == [["BenchmarkTests"], ["ChatMeasurementTests", "ChatEvalTests", "FolderChatEvalTests"], ["ChatEvalRun"]])
        #expect(normal.allSatisfy { $0.selectedTests == nil })
        for (name, selected) in [("Benchmark", benchmark), ("Evals", evals)] {
            let targets = try plan(named: name).testTargets
            #expect(targets.map { $0.selectedTests?.suites.map(\.name) } == selected, "\(name).xctestplan")
            #expect(targets.allSatisfy { $0.skippedTests == nil })
        }
        #expect(String(describing: BenchmarkTests.self) == "BenchmarkTests")
        // The other bundles' suites cannot be named from here; their sources can be read.
        for (folder, suite) in [
            ("FileStoreIntelligenceTests", "ChatMeasurementTests"), ("FileStoreIntelligenceTests", "ChatEvalTests"),
            ("FileStoreIntelligenceTests", "FolderChatEvalTests"), ("ChatEvals", "ChatEvalRun"),
        ] {
            let source = try SafetyTests.projectRoot().appending(path: "\(folder)/\(suite).swift")
            #expect(try String(contentsOf: source, encoding: .utf8).contains("\nstruct \(suite) {"), "\(folder)/\(suite).swift")
        }
    }
}
