@testable import RVCLI

final class RecordingSystemctl: SystemctlApplying {
    private(set) var enabled: [String] = []
    private(set) var disabled: [String] = []

    func enableNow(unit: String) throws {
        enabled.append(unit)
    }

    func disableNow(unit: String) throws {
        disabled.append(unit)
    }
}

final class FailingSystemctl: SystemctlApplying {
    func enableNow(unit _: String) throws {
        throw SystemctlError.nonZeroExit(1)
    }

    func disableNow(unit _: String) throws {
        throw SystemctlError.nonZeroExit(1)
    }
}
