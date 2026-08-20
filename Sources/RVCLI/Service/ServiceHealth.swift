import RVDomain
import RVIPC
import RVPresentation

/// Inspected rvd health derived from diagnostics and optional LaunchAgent presence.
enum ServiceHealth: Equatable, Sendable {
    case reachable(Reachable)
    case down(Local)
    case notInstalled(Local)
    case skew(reason: ServiceSkewReason?, local: Local)
    case requestFailed(failure: ServiceDiagnosticFailure, local: Local)

    struct Reachable: Equatable, Sendable {
        var snapshot: DoctorSnapshotReply
        var localCorePacksReady: Bool
        var launchAgent: DoctorLaunchAgentState
    }

    struct Local: Equatable, Sendable {
        var corePacksReady: Bool
        var serviceSemver: String?
        var launchAgent: DoctorLaunchAgentState
    }
}

extension ServiceHealth {
    /// Derives health from diagnostics. Down stays down when LaunchAgent is unknown.
    static func inspect(_ diagnostics: ServiceDiagnosticResult) -> ServiceHealth {
        inspect(diagnostics, launchAgent: .omitted)
    }

    /// Derives health from diagnostics and observed LaunchAgent installed/loaded.
    static func inspect(
        _ diagnostics: ServiceDiagnosticResult,
        launchAgentInstalled: Bool,
        launchAgentLoaded: Bool
    ) -> ServiceHealth {
        inspect(
            diagnostics,
            launchAgent: .observed(
                launchAgentState(installed: launchAgentInstalled, loaded: launchAgentLoaded)
            )
        )
    }

    var launchAgent: DoctorLaunchAgentState {
        switch self {
        case .reachable(let facts):
            facts.launchAgent
        case .down(let local), .notInstalled(let local):
            local.launchAgent
        case .skew(_, let local), .requestFailed(_, let local):
            local.launchAgent
        }
    }

    var fallbackReady: Bool {
        switch self {
        case .reachable(let facts):
            facts.localCorePacksReady
        case .down(let local), .notInstalled(let local):
            local.corePacksReady
        case .skew(_, let local), .requestFailed(_, let local):
            local.corePacksReady
        }
    }

    var enabledPacks: [PackID] {
        switch self {
        case .reachable(let facts):
            facts.snapshot.packsEnabled
        case .down(let local), .notInstalled(let local),
             .skew(_, let local), .requestFailed(_, let local):
            local.corePacksReady ? dayOnePackIDs : []
        }
    }

    var packCheckReady: Bool {
        switch self {
        case .reachable(let facts):
            facts.snapshot.checks.first { $0.id == "packs" }?.status == .ok
        case .down(let local), .notInstalled(let local),
             .skew(_, let local), .requestFailed(_, let local):
            local.corePacksReady
        }
    }
}

extension ServiceHealth {
    private enum LaunchAgentInput: Equatable {
        case omitted
        case observed(DoctorLaunchAgentState)
    }

    private static func launchAgentState(
        installed: Bool,
        loaded: Bool
    ) -> DoctorLaunchAgentState {
        if loaded {
            .loaded
        } else if installed {
            .installed
        } else {
            .missing
        }
    }

    private static func inspect(
        _ diagnostics: ServiceDiagnosticResult,
        launchAgent: LaunchAgentInput
    ) -> ServiceHealth {
        let agent: DoctorLaunchAgentState
        switch launchAgent {
        case .omitted:
            agent = .missing
        case .observed(let observed):
            agent = observed
        }

        switch diagnostics {
        case .xpc(let snapshot, let localCorePacksReady):
            return inspect(
                snapshot: snapshot,
                localCorePacksReady: localCorePacksReady,
                launchAgent: agent
            )
        case .local(let diagnostic):
            let local = Local(
                corePacksReady: diagnostic.corePacksReady,
                serviceSemver: diagnostic.serviceSemver,
                launchAgent: agent
            )
            switch diagnostic.cause {
            case .down:
                if case .observed(.missing) = launchAgent {
                    return .notInstalled(local)
                }
                return .down(local)
            case .skew(let reason):
                return .skew(reason: reason, local: local)
            case .requestFailed(let failure):
                return .requestFailed(failure: failure, local: local)
            }
        }
    }

    private static func inspect(
        snapshot: DoctorSnapshotReply,
        localCorePacksReady: Bool,
        launchAgent: DoctorLaunchAgentState
    ) -> ServiceHealth {
        let local = Local(
            corePacksReady: localCorePacksReady,
            serviceSemver: snapshot.serviceSemver,
            launchAgent: launchAgent
        )
        switch snapshot.state {
        case .running, .idleExitArmed:
            .reachable(
                Reachable(
                    snapshot: snapshot,
                    localCorePacksReady: localCorePacksReady,
                    launchAgent: launchAgent
                )
            )
        case .down:
            .down(local)
        case .skew:
            .skew(reason: nil, local: local)
        }
    }
}
