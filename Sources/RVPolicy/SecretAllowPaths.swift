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
        guard let secret = root["secret"] as? [String: Any],
              let paths = secret["allow_paths"] as? [String]
        else {
            return []
        }
        return paths
    }

    public static func saveMachineConfig(_ paths: [String], to file: URL) throws {
        try MachineConfigJSON.update(file: file) { root in
            var secret = root["secret"] as? [String: Any] ?? [:]
            secret["allow_paths"] = paths
            root["secret"] = secret
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
            if let document = try? TypedRuleStore(baseDirectory: configDir).loadMachineDocument() {
                machine.append(contentsOf: document.allowPaths)
            }
        }
        var repo: [String] = []
        if let workspace,
           let document = try? TypedRuleStore(baseDirectory: workspace).loadRepoDocument(workspace: workspace)
        {
            repo.append(contentsOf: document.allowPaths)
        }
        return merge(machine: machine, repo: repo)
    }
}
