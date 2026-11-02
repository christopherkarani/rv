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
    case forceClearThenWrite(HostAttachWrite)
    case write(HostAttachWrite)
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
                steps.append(
                    .forceClearThenWrite(
                        HostArtifacts.attach(
                            host: host,
                            layout: layout,
                            existingData: nil,
                            forceClear: true
                        )
                    )
                )
            case .write(let existingData):
                steps.append(
                    .write(
                        HostArtifacts.attach(
                            host: host,
                            layout: layout,
                            existingData: existingData,
                            forceClear: false
                        )
                    )
                )
            }
        }
        // Hosts before LaunchAgent: a launchctl miss must not skip hook wiring.
        // There is no in-process fallback: with rvd down every hook denies, so
        // setup reports a failed or skipped service step with a fix line.
        steps.append(rvdIsExecutable ? .writeLaunchAgent : .skipLaunchAgent)
        return SetupWorkPlan(steps: steps)
    }
}
