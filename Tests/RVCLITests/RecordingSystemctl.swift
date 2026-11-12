@testable import RVCLI

final class RecordingSystemctl: SystemctlApplying {
    private(set) var enabled: [String] = []
    private(set) var disabled: [String] = []
    private(set) var restarted: [String] = []
    private(set) var started: [String] = []
    var reachable: Bool

    init(reachable: Bool = true) {
        self.reachable = reachable
    }

    func enableNow(unit: String) throws {
        enabled.append(unit)
    }

    func disableNow(unit: String) throws {
        disabled.append(unit)
    }

    func restart(unit: String, onlyIfStopped: Bool) throws {
        if onlyIfStopped {
            started.append(unit)
        } else {
            restarted.append(unit)
        }
    }

    func userManagerReachable() -> Bool {
        reachable
    }
}

final class FailingSystemctl: SystemctlApplying {
    func enableNow(unit _: String) throws {
        throw SystemctlError.nonZeroExit(1)
    }

    func disableNow(unit _: String) throws {
        throw SystemctlError.nonZeroExit(1)
    }

    func restart(unit _: String, onlyIfStopped _: Bool) throws {
        throw SystemctlError.nonZeroExit(1)
    }

    func userManagerReachable() -> Bool {
        true
    }
}

final class RecordingDirectRvd: DirectRvdLaunching {
    private(set) var events: [String] = []
    var startError: (any Error)?

    func stop(rvdPath: String) {
        events.append("stop \(rvdPath)")
    }

    func start(rvdPath: String) throws {
        if let startError { throw startError }
        events.append("start \(rvdPath)")
    }
}
