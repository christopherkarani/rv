import Foundation
import RVDomain
import RVPolicy

/// File-tool door: Edit/Write to rv's own wiring (`RVWiringPaths`) denies.
///
/// The typed path is judged lexically, then as the filesystem resolves it
/// (realpath, or the deepest existing ancestor for a file about to be
/// created), then against the resolved location of each fixed wiring file
/// (a dotfiles manager may make `~/.claude/settings.json` a symlink to the
/// file the agent is editing), then by inode (a hard link to one).
///
/// Host settings files that can disable or override hooks
/// (`RVWiringPaths.isHostSettingsFile`: project and local
/// `.claude/settings*.json`, `.codex/config.toml`, ...) deny at every
/// scope, whether or not rv's hook is wired into them yet: a project file
/// with no rv marker can still carry `disableAllHooks`.
enum WiringPathGuard {
    static func protects(_ typed: String, home: HomeDirectory?, cwd: WorkingDirectory?) -> Bool {
        let homePath = home?.rawValue ?? FileManager.default.homeDirectoryForCurrentUser.path
        guard let lexical = absolute(typed, home: homePath, cwd: cwd) else { return false }
        let homes = Set([homePath, SecretPathCandidateResolver.posixRealpath(homePath) ?? homePath])
        if homes.contains(where: { RVWiringPaths.matches(lexical, home: $0) }) { return true }
        let resolved = SecretPathCandidateResolver.resolvedPath(lexical)
        if let resolved {
            if homes.contains(where: { RVWiringPaths.matches(resolved, home: $0) }) { return true }
            let fixed = RVWiringPaths.fixedFiles(home: homePath)
            if fixed.contains(where: { SecretPathCandidateResolver.posixRealpath($0) == resolved }) { return true }
        }
        if homes.contains(where: { RVWiringPaths.sharesInodeWithWiring(lexical, home: $0) }) { return true }
        return [lexical, resolved].compactMap { $0 }.contains(where: RVWiringPaths.isHostSettingsFile)
    }

    static func deny(path: String) -> EvaluationResult {
        let ruleID = RVWiringPaths.ruleID
        let matchingView = MatchingView(path)
        return EvaluationResult(
            outcome: .deny(
                Deny(ruleID: ruleID, reason: RVWiringPaths.reason),
                matched: RuleMatch(
                    ruleID: ruleID, severity: .high, reason: RVWiringPaths.reason,
                    regex: nil, matchedText: path, searchText: path
                )
            ),
            matchingView: matchingView
        )
    }

    /// Absolute, lexically collapsed spelling; nil for a relative path
    /// with no cwd to anchor it.
    static func absolute(_ typed: String, home: String, cwd: WorkingDirectory?) -> String? {
        var path = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .expanded(let expanded) = expandTildeUser(path) { path = expanded }
        for alias in ["~", "$HOME", "${HOME}"] {
            if path == alias { path = home }
            else if path.hasPrefix(alias + "/") { path = home + String(path.dropFirst(alias.count)) }
        }
        if path.hasPrefix("/") == false {
            guard let cwd else { return nil }
            path = cwd.rawValue + "/" + path
        }
        var parts: [Substring] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { _ = parts.popLast(); continue }
            parts.append(component)
        }
        return "/" + parts.joined(separator: "/")
    }
}
