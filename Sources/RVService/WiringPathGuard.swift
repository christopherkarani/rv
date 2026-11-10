import Foundation
import RVDomain
import RVPolicy

/// File-tool door: Edit/Write to rv's own wiring (`RVWiringPaths`) denies.
///
/// The typed path is judged lexically, then as the filesystem resolves it
/// (realpath, or the deepest existing ancestor for a file about to be
/// created), then against the resolved location of each fixed wiring file
/// (a dotfiles manager may make `~/.claude/settings.json` a symlink to the
/// file the agent is editing).
///
/// Project-level host files (`<repo>/.claude/settings.json`, ...) are not
/// rv's: `rv setup` only wires the home-level ones. They are protected only
/// when rv's hook is already wired into them (the file names an rv adapter
/// or the legacy `hook --host` command), so removing that wiring is denied
/// while ordinary project settings edits stay allowed.
enum WiringPathGuard {
    static func protects(_ typed: String, home: HomeDirectory?, cwd: WorkingDirectory?) -> Bool {
        let homePath = home?.rawValue ?? FileManager.default.homeDirectoryForCurrentUser.path
        guard let lexical = absolute(typed, home: homePath, cwd: cwd) else { return false }
        let homes = Set([homePath, SecretPathCandidateResolver.posixRealpath(homePath) ?? homePath])
        if homes.contains(where: { RVWiringPaths.matches(lexical, home: $0) }) { return true }
        let resolved = SecretPathCandidateResolver.resolvedPath(lexical)
        if let resolved {
            if homes.contains(where: { RVWiringPaths.matches(resolved, home: $0) }) { return true }
            let fixed = RVWiringPaths.fixedFiles(home: homePath) + extraSymlinkTargets(home: homePath)
            if fixed.contains(where: { SecretPathCandidateResolver.posixRealpath($0) == resolved }) { return true }
        }
        return [lexical, resolved].compactMap { $0 }.contains(where: isWiredProjectHostFile)
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

    /// Binaries and units commonly symlinked into a build tree.
    private static func extraSymlinkTargets(home: String) -> [String] {
        ["rv", "rv-cli", "rvd"].map { home + "/.local/bin/" + $0 } + [
            home + "/Library/LaunchAgents/dev.rv.evaluate.plist",
            home + "/.config/systemd/user/dev.rv.evaluate.service",
        ]
    }

    /// Host config shapes that can carry a hook registration.
    private static let hostConfigShapes: [[String]] = [
        [".claude", "settings.json"],
        [".claude", "settings.local.json"],
        [".cursor", "hooks.json"],
        [".codex", "hooks.json"],
        [".gemini", "settings.json"],
        [".gemini", "config", "hooks.json"],
    ]

    private static let wiringMarkers = ["rv-guard", "hook --host"]
    private static let maxConfigBytes = 1 << 20

    private static func isWiredProjectHostFile(_ path: String) -> Bool {
        let components = path.split(separator: "/").map { foldedPathComponent(String($0)) }
        let shaped = hostConfigShapes.contains { shape in
            let folded = shape.map(foldedPathComponent)
            return components.count >= folded.count && Array(components.suffix(folded.count)) == folded
        }
        guard shaped,
              let handle = FileHandle(forReadingAtPath: path),
              let data = try? handle.read(upToCount: maxConfigBytes)
        else { return false }
        try? handle.close()
        let text = String(decoding: data, as: UTF8.self)
        return wiringMarkers.contains { text.contains($0) }
    }

    /// Absolute, lexically collapsed spelling; nil for a relative path
    /// with no cwd to anchor it.
    private static func absolute(_ typed: String, home: String, cwd: WorkingDirectory?) -> String? {
        var path = typed.trimmingCharacters(in: .whitespacesAndNewlines)
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
