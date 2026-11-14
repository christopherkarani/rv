import Foundation
import RVDomain
import RVHistory

public enum SafetyStoreError: Error, Sendable, Equatable {
    case invalidFile
}

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
    public func saveMachine(_ level: SafetyLevel) throws {
        let audit: MachineConfigJSON.ChangeEvent = { before, _ in
            let prior = before["safety"]?["level"]?.string ?? SafetyLevel.normal.rawValue
            guard prior != level.rawValue else { return nil }
            return ConfigChangeAudit.setting(
                "safety.level", from: prior, to: level.rawValue,
                direction: level == .strict ? .tightening : .loosening)
        }
        try MachineConfigJSON.update(file: configFile, audit: audit) { root in
            var safety = root["safety"]?.asObject ?? [:]
            safety["level"] = .string(level.rawValue)
            root["safety"] = .object(safety)
        }
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
