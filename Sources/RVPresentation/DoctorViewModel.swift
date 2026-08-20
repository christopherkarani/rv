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

/// Readiness of the in-process evaluation fallback.
public enum DoctorFallbackState: String, Equatable, Sendable {
    case ready
    case unavailable
}

/// Integrity state of the pack registry used for health decisions.
public enum DoctorPackRegistryState: String, Equatable, Sendable {
    case ready
    case broken
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
    /// Local fallback readiness.
    public var fallback: DoctorFallbackState
    /// LaunchAgent registration state.
    public var launchAgent: DoctorLaunchAgentState
    /// Sanitized operator-facing warning.
    public var warning: String?

    /// Creates the service facts for a doctor snapshot.
    public init(
        state: DoctorServiceState,
        protocolName: String,
        serviceSemver: String?,
        label: String,
        fallback: DoctorFallbackState,
        launchAgent: DoctorLaunchAgentState,
        warning: String? = nil
    ) {
        self.state = state
        self.protocolName = protocolName
        self.serviceSemver = serviceSemver
        self.label = label
        self.fallback = fallback
        self.launchAgent = launchAgent
        self.warning = warning
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

    /// Whether the registry is healthy and all day-one packs are enabled.
    public var areDayOnePacksReady: Bool {
        registry == .ready && missingDayOne.isEmpty
    }
}

/// One Host adapter fact rendered by doctor.
public struct DoctorHostView: Equatable, Sendable {
    /// Supported Host.
    public var host: SetupHostKind
    /// Installation state at the Host's owned path.
    public var state: DoctorHostState

    /// Creates a Host adapter fact.
    public init(host: SetupHostKind, state: DoctorHostState) {
        self.host = host
        self.state = state
    }
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

    /// Creates a complete doctor health model.
    public init(
        service: DoctorServiceView,
        packs: DoctorPacksView,
        hosts: [DoctorHostView],
        config: DoctorConfigState,
        grade: DoctorProtectionGrade = .hook
    ) {
        self.service = service
        self.packs = packs
        self.hosts = hosts
        self.config = config
        self.grade = grade
    }

    /// Whether doctor should return a successful exit code.
    public var isHealthy: Bool {
        config == .readable && packs.areDayOnePacksReady && service.fallback == .ready
    }
}
