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

    @Test func plansPointAtTheGeneratedTestTargets() throws {
        let project = try SafetyTests.projectRoot().appending(path: "SmartOSFileStore.xcodeproj/project.pbxproj")
        let generated = try String(contentsOf: project, encoding: .utf8)
        for name in ["SmartOSFileStore", "Benchmark"] {
            let targets = try plan(named: name).testTargets.map(\.target)
            // Both test bundles, or one of them would never run.
            #expect(targets.map(\.name) == ["FileStoreCoreTests", "FileStoreIntelligenceTests"])
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
    @Test func defaultPlanLeavesTheBenchmarksOutAndTheBenchmarkPlanRunsOnlyThem() throws {
        // The engine's benchmark, and the chat's measurements and evals on the real model.
        let measured = [["BenchmarkTests"], ["ChatMeasurementTests", "ChatEvalTests", "FolderChatEvalTests"]]
        let normal = try plan(named: "SmartOSFileStore").testTargets
        #expect(normal.map { $0.skippedTests?.suites.map(\.name) } == measured)
        #expect(normal.allSatisfy { $0.selectedTests == nil })
        let benchmark = try plan(named: "Benchmark").testTargets
        #expect(benchmark.map { $0.selectedTests?.suites.map(\.name) } == measured)
        #expect(benchmark.allSatisfy { $0.skippedTests == nil })
        #expect(String(describing: BenchmarkTests.self) == "BenchmarkTests")
        // The other bundle's suites cannot be named from here; their sources can be read.
        for suite in ["ChatMeasurementTests", "ChatEvalTests"] {
            let chat = try SafetyTests.projectRoot().appending(path: "FileStoreIntelligenceTests/\(suite).swift")
            #expect(try String(contentsOf: chat, encoding: .utf8).contains("\nstruct \(suite) {"))
        }
    }
}
