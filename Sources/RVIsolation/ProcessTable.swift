#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A process as one read of the kernel's table saw it. The start time is
/// what a reused pid changes: libproc's `pbi_start_tv*` on macOS; on Linux
/// `/proc/<pid>/stat` field 22 (clock ticks after boot) as seconds and
/// microseconds. The field types are libproc's, so the macOS comparisons
/// read exactly as they did against `proc_bsdinfo`.
struct ProcessIdentity: Equatable, Sendable {
    var pid: UInt32
    var parent: UInt32
    var group: UInt32
    var startSeconds: UInt64
    var startMicroseconds: UInt64
}

/// One lookup. `absent` is a process that is gone (skip it); `unavailable`
/// is a kernel that would not answer (the caller cannot tell).
enum ProcessLookup: Equatable, Sendable {
    case found(ProcessIdentity)
    case absent
    case unavailable
}

/// What the kernel says a process runs.
enum ProcessExecutable: Equatable, Sendable {
    /// macOS: `proc_pidpath`, the path of the process's text vnode.
    case path(String)
    /// Linux: the target `/proc/<pid>/exe` reads as, and the identity of the
    /// file it opens, which is the file the process runs even when the path
    /// now names another (a bind mount in the process's mount namespace) or
    /// nothing (` (deleted)`).
    case file(path: String, running: GatewayBinaryPin)
}

/// The kernel primitives the gateway's runtime binding reads. The scan
/// (`GatewayPeerScan`), the binary walk (`GatewayBinaryScan`) and group
/// recovery (`ProcessGroupRecovery`) are written once against this; macOS
/// answers with libproc (`LibprocProcessTable`), Linux with `/proc`
/// (`ProcFSProcessTable`). A table is used for one decision and dropped.
protocol ProcessTable {
    func lookup(_ pid: pid_t) -> ProcessLookup
    /// The session `pid` belongs to; nil when it could not be read.
    func session(of pid: pid_t) -> pid_t?
    /// The live children of `pid`, above pid 1. Nil when they could not be listed.
    func children(of pid: pid_t) -> [pid_t]?
    /// This user's processes, above pid 1. Nil when they could not be listed.
    func userProcesses() -> [pid_t]?
    /// Whether `pid` holds the client socket of `peer`'s connection. Nil
    /// when its descriptors could not be read.
    func holdsSocket(_ pid: pid_t, _ peer: GatewayPeer) -> Bool?
    /// Nil when it could not be read.
    func executable(_ pid: pid_t) -> ProcessExecutable?
    /// How `GatewayPeerScan` reads a failed `userProcesses()`, or a session
    /// (the leader's or a listed process's) that `session(of:)` could not
    /// read, while it searches a session. The libproc scan has always read
    /// these as not in the session, and keeps doing so; `/proc` reads them
    /// as a scan that cannot tell.
    var failedListingIsEmptySession: Bool { get }
}

/// The table for this host.
enum HostProcessTable {
    #if os(macOS)
    static func make() -> LibprocProcessTable { LibprocProcessTable() }
    #else
    static func make() -> ProcFSProcessTable { ProcFSProcessTable() }
    #endif
}
