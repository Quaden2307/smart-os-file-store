import Foundation

/// Units for the measurements the scale tests and the benchmark report.
enum Measured {
    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    static func mebibytes(_ bytes: UInt64) -> String {
        String(format: "%.1f MiB", Double(bytes) / Double(1 << 20))
    }
}
