import Foundation
import Testing

/// The app's views take every font, colour, spacing, radius and animation from
/// `SmartOSFileStore/DesignTokens.swift` (docs/design.md). The app has no test target, so this
/// reads its sources as text, the way `SafetyTests` does.
@Suite("Design tokens")
struct DesignTokenTests {
    private static let tokensFile = "DesignTokens.swift"

    /// What a view may not write, and what to tell whoever wrote it.
    private static let rules: [(pattern: String, message: String)] = [
        (#"\.font\((?!Design\.)"#, "a font that is not a Design.Typography role"),
        (#"\.system\(size:|\bofSize:|\bFont\.custom\b"#, "a raw font size"),
        (#"\bColor\(|\bColor\.(?!clear\b)|\bNSColor\b"#, "a raw colour"),
        (
            #"[(\s]\.(red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|gray|black|white)\b"#,
            "a named colour: use Design.Colour"
        ),
        (#"Gradient\b|\.gradient\b|\.shadow\("#, "a gradient or a shadow"),
        (#"\.padding\([^)]*\b\d"#, "a padding that is not a Design.Space step"),
        (#"[sS]pacing:\s*[1-9]"#, "a spacing that is not a Design.Space step"),
        (#"\b(cornerRadius|radius|duration):\s*\d|\bminLength:\s*[1-9]"#, "a raw radius, duration or length"),
        (
            #"\.(easeInOut|easeIn|easeOut|linear|spring|smooth|snappy|bouncy|interpolatingSpring)\b|[(\s]\.default\b"#,
            "a raw animation: use Design.Motion"
        ),
        (#"\.animation\("#, "an animation that skips Reduce Motion: use .motion(_:value:)"),
    ]

    /// Every rule a piece of code breaks, each as "matched text: message". Sizes of frames and
    /// table columns, and a view's own constants, may be numbers on the 4 point grid.
    private static func violations(in code: String) throws -> [String] {
        var found: [String] = []
        for rule in rules {
            for match in code.matches(of: try SafetyTests.regex(rule.pattern)) {
                found.append("\(code[match.range]): \(rule.message)")
            }
        }
        for size in code.matches(of: /\.(?:frame|width)\(((?:[^()]|\([^()]*\))*)\)/) {
            for number in size.1.replacing("_", with: "").matches(of: /\b\d+(?:\.\d+)?\b/) {
                guard let value = Double(number.0), value.truncatingRemainder(dividingBy: 4) != 0 else { continue }
                found.append("\(size.0): \(number.0) is off the 4 point grid")
            }
        }
        for constant in code.matches(of: /CGFloat\s*=\s*(\d+(?:\.\d+)?)/) {
            guard let value = Double(constant.1), value.truncatingRemainder(dividingBy: 4) != 0 else { continue }
            found.append("\(constant.0): a view's own constant is off the 4 point grid")
        }
        return found
    }

    @Test func theScanSeesEachRawValue() throws {
        let bad = [
            ".font(.caption)", ".font(.system(size: 12))", "NSFont.systemFont(ofSize: 13)",
            "Color(red: 1, green: 0, blue: 0)", "Color.blue", "NSColor.labelColor", ".foregroundStyle(.red)",
            ".fill(.blue.gradient)", "LinearGradient(colors: [])", ".shadow(radius: Design.Space.xs)",
            ".padding(6)", ".padding(.horizontal, 12)", "HStack(spacing: 8)", "Grid(horizontalSpacing: 16)",
            "RoundedRectangle(cornerRadius: 12)", ".blur(radius: 5)", "Spacer(minLength: 12)",
            ".animation(.easeInOut(duration: Design.Space.xs), value: isOpen)", "withAnimation(.smooth) {}",
            ".animation(isOn ? nil : .default, value: isOn)", ".animation(Design.Motion.quick, value: isOn)",
            ".frame(width: 26, height: 24)", ".frame(width: Self.width(for: row), height: 13)",
            ".width(min: 90, ideal: 1_080)", "static let indent: CGFloat = 22",
        ]
        for line in bad {
            #expect(try !Self.violations(in: line).isEmpty, "the scan misses \(line)")
        }
        let good = """
            Text(name).font(Design.Typography.caption.weight(.semibold)).foregroundStyle(.secondary)
            VStack(spacing: 0) { Spacer(minLength: 0); Color.clear }
            row.padding(.horizontal, Design.Space.m).frame(minWidth: 1_080, maxHeight: .infinity)
            FileManager.default.fileExists(atPath: path)
            column.width(min: 120, ideal: 164).motion(Design.Motion.quick, value: isOpen)
            static let minHeight: CGFloat = 160
            """
        #expect(try Self.violations(in: good) == [])
    }

    @Test func viewsTakeEveryStyleFromTheTokens() throws {
        let views = try SafetyTests.sources(of: "SmartOSFileStore").filter { $0.name != Self.tokensFile }
        #expect(views.count >= 40)
        for view in views {
            #expect(try Self.violations(in: view.code) == [], "\(view.label)")
        }
    }

    /// The chat bar's values, some of them off the grid, stay in the chat bar.
    @Test func onlyTheChatUsesTheChatTokens() throws {
        let chatFiles: Set = ["ChatBar.swift", "ChatCleanupCard.swift", "ConversationPanel.swift", "ThinkingIndicator.swift"]
        let others = try SafetyTests.sources(of: "SmartOSFileStore")
            .filter { $0.name != Self.tokensFile && !chatFiles.contains($0.name) }
        #expect(others.count >= 40)
        for source in others {
            #expect(!source.code.contains("Design.Chat"), "\(source.label) uses a chat token")
        }
    }

    /// The spacing steps themselves sit on the grid; `tight` is the one half step.
    @Test func spacingStepsSitOnTheGrid() throws {
        let tokens = try #require(SafetyTests.sources(of: "SmartOSFileStore").first { $0.name == Self.tokensFile })
        let space = try #require(tokens.code.firstMatch(of: /enum Space \{([^}]*)\}/))
        let steps = space.1.matches(of: /static let (\w+): CGFloat = (\d+)/)
        #expect(steps.count >= 5)
        for step in steps where step.1 != "tight" {
            #expect(try #require(Int(step.2)) % 4 == 0, "Design.Space.\(step.1) is off the grid")
        }
    }
}
