#if os(macOS)
import Darwin
import Foundation

/// Start time and process-group id captured from the kernel after spawn.
struct ProcessGroupFact: Equatable, Sendable {
    var pgid: ValidatedPGID
    var startSeconds: Int64
    var startMicroseconds: Int64
}

/// A process-group id that is safe to signal. `kill(-pgid, …)` with
/// `pgid <= 1` would hit init's group or the caller's own, so only ids
/// above 1 become values of this type. Construction is the check: code
/// holding a `ValidatedPGID` needs no further guard before `killpg`.
struct ValidatedPGID: Sendable, Equatable, Hashable {
    let rawValue: Int32

    init?(_ rawValue: Int32) {
        guard rawValue > 1 else { return nil }
        self.rawValue = rawValue
    }
}

/// Durable process-group identity. A bare PGID is not enough to signal.
struct RecordedProcessGroup: Equatable, Sendable {
    /// Owning runtime session. Provenance carried from the lifecycle log so
    /// recovery can attribute the group; `prove` intentionally does not read
    /// it. The signal decision rests on kernel identity (the pgid plus the
    /// leader's start time), which a reused pgid cannot spoof: a record
    /// naming a live group names that group no matter which runtime label
    /// it carries.
    var runtime: UUID
    var pgid: ValidatedPGID
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
        guard let pgid = ValidatedPGID(pid) else { return nil }
        switch lookup(pid) {
        case .found(let info):
            guard info.pbi_pid == UInt32(pid), info.pbi_pgid == UInt32(pid) else { return nil }
            return ProcessGroupFact(
                pgid: pgid,
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
        // No pgid guard: `ValidatedPGID` admits only signallable ids.
        for _ in 0..<50 {
            switch prove(group) {
            case .absent:
                return .success(())
            case .queryFailed:
                return .failure(.queryFailed)
            case .refusedIdentity:
                return .failure(.refusedIdentity)
            case .owned:
                _ = kill(-group.pgid.rawValue, SIGKILL)
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
        switch lookup(group.pgid.rawValue) {
        case .absent:
            return .absent
        case .unavailable:
            return .queryFailed
        case .found(let info):
            guard info.pbi_pid == UInt32(group.pgid.rawValue) else { return .queryFailed }
            let sameStart = Int64(info.pbi_start_tvsec) == group.startSeconds
                && Int64(info.pbi_start_tvusec) == group.startMicroseconds
            if sameStart == false {
                return .absent
            }
            guard info.pbi_pgid == UInt32(group.pgid.rawValue) else { return .refusedIdentity }
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
