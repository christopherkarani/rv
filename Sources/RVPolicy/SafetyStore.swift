import Foundation
import RVDomain

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
        if let safety = root["safety"] as? [String: Any],
           let raw = safety["level"] as? String,
           let level = SafetyLevel(rawValue: raw)
        {
            return level
        }
        return .normal
    }

    public func saveMachine(_ level: SafetyLevel) throws {
        try MachineConfigJSON.update(file: configFile) { root in
            var safety = root["safety"] as? [String: Any] ?? [:]
            safety["level"] = level.rawValue
            root["safety"] = safety
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
        let machinePolicy = loadDocumentLevel(
            home: home,
            workspace: nil,
            machine: true
        )
        let machine = merge(machine: machineConfig, repo: machinePolicy)
        let repo = loadDocumentLevel(home: home, workspace: workspace, machine: false)
        return merge(machine: machine, repo: repo)
    }

    private static func loadDocumentLevel(
        home: HomeDirectory?,
        workspace: URL?,
        machine: Bool
    ) -> SafetyLevel? {
        do {
            if machine {
                guard let home else { return nil }
                return try TypedRuleStore(
                    baseDirectory: RVPolicyPaths.configDirectory(home: home)
                ).loadMachineDocument().safetyLevel
            }
            guard let workspace else { return nil }
            return try TypedRuleStore(baseDirectory: workspace)
                .loadRepoDocument(workspace: workspace).safetyLevel
        } catch {
            return nil
        }
    }
}
