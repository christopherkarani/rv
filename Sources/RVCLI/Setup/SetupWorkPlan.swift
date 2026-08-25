import Foundation
import RVPresentation

/// Ordered setup steps derived from inspection and `--force`.
/// Building a plan performs no writes, launchctl, or analytics.
struct SetupWorkPlan: Equatable, Sendable {
    var steps: [SetupWorkStep]

    /// Slot kind this plan would report if every write succeeded.
    /// Not a `SetupReport`: `wrote` is observed only after interpret.
    func predictedKind(for host: SetupHostKind) -> SetupSlotKind {
        for step in steps {
            switch step {
            case .skipOccupied(let stepHost):
                if stepHost == host { return .occupied }
            case .forceClearThenWrite(let stepHost):
                if stepHost == host { return .wired }
            case .write(let stepHost, existingData: _):
                if stepHost == host { return .wired }
            case .skipUndetected(let stepHost):
                if stepHost == host { return .pending }
            case .createConfigDirectory, .writeLaunchAgent, .skipLaunchAgent:
                break
            }
        }
        return .pending
    }
}

enum SetupWorkStep: Equatable, Sendable {
    case createConfigDirectory
    case writeLaunchAgent
    case skipLaunchAgent
    case skipUndetected(SetupHostKind)
    case skipOccupied(SetupHostKind)
    case forceClearThenWrite(SetupHostKind)
    case write(SetupHostKind, existingData: Data?)
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
