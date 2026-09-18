import RVDomain
import RVPresentation

/// HOME pack enablement. A failed read is unreadable — never invent IDs from rvd.
enum OperatorPacks: Sendable, Equatable {
    case home([PackID])
    case unreadable
}

/// LaunchAgent presence. Unknown keeps down from becoming not-installed.
enum LaunchAgentFact: Sendable, Equatable {
    case observed(DoctorLaunchAgentState)
    case unknown
}

/// Already-inspected operator facts. Projection is pure.
struct OperatorInputs: Sendable {
    var diagnostics: ServiceDiagnosticResult
    var launchAgent: LaunchAgentFact
    var packs: OperatorPacks
    var hosts: HostAdapterInstallationSnapshot
}

/// One operator view: service health, HOME packs, Host adapter installation.
struct OperatorSnapshot: Sendable, Equatable {
    var health: ServiceHealth
    var packs: OperatorPacks
    var hosts: HostAdapterInstallationSnapshot

    static func project(_ inputs: OperatorInputs) -> OperatorSnapshot {
        OperatorSnapshot(
            health: ServiceHealth.inspect(inputs.diagnostics, launchAgent: inputs.launchAgent),
            packs: inputs.packs,
            hosts: inputs.hosts
        )
    }
}
