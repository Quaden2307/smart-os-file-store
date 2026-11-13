import Darwin
import Foundation

/// The test process's physical memory footprint in bytes, as Activity Monitor reports it.
/// Nil if the kernel refuses to say.
func physicalFootprintInBytes() -> UInt64? {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, rebound)
        }
    }
    guard result == 0 else { return nil }
    return usage.ri_phys_footprint
}
