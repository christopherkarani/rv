import Foundation
import RVDomain

struct SetupWorkPlan: Equatable, Sendable {
    var steps: [SetupWorkStep]
    /// Hosts already wired before this run. A failed service step leaves
    /// them as they were; the failure output names them.
    var alreadyWired: [HookHost] = []
}

enum SetupWorkStep: Equatable, Sendable {
    case createConfigDirectory
    case writeLaunchAgent
    case skipLaunchAgent
    case skipUndetected(HookHost)
    case skipOccupied(HookHost)
    /// The operator turned rv off for this host (`rv host mode <host> off`).
    case skipOff(HookHost)
    /// The host's hook command starts an interpreter that is not runnable,
    /// so the hook would fail open: setup refuses to wire it.
    case skipRuntimeMissing(HookHost, interpreter: String)
    case forceClearThenWrite(HostAttachWrite)
    case write(HostAttachWrite)
}

enum SetupWorkPlanBuilder {
    static func make(
        installations: HostAdapterInstallationSnapshot,
        layout: OwnedPaths,
        force: Bool,
        rvdIsExecutable: Bool,
        offHosts: Set<HookHost> = [],
        missingInterpreters: Set<String> = []
    ) -> SetupWorkPlan {
        // Service before hosts: rvd must answer before setup leaves any new
        // hook in place, because a hook with no answering rvd denies every
        // agent tool call. A failed service step therefore wires nothing.
        var steps: [SetupWorkStep] = [
            .createConfigDirectory,
            rvdIsExecutable ? .writeLaunchAgent : .skipLaunchAgent,
        ]
        var alreadyWired: [HookHost] = []
        for owned in layout.hostAdapters {
            let host = owned.host
            if case .wired = installations.installation(for: host) {
                alreadyWired.append(host)
            }
            if offHosts.contains(host) {
                steps.append(.skipOff(host))
                continue
            }
            if let interpreter = AdapterRuntime.interpreter(for: host),
               missingInterpreters.contains(interpreter),
               installations.installation(for: host).wouldWrite(force: force)
            {
                steps.append(.skipRuntimeMissing(host, interpreter: interpreter))
                continue
            }
            steps.append(step(for: host, installation: installations.installation(for: host), layout: layout, force: force))
        }
        return SetupWorkPlan(steps: steps, alreadyWired: alreadyWired)
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
