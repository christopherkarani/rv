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
    case forceClearThenWrite(HookHost)
    case write(HookHost, existingData: Data?)
}

enum SetupWorkPlanBuilder {
    static func make(
        installations: HostAdapterInstallationSnapshot,
        layout: OwnedPaths,
        force: Bool,
        rvdIsExecutable: Bool
    ) -> SetupWorkPlan {
        var steps: [SetupWorkStep] = [.createConfigDirectory]
        for owned in layout.hostAdapters {
            let host = owned.host
            switch installations.installation(for: host).setupPlan(force: force) {
            case .skipUndetected:
                steps.append(.skipUndetected(host))
            case .skipOccupied:
                steps.append(.skipOccupied(host))
            case .forceClearThenWrite:
                steps.append(.forceClearThenWrite(host))
            case .write(let existingData):
                steps.append(.write(host, existingData: existingData))
            }
        }
        // Hosts before LaunchAgent: a launchctl miss must not skip hook wiring.
        // Hooks still evaluate in-process when rvd is down.
        steps.append(rvdIsExecutable ? .writeLaunchAgent : .skipLaunchAgent)
        return SetupWorkPlan(steps: steps)
    }
}
