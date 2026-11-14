import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Start time and process-group id captured from the kernel after spawn.
/// These value types are platform-independent: the journal stage machine
/// (`WorkspaceSessionLifecycle`) narrows recorded groups on every platform.
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
        capture(pid: pid, in: HostProcessTable.make())
    }

    static func capture(pid: pid_t, in table: some ProcessTable) -> ProcessGroupFact? {
        guard let pgid = ValidatedPGID(pid) else { return nil }
        switch table.lookup(pid) {
        case .found(let info):
            // A start time that does not fit is not one this records.
            guard info.pid == UInt32(pid), info.group == UInt32(pid),
                let seconds = Int64(exactly: info.startSeconds),
                let microseconds = Int64(exactly: info.startMicroseconds)
            else { return nil }
            return ProcessGroupFact(pgid: pgid, startSeconds: seconds, startMicroseconds: microseconds)
        case .absent, .unavailable:
            return nil
        }
    }

    /// Signals `-pgid` only while the leader's start time still matches.
    static func terminate(
        _ group: RecordedProcessGroup
    ) -> Result<Void, ProcessGroupStop> {
        let table = HostProcessTable.make()
        // No pgid guard: `ValidatedPGID` admits only signallable ids.
        for _ in 0..<50 {
            switch prove(group, in: table) {
            case .absent:
                return .success(())
            case .queryFailed:
                return .failure(.queryFailed)
            case .refusedIdentity:
                return .failure(.refusedIdentity)
            case .owned:
                stop(group, in: table)
            }
            usleep(10_000)
        }
        switch prove(group, in: table) {
        case .absent:
            return .success(())
        case .queryFailed:
            return .failure(.queryFailed)
        case .owned, .refusedIdentity:
            return .failure(.queryFailed)
        }
    }

    private enum Proof: Equatable {
        case owned
        case absent
        case queryFailed
        case refusedIdentity
    }

    private static func prove(_ group: RecordedProcessGroup, in table: some ProcessTable) -> Proof {
        switch table.lookup(group.pgid.rawValue) {
        case .absent:
            return .absent
        case .unavailable:
            return .queryFailed
        case .found(let info):
            guard info.pid == UInt32(group.pgid.rawValue) else { return .queryFailed }
            let sameStart = Int64(exactly: info.startSeconds) == group.startSeconds
                && Int64(exactly: info.startMicroseconds) == group.startMicroseconds
            if sameStart == false {
                return .absent
            }
            guard info.group == UInt32(group.pgid.rawValue) else { return .refusedIdentity }
            return .owned
        }
    }

    /// Called right after `prove` said `owned`.
    private static func stop(_ group: RecordedProcessGroup, in table: some ProcessTable) {
        let pgid = group.pgid.rawValue
        #if os(Linux)
        // A pidfd names one process, so a pid recycled after the proof is not
        // signalled through it. It is opened and the group proved again: a
        // match means it is the leader. The leader dies first; dead and
        // unreaped it keeps its pid, so `-pgid` is still its group. Without
        // pidfds (kernel before 5.3, glibc before 2.36, a seccomp filter)
        // this is the identity-checked `kill` macOS uses.
        switch PidFD.open(pgid) {
        case .gone:
            return  // the next proof sees it
        case .unsupported:
            break
        case .descriptor(let descriptor):
            defer { close(descriptor) }
            guard prove(group, in: table) == .owned else { return }
            _ = PidFD.signal(descriptor, SIGKILL)
        }
        #endif
        _ = kill(-pgid, SIGKILL)
    }

    #if os(macOS)
    enum Lookup {
        case found(proc_bsdinfo)
        case absent
        case unavailable
    }

    static func lookup(_ pid: pid_t) -> Lookup {
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
    #endif
}

/// `pidfd_open` and `pidfd_send_signal`, looked up at run time: glibc
/// exports them from 2.36, and a kernel before 5.3 or a seccomp filter
/// refuses them with `ENOSYS`/`EPERM`. Elsewhere (macOS) the lookup finds
/// nothing and every call is `unsupported`.
enum PidFD {
    private typealias Open = @convention(c) (pid_t, UInt32) -> Int32
    private typealias Send = @convention(c) (Int32, Int32, UnsafeMutableRawPointer?, UInt32) -> Int32

    enum Opened: Equatable {
        case descriptor(Int32)
        /// `ESRCH`: no process has the pid.
        case gone
        case unsupported
    }

    static func open(_ pid: pid_t) -> Opened {
        guard let call: Open = symbol("pidfd_open") else { return .unsupported }
        let descriptor = call(pid, 0)
        if descriptor >= 0 { return .descriptor(descriptor) }
        return errno == ESRCH ? .gone : .unsupported
    }

    static func signal(_ descriptor: Int32, _ number: Int32) -> Bool {
        guard let call: Send = symbol("pidfd_send_signal") else { return false }
        return call(descriptor, number, nil, 0) == 0
    }

    private static func symbol<Function>(_ name: String) -> Function? {
        guard let library = dlopen(nil, RTLD_NOW) else { return nil }
        defer { dlclose(library) }
        guard let address = dlsym(library, name) else { return nil }
        return unsafeBitCast(address, to: Function.self)
    }
}
