import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Pids of this user's running `rvd` processes, so a literal-pid `kill`
/// of rvd is caught at evaluation time. Nil when the process table could
/// not be read: callers fail closed.
package func runningRVDaemonPIDs() -> Set<Int32>? {
    var pids: Set<Int32> = []
    if ProcessInfo.processInfo.processName == "rvd" { pids.insert(getpid()) }
    #if canImport(Darwin)
    let uid = getuid()
    let estimate = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
    guard estimate > 0 else { return nil }
    let stride = MemoryLayout<pid_t>.stride
    var all = [pid_t](repeating: 0, count: Int(estimate) / stride + 64)
    let bytes = all.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY), uid, $0.baseAddress, Int32($0.count)) }
    guard bytes > 0 else { return nil }
    for pid in all.prefix(min(Int(bytes) / stride, all.count)) where pid > 0 {
        var name = [CChar](repeating: 0, count: 64)
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { continue }
        if String(cString: name) == "rvd" { pids.insert(pid) }
    }
    #else
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return nil }
    for entry in entries {
        guard let pid = Int32(entry),
              let comm = try? String(contentsOfFile: "/proc/\(entry)/comm", encoding: .utf8)
        else { continue }
        if comm.trimmingCharacters(in: .whitespacesAndNewlines) == "rvd" { pids.insert(pid) }
    }
    #endif
    return pids
}
