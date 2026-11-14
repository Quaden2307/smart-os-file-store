import Darwin
import Foundation

/// The test process's physical memory footprint in bytes, as Activity Monitor reports it.
/// Nil if the kernel refuses to say.
func physicalFootprintInBytes() -> UInt64? {
    resourceUsage()?.ri_phys_footprint
}

/// The highest physical footprint the test process has reached since it started. When a suite runs
/// alone, this covers everything it did, including stretches nothing sampled.
func lifetimePeakFootprintInBytes() -> UInt64? {
    resourceUsage()?.ri_lifetime_max_phys_footprint
}

private func resourceUsage() -> rusage_info_v4? {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, rebound)
        }
    }
    guard result == 0 else { return nil }
    return usage
}
