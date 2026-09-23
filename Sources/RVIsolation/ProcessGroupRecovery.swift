#if os(macOS)
import Darwin
import Foundation

/// Start time and process-group id captured from the kernel after spawn.
struct ProcessGroupFact: Equatable, Sendable {
    var pgid: Int32
    var startSeconds: Int64
    var startMicroseconds: Int64
}

/// Durable process-group identity. A bare PGID is not enough to signal.
struct RecordedProcessGroup: Equatable, Sendable {
    var runtime: UUID
    var pgid: Int32
    var startSeconds: Int64
    var startMicroseconds: Int64
}

enum ProcessGroupStop: Error, Equatable, Sendable {
    /// The kernel did not answer. Do not signal.
    case queryFailed
    /// The recorded identity is not a process group RV may signal.
    case refusedIdentity
}

/// Proves a recorded process group still belongs to a workspace, then signals it.
///
/// A reused PGID has a different start time. That process is left alone.
enum ProcessGroupRecovery {
    static func capture(pid: pid_t) -> ProcessGroupFact? {
        guard pid > 1 else { return nil }
        switch lookup(pid) {
        case .found(let info):
            guard info.pbi_pid == UInt32(pid), info.pbi_pgid == UInt32(pid) else { return nil }
            return ProcessGroupFact(
                pgid: pid,
                startSeconds: Int64(info.pbi_start_tvsec),
                startMicroseconds: Int64(info.pbi_start_tvusec)
            )
        case .absent, .unavailable:
            return nil
        }
    }

    /// Signals `-pgid` only while the leader's start time still matches.
    static func terminate(
        _ group: RecordedProcessGroup
    ) -> Result<Void, ProcessGroupStop> {
        guard group.pgid > 1 else { return .failure(.refusedIdentity) }
        for _ in 0..<50 {
            switch prove(group) {
            case .absent:
                return .success(())
            case .queryFailed:
                return .failure(.queryFailed)
            case .refusedIdentity:
                return .failure(.refusedIdentity)
            case .owned:
                _ = kill(-group.pgid, SIGKILL)
            }
            usleep(10_000)
        }
        switch prove(group) {
        case .absent:
            return .success(())
        case .queryFailed:
            return .failure(.queryFailed)
        case .owned, .refusedIdentity:
            return .failure(.queryFailed)
        }
    }

    private enum Proof {
        case owned
        case absent
        case queryFailed
        case refusedIdentity
    }

    private static func prove(_ group: RecordedProcessGroup) -> Proof {
        guard group.pgid > 1 else { return .refusedIdentity }
        switch lookup(group.pgid) {
        case .absent:
            return .absent
        case .unavailable:
            return .queryFailed
        case .found(let info):
            guard info.pbi_pid == UInt32(group.pgid) else { return .queryFailed }
            let sameStart = Int64(info.pbi_start_tvsec) == group.startSeconds
                && Int64(info.pbi_start_tvusec) == group.startMicroseconds
            if sameStart == false {
                return .absent
            }
            guard info.pbi_pgid == UInt32(group.pgid) else { return .refusedIdentity }
            return .owned
        }
    }

    private enum Lookup {
        case found(proc_bsdinfo)
        case absent
        case unavailable
    }

    private static func lookup(_ pid: pid_t) -> Lookup {
        var info = proc_bsdinfo()
        errno = 0
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let wrote = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        if wrote > 0 {
            return .found(info)
        }
        if errno == ESRCH {
            return .absent
        }
        return .unavailable
    }
}
#endif
