import Foundation
import RVDomain

struct SetupWorkPlan: Equatable, Sendable {
    var steps: [SetupWorkStep]
}

enum SetupWorkStep: Equatable, Sendable {
    case createConfigDirectory
    case writeLaunchAgent
    case skipLaunchAgent
    case skipUndetected(HookHost)
    case skipOccupied(HookHost)
    /// The operator turned rv off for this host (`rv host mode <host> off`).
    case skipOff(HookHost)
    case forceClearThenWrite(HostAttachWrite)
    case write(HostAttachWrite)
}

enum SetupWorkPlanBuilder {
    static func make(
        installations: HostAdapterInstallationSnapshot,
        layout: OwnedPaths,
        force: Bool,
        rvdIsExecutable: Bool,
        offHosts: Set<HookHost> = []
    ) -> SetupWorkPlan {
        var steps: [SetupWorkStep] = [.createConfigDirectory]
        for owned in layout.hostAdapters {
            let host = owned.host
            if offHosts.contains(host) {
                steps.append(.skipOff(host))
                continue
            }
            steps.append(step(for: host, installation: installations.installation(for: host), layout: layout, force: force))
        }
        // Hosts before LaunchAgent: a launchctl miss must not skip hook wiring.
        // There is no in-process fallback: with rvd down every hook denies, so
        // setup reports a failed or skipped service step with a fix line.
        steps.append(rvdIsExecutable ? .writeLaunchAgent : .skipLaunchAgent)
        return SetupWorkPlan(steps: steps)
    }

    /// The wiring step for one host. `rv setup` folds it per host; `rv host
    /// mode` re-wires a single host through it.
    static func step(
        for host: HookHost,
        installation: HostAdapterInstallation,
        layout: OwnedPaths,
        force: Bool
    ) -> SetupWorkStep {
        switch installation.setupPlan(force: force) {
        case .skipUndetected:
            .skipUndetected(host)
        case .skipOccupied:
            .skipOccupied(host)
        case .forceClearThenWrite:
            .forceClearThenWrite(
                HostArtifacts.attach(host: host, layout: layout, existingData: nil, forceClear: true)
            )
        case .write(let existingData):
            .write(
                HostArtifacts.attach(host: host, layout: layout, existingData: existingData, forceClear: false)
            )
        }
    }
}
