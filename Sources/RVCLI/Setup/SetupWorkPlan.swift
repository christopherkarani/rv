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
        steps.append(rvdIsExecutable ? .writeLaunchAgent : .skipLaunchAgent)
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
        return SetupWorkPlan(steps: steps)
    }
}
