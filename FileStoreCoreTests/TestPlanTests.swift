import Foundation
import Testing

/// The committed test plans point at the generated project's test target by XcodeGen's identifier,
/// and the .xcodeproj is regenerated, never committed. If the identifier ever changed, the plans
/// could quietly stop leaving the benchmark out of the normal run; this catches it.
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

    @Test func plansPointAtTheGeneratedTestTarget() throws {
        let project = try SafetyTests.projectRoot().appending(path: "SmartOSFileStore.xcodeproj/project.pbxproj")
        let generated = try String(contentsOf: project, encoding: .utf8)
        for name in ["SmartOSFileStore", "Benchmark"] {
            let target = try #require(try plan(named: name).testTargets.first).target
            #expect(target.name == "FileStoreCoreTests")
            // XcodeGen writes each target as `<identifier> /* <name> */ = {` followed by its `isa`.
            #expect(
                generated.contains("\(target.identifier) /* \(target.name) */ = {\n\t\t\tisa = PBXNativeTarget;"),
                "\(name).xctestplan names \(target.identifier), which is not the generated FileStoreCoreTests target"
            )
        }
    }

    /// Swift Testing honours only the structured `{"suites": [{"name": …}]}` form, by type name.
    @Test func defaultPlanLeavesTheBenchmarkOutAndTheBenchmarkPlanRunsOnlyIt() throws {
        let normal = try #require(try plan(named: "SmartOSFileStore").testTargets.first)
        #expect(normal.skippedTests?.suites.map(\.name) == ["BenchmarkTests"])
        #expect(normal.selectedTests == nil)
        let benchmark = try #require(try plan(named: "Benchmark").testTargets.first)
        #expect(benchmark.selectedTests?.suites.map(\.name) == ["BenchmarkTests"])
        #expect(String(describing: BenchmarkTests.self) == "BenchmarkTests")
    }
}
