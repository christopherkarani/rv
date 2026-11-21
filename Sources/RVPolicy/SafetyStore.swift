import Foundation
import RVDomain
import RVHistory

/// Machine safety knob plus restrict-only overlay with a repo layer.
public struct SafetyStore: Sendable {
    public var configDirectory: URL

    public init(configDirectory: URL) {
        self.configDirectory = configDirectory
    }

    public var configFile: URL {
        configDirectory.appendingPathComponent("config.json", isDirectory: false)
    }

    /// Missing file or key is `normal`.
    public func loadMachine() -> SafetyLevel {
        let root = MachineConfigJSON.load(from: configFile)
        if let raw = root["safety"]?["level"]?.string,
           let level = SafetyLevel(rawValue: raw)
        {
            return level
        }
        return .normal
    }

    /// Records `config.changed` (`safety.level`) write-ahead when the level
    /// changes. `strict` is the highest level, so moving to it tightens.
    /// Written through `MachineConfigJSON.set`: a config that is not an
    /// object, or whose `safety` is not one, throws
    /// `OwnerConfigWriteError.unreadable` and nothing is written.
    public func saveMachine(_ level: SafetyLevel) throws {
        let setting = MachineConfigJSON.Setting(
            keyPath: ["safety", "level"], describe: { $0?.string ?? SafetyLevel.normal.rawValue },
            direction: { _, _ in level == .strict ? .tightening : .loosening })
        try MachineConfigJSON.set(.string(level.rawValue), for: setting, in: configFile)
    }

    /// Restrict-only: `strict` wins. Repo `normal` cannot lower machine `strict`.
    public static func merge(machine: SafetyLevel, repo: SafetyLevel?) -> SafetyLevel {
        if machine == .strict { return .strict }
        if repo == .strict { return .strict }
        return .normal
    }

    public static func loadEffective(home: HomeDirectory?, workspace: URL?) -> SafetyLevel {
        let machineConfig: SafetyLevel
        if let home {
            machineConfig = SafetyStore(
                configDirectory: RVPolicyPaths.configDirectory(home: home)
            ).loadMachine()
        } else {
            machineConfig = .normal
        }
        let document = PolicyWorkspace(home: home, workspace: workspace).documentSafetyLevel()
        return merge(machine: machineConfig, repo: document)
    }
}
