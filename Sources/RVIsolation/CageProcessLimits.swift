import RVDomain

/// The kernel limits and wall-clock deadline one caged process tree
/// starts with, resolved from the operator's `limits` policy.
///
/// `rv-pty-claim` applies these in the leader before it execs
/// `sandbox-exec` (posix_spawn cannot set rlimits). Each cap only lowers:
/// the helper sets the hard limit to `min(cap, inherited hard)` and the
/// soft limit to `min(inherited soft, new hard)`, so nothing is raised
/// above what the host already had. A limit the helper cannot apply
/// stops it before exec: the runtime never starts.
///
/// Left out on purpose:
/// - `RLIMIT_NPROC`: on Darwin the kernel compares it with the count of
///   every process the uid owns, not the cage's own tree. A cap would
///   fail forks in the cage whenever the user's other processes are
///   numerous, and would not bound the cage on its own.
/// - `RLIMIT_AS` / `RLIMIT_DATA` / `RLIMIT_RSS`: Darwin does not enforce
///   them for mmap-backed memory, so they would promise a bound that
///   does not hold. Memory sizing is a VM backend concern.
struct CageProcessLimits: Sendable, Equatable {
    /// `RLIMIT_NOFILE` hard cap when the policy sets none.
    static let defaultOpenFiles: UInt64 = 65_536
    /// `RLIMIT_FSIZE` hard cap when the policy sets none: 64 GiB.
    static let defaultFileSizeBytes: UInt64 = 1 << 36
    /// The leader's out-of-host watchdog fires this long after the host's
    /// own deadline, so a live host always records the timeout first and
    /// the watchdog only matters when the host is gone.
    static let watchdogGraceSeconds: UInt64 = 5

    var openFiles: UInt64
    var fileSizeBytes: UInt64
    /// Nil leaves `RLIMIT_CPU` as inherited.
    var cpuSeconds: UInt64?
    /// Wall-clock lifetime. Nil runs without a deadline.
    var timeoutSeconds: UInt64?

    /// Defaults only: core dumps off, descriptor and file-size caps, no
    /// CPU cap, no deadline. What every launch gets without a policy.
    static let standard = CageProcessLimits(policy: nil)

    init(policy: RuntimeProcessLimits?) {
        openFiles = policy?.openFiles ?? Self.defaultOpenFiles
        fileSizeBytes = policy?.fileSizeBytes ?? Self.defaultFileSizeBytes
        cpuSeconds = policy?.cpuSeconds
        timeoutSeconds = policy?.timeoutSeconds
    }

    /// The deadline for one launch. The policy value is both the default
    /// and a ceiling: a request may shorten it, never extend it, so an
    /// over-long request runs with the policy value.
    func withRequestedTimeout(_ requested: UInt64?) -> CageProcessLimits {
        var resolved = self
        switch (requested, timeoutSeconds) {
        case (nil, _):
            break
        case (let requested?, nil):
            resolved.timeoutSeconds = requested
        case (let requested?, let ceiling?):
            resolved.timeoutSeconds = min(requested, ceiling)
        }
        return resolved
    }

    /// The same caps with no deadline: admission one-shots run under the
    /// owning runtime's lifetime, not a clock of their own.
    var withoutDeadline: CageProcessLimits {
        var resolved = self
        resolved.timeoutSeconds = nil
        return resolved
    }

    /// `rv-pty-claim` options, in a fixed order. Core dumps are always
    /// disabled first. `injectFailure` is the test seam for a limit the
    /// kernel refuses; production never sets it.
    func helperArguments(injectFailure: Bool = false) -> [String] {
        var arguments = [
            "--rlimit=core:0",
            "--rlimit=nofile:\(openFiles)",
            "--rlimit=fsize:\(fileSizeBytes)",
        ]
        if let cpuSeconds {
            arguments.append("--rlimit=cpu:\(cpuSeconds)")
        }
        if let timeoutSeconds {
            arguments.append("--deadline-seconds=\(timeoutSeconds + Self.watchdogGraceSeconds)")
        }
        if injectFailure {
            arguments.append("--rlimit-fault")
        }
        return arguments
    }
}
