import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import RVDomain
import RVPolicy

/// When rv's MCP gateway is in use, agent writes to host MCP configs
/// (`MCPHostConfigPaths`) deny on both doors: the shell door through the
/// guard attached to the probed filesystem context (RVEngine judges it),
/// the file-tool door here.
///
/// In use means rv's `mcp.json` exists in `~/.config/rv` (any `lstat`
/// failure other than "no such file" counts, fail closed), or the
/// organization's managed policy carries MCP rules or cannot be loaded.
enum MCPHostConfigDoor {
    static func hostConfigGuard(home: HomeDirectory?, managed: ManagedPolicyState) -> MCPHostConfigGuard? {
        guard gatewayInUse(home: home, managed: managed) else { return nil }
        return MCPHostConfigGuard(resolvedAliases: resolvedAliases(home: homePath(home)))
    }

    static func gatewayInUse(home: HomeDirectory?, managed: ManagedPolicyState) -> Bool {
        switch managed {
        case .invalid:
            return true
        case .active(let bundle):
            if bundle.policy.mcp != ManagedPolicy.MCP() { return true }
        case .none:
            break
        }
        guard let home else { return false }
        let path = RVPolicyPaths.configDirectory(home: home)
            .appendingPathComponent(MCPHostConfigPaths.gatewayConfigFileName, isDirectory: false).path
        var info = stat()
        if lstat(path, &info) == 0 { return true }
        return errno != ENOENT && errno != ENOTDIR
    }

    /// Where the fixed guarded files really are when a dotfiles manager
    /// made one a symlink: editing the target edits the config.
    static func resolvedAliases(home: String) -> [String] {
        MCPHostConfigPaths.fixedFiles(home: home).compactMap { file in
            guard let resolved = SecretPathCandidateResolver.posixRealpath(file), resolved != file else { return nil }
            return resolved
        }
    }

    /// File door: whether an Edit/Write of `typed` lands on a host MCP
    /// config, as typed, as resolved, or as a guarded file's resolved alias.
    static func protects(
        _ typed: String, guard guarded: MCPHostConfigGuard, home: HomeDirectory?, cwd: WorkingDirectory?
    ) -> Bool {
        let homePath = homePath(home)
        guard let lexical = WiringPathGuard.absolute(typed, home: homePath, cwd: cwd) else {
            // A relative path with no cwd cannot be placed: judge the shape.
            return MCPHostConfigPaths.isGuarded("/" + typed, home: homePath)
        }
        let homes = Set([homePath, SecretPathCandidateResolver.posixRealpath(homePath) ?? homePath])
        let candidates = [lexical, SecretPathCandidateResolver.resolvedPath(lexical)].compactMap { $0 }
        for candidate in candidates {
            if homes.contains(where: { MCPHostConfigPaths.isGuarded(candidate, home: $0) }) { return true }
            if guarded.resolvedAliases.contains(where: { candidate == $0 || candidate.hasPrefix($0 + "/") }) {
                return true
            }
        }
        return false
    }

    static func deny(path: String) -> EvaluationResult {
        let ruleID = MCPHostConfigPaths.ruleID
        return EvaluationResult(
            outcome: .deny(
                Deny(ruleID: ruleID, reason: MCPHostConfigPaths.reason),
                matched: RuleMatch(
                    ruleID: ruleID, severity: .high, reason: MCPHostConfigPaths.reason,
                    regex: nil, matchedText: path, searchText: path
                )
            ),
            matchingView: MatchingView(path)
        )
    }

    private static func homePath(_ home: HomeDirectory?) -> String {
        home?.rawValue ?? FileManager.default.homeDirectoryForCurrentUser.path
    }
}
