import RVDomain

/// Reachability and compatibility of the evaluation service.
public enum DoctorServiceState: String, Equatable, Sendable {
    case running
    case down
    case skew
    case notInstalled = "not-installed"
}

/// Installation state at an rv-owned Host adapter path.
///
/// Shared by setup inspection, uninstall, and doctor rendering so those
/// surfaces cannot drift apart.
public enum DoctorHostState: String, Equatable, Sendable {
    case missing
    case wired
    case occupied
    case absentFile = "absent-file"
    case broken
}

/// Readability of rv's configuration directory.
public enum DoctorConfigState: String, Equatable, Sendable {
    case readable
    case unreadable
}

/// Registration state of the on-demand LaunchAgent.
public enum DoctorLaunchAgentState: String, Equatable, Sendable {
    case loaded
    case installed
    case missing
}

/// Protection level rv can truthfully claim.
public enum DoctorProtectionGrade: String, Equatable, Sendable {
    case hook
}

/// Whether a named host has the file-tool door as well as the shell door.
public enum DoctorFileToolsState: String, Equatable, Sendable {
    case wired
    case shellOnly = "shell-only"
    case notApplicable = "n-a"
}

/// Whether this CLI can load and compile the core packs locally. Diagnostic
/// only: hooks never evaluate in-process, so a down `rvd` denies every hook
/// regardless of this state.
public enum DoctorFallbackState: String, Equatable, Sendable {
    case ready
    case unavailable
}

/// Integrity state of the pack registry used for health decisions.
public enum DoctorPackRegistryState: String, Equatable, Sendable {
    case ready
    case broken
}

/// Would the hooks trust the installed `rvd`? A static check of its bytes
/// against the active trust source (`manifest`, `sibling-pin`, `invalid`).
public struct DoctorServiceTrust: Equatable, Sendable {
    public var source: String
    public var satisfied: Bool
    /// Why the hooks would reject the installed rvd; nil when satisfied.
    public var reason: String?

    public init(source: String, satisfied: Bool, reason: String?) {
        self.source = source
        self.satisfied = satisfied
        self.reason = reason
    }
}

/// Service facts rendered by doctor.
public struct DoctorServiceView: Equatable, Sendable {
    /// Current service reachability and compatibility.
    public var state: DoctorServiceState
    /// Negotiated IPC protocol name.
    public var protocolName: String
    /// Service version observed from the peer, when one replied.
    public var serviceSemver: String?
    /// Mach service label.
    public var label: String
    /// Local core-pack readiness (not a hook fallback; there is none).
    public var fallback: DoctorFallbackState
    /// LaunchAgent registration state.
    public var launchAgent: DoctorLaunchAgentState
    /// Sanitized operator-facing warning.
    public var warning: String?
    /// One-line repair hint when the service is not running cleanly.
    public var fix: String?
    /// Installed-rvd trust verdict; nil when not evaluated.
    public var trust: DoctorServiceTrust?

    /// Creates the service facts for a doctor snapshot.
    public init(
        state: DoctorServiceState,
        protocolName: String,
        serviceSemver: String?,
        label: String,
        fallback: DoctorFallbackState,
        launchAgent: DoctorLaunchAgentState,
        warning: String? = nil,
        fix: String? = nil,
        trust: DoctorServiceTrust? = nil
    ) {
        self.trust = trust
        self.state = state
        self.protocolName = protocolName
        self.serviceSemver = serviceSemver
        self.label = label
        self.fallback = fallback
        self.launchAgent = launchAgent
        self.warning = warning
        self.fix = fix
    }
}

/// Pack facts derived from enabled IDs and registry integrity.
public struct DoctorPacksView: Equatable, Sendable {
    /// Enabled pack IDs in stable order.
    public var enabled: [PackID]
    /// Pack registry integrity.
    public var registry: DoctorPackRegistryState

    /// Creates pack facts and normalizes enabled-pack ordering.
    public init(
        enabled: [PackID],
        registry: DoctorPackRegistryState
    ) {
        self.enabled = enabled.sorted { $0.rawValue < $1.rawValue }
        self.registry = registry
    }

    /// Day-one pack IDs that are not enabled.
    public var missingDayOne: [PackID] {
        dayOnePackIDs.filter { enabled.contains($0) == false }
    }

    /// Enabled packs outside the day-one set.
    public var extrasEnabled: [PackID] {
        enabled.filter { dayOnePackIDs.contains($0) == false }
    }

    /// Enabled day-one packs (stable order).
    public var dayOneEnabled: [PackID] {
        dayOnePackIDs.filter { enabled.contains($0) }
    }

    /// Whether the registry is healthy and all day-one packs are enabled.
    public var areDayOnePacksReady: Bool {
        registry == .ready && missingDayOne.isEmpty
    }
}

