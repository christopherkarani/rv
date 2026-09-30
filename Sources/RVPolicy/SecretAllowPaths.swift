import Foundation
import RVDomain

/// Load and merge `secret.allow_paths` from machine config and policy.toml.
public enum SecretAllowPaths {
    public static func merge(machine: [String], repo: [String]) -> SecretAllowPathSet {
        var seen: Set<String> = []
        var literals: [String] = []
        for path in machine + repo {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false, seen.contains(trimmed) == false else { continue }
            seen.insert(trimmed)
            literals.append(trimmed)
        }
        return SecretAllowPathSet(literals: literals)
    }

    public static func loadMachineConfig(from file: URL) -> [String] {
        let root = MachineConfigJSON.load(from: file)
        guard let values = root["secret"]?["allow_paths"]?.asArray else {
            return []
        }
        let paths = values.compactMap(\.string)
        guard paths.count == values.count else {
            return []
        }
        return paths
    }

    public static func saveMachineConfig(_ paths: [String], to file: URL) throws {
        try MachineConfigJSON.update(file: file) { root in
            var secret = root["secret"]?.asObject ?? [:]
            secret["allow_paths"] = .array(paths.map(JSONValue.string))
            root["secret"] = .object(secret)
        }
    }

    public static func loadEffective(home: HomeDirectory?, workspace: URL?) -> SecretAllowPathSet {
        var machine: [String] = []
        if let home {
            let configDir = RVPolicyPaths.configDirectory(home: home)
            machine.append(
                contentsOf: loadMachineConfig(
                    from: configDir.appendingPathComponent("config.json", isDirectory: false)
                )
            )
        }
        let documents = PolicyWorkspace(home: home, workspace: workspace).documentAllowPaths()
        return merge(machine: machine, repo: documents.literals)
    }
}