/// One Host adapter fact rendered by doctor.
public struct DoctorHostView: Equatable, Sendable {
    /// Supported Host.
    public var host: HookHost
    /// Installation state at the Host's owned path.
    public var state: DoctorHostState
    /// File-tool wiring for Claude / Cursor / Grok. Other hosts are not applicable.
    public var fileTools: DoctorFileToolsState

    /// Creates a Host adapter fact.
    public init(
        host: HookHost,
        state: DoctorHostState,
        fileTools: DoctorFileToolsState = .notApplicable
    ) {
        self.host = host
        self.state = state
        self.fileTools = fileTools
    }
}

/// Counts behind `rv workspace leftovers`.
public struct DoctorLeftoversSummary: Equatable, Sendable {
    /// Workspace sessions the lifecycle log never closed.
    public var sessions: Int
    /// Attached rv images no live host owns; nil when `hdiutil info` failed.
    public var strandedImages: Int?
    /// rv image files in the temporary directory that nothing has attached.
    public var unattachedImageFiles: Int

    /// Creates leftover counts.
    public init(sessions: Int, strandedImages: Int?, unattachedImageFiles: Int) {
        self.sessions = sessions
        self.strandedImages = strandedImages
        self.unattachedImageFiles = unattachedImageFiles
    }

    /// Whether every count is known to be zero.
    public var isEmpty: Bool {
        sessions == 0 && strandedImages == 0 && unattachedImageFiles == 0
    }
}

/// How badly an install problem breaks hooks.
public enum DoctorProblemSeverity: String, Equatable, Sendable {
    /// Hooks may still work; worth fixing.
    case warn
    /// Hooks are, or will be, denied until this is fixed.
    case fail
}

/// One install/runtime problem doctor found, with a copy-pasteable repair.
public struct DoctorProblem: Equatable, Sendable {
    /// Stable machine id (e.g. `launchd-domain`).
    public var id: String
    /// Severity used for exit status and ink.
    public var severity: DoctorProblemSeverity
    /// One-line description of what is wrong.
    public var summary: String
    /// One-line repair hint.
    public var fix: String

    /// Creates a doctor problem row.
    public init(id: String, severity: DoctorProblemSeverity, summary: String, fix: String) {
        self.id = id
        self.severity = severity
        self.summary = summary
        self.fix = fix
    }
}

/// Workspace leftovers as doctor reports them. Informational: never grades health.
public enum DoctorLeftoversView: Equatable, Sendable {
    /// Contained workspaces exist only on macOS.
    case notApplicable
    /// Leftover counts on a platform with contained workspaces.
    case summary(DoctorLeftoversSummary)
}

/// Complete read-only health model for doctor output.
public struct DoctorViewModel: Equatable, Sendable {
    /// Service health facts.
    public var service: DoctorServiceView
    /// Pack health facts.
    public var packs: DoctorPacksView
    /// Host adapter facts in display order.
    public var hosts: [DoctorHostView]
    /// Configuration-directory readability.
    public var config: DoctorConfigState
    /// Truthful protection grade.
    public var grade: DoctorProtectionGrade
    /// Effective safety posture.
    public var safety: SafetyLevel
    /// Whether the denial ledger is writing.
    public var blocksEnabled: Bool
    /// Workspace leftovers, when the caller probed for them.
    public var leftovers: DoctorLeftoversView?
    /// Install/runtime problems in display order; empty when none were found.
    public var problems: [DoctorProblem]

    /// Creates a complete doctor health model.
    public init(
        service: DoctorServiceView,
        packs: DoctorPacksView,
        hosts: [DoctorHostView],
        config: DoctorConfigState,
        grade: DoctorProtectionGrade = .hook,
        safety: SafetyLevel = .normal,
        blocksEnabled: Bool = true,
        leftovers: DoctorLeftoversView? = nil,
        problems: [DoctorProblem] = []
    ) {
        self.service = service
        self.packs = packs
        self.hosts = hosts
        self.config = config
        self.grade = grade
        self.safety = safety
        self.blocksEnabled = blocksEnabled
        self.leftovers = leftovers
        self.problems = problems
    }

    /// Whether doctor should return a successful exit code. Graded from
    /// the worst component: the service must be running (down, skew, and
    /// not-installed all fail: hooks have no in-process fallback), local
    /// core packs must load, packs must be ready, config readable, and no
    /// install problem may be failing. Host wiring alone does not grade
    /// health (setup is the remedy).
    public var isHealthy: Bool {
        service.state == .running
            && service.fallback == .ready
            && config == .readable
            && packs.areDayOnePacksReady
            && problems.allSatisfy { $0.severity != .fail }
    }
}
