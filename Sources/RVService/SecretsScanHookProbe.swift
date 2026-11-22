import Foundation
import RVDomain
import RVEngine
import RVIsolation
import RVPolicy

/// Read-only probe: does the repository a command runs in have rv's secrets
/// pre-commit hook (`rv secrets hook install`)? It finds the hooks
/// directory the way git does, without running git: `core.hooksPath` from
/// the repository's config, then `~/.gitconfig`, then
/// `~/.config/git/config` (relative to the worktree root, `~` expanded),
/// else `hooks` in the common git dir (a linked worktree's `commondir`
/// followed). The hook counts when its `pre-commit` holds rv's block
/// marker. Files are read with a size cap; any failure reads as "not
/// installed", so a repository rv cannot read is never blocked.
///
/// Only commands that would skip or move hooks (`SecretsScanGuard.
/// skipsCommitHook`, `movesHooksPath`) and file-tool writes of a
/// `pre-commit` file reach it, so ordinary evaluations pay nothing.
enum SecretsScanHookProbe {
    static let maximumFileBytes = 1024 * 1024
    /// The whole-hook marker an older `rv secrets hook install` wrote.
    static let legacyMarker = "# rv-secrets-hook"

    /// The `pre-commit` file holding rv's block, or nil.
    static func installedHook(cwd: WorkingDirectory?, home: HomeDirectory?) -> String? {
        guard let cwd,
              let root = FilesystemLiveProbe.discoverRepositoryRoot(from: cwd.rawValue)?.rawValue,
              let gitdir = GitLiveProbe.resolvedGitDir(repoRoot: root)
        else { return nil }
        let common = commonDirectory(gitdir: gitdir)
        let hooks = hooksDirectory(root: root, common: common, home: home?.rawValue)
        let hook = hooks + "/pre-commit"
        guard let text = readCapped(hook), holdsRVBlock(text) else { return nil }
        return hook
    }

    /// Tightens an allow for a command that skips or moves the hooks of a
    /// repository with rv's hook to the commit check's stop.
    static func tighten(
        _ result: EvaluationResult, command: ShellCommand, cwd: WorkingDirectory?, home: HomeDirectory?
    ) -> EvaluationResult {
        guard result.decision == .allow, weakensHook(command, cwd: cwd, home: home) else { return result }
        return SecretsScanGuard.deny(searchText: result.matchingView.rawValue)
    }

    /// The text test first (cheap), the filesystem only when it holds.
    static func weakensHook(_ command: ShellCommand, cwd: WorkingDirectory?, home: HomeDirectory?) -> Bool {
        guard SecretsScanGuard.skipsCommitHook(command) || SecretsScanGuard.movesHooksPath(command) else {
            return false
        }
        return installedHook(cwd: cwd, home: home) != nil
    }

    static func holdsRVBlock(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == SecretGitHook.beginMarker || trimmed == legacyMarker
        }
    }

    // MARK: git layout

    private static func commonDirectory(gitdir: String) -> String {
        guard let text = readCapped(gitdir + "/commondir"),
              let line = text.split(whereSeparator: \.isNewline).first
        else { return gitdir }
        let value = line.trimmingCharacters(in: .whitespaces)
        guard value.isEmpty == false else { return gitdir }
        return value.hasPrefix("/") ? value : gitdir + "/" + value
    }

    private static func hooksDirectory(root: String, common: String, home: String?) -> String {
        var configs = [common + "/config"]
        if let home {
            configs += [home + "/.gitconfig", home + "/.config/git/config"]
        }
        for config in configs {
            guard let text = readCapped(config), let value = hooksPath(inConfig: text) else { continue }
            if value.hasPrefix("~/"), let home { return home + String(value.dropFirst()) }
            return value.hasPrefix("/") ? value : root + "/" + value
        }
        return common + "/hooks"
    }

    /// The last `core.hooksPath` in one git config file's text, or nil.
    /// Sections and keys are case-insensitive; a value may be quoted and
    /// carry a trailing `#`/`;` comment.
    static func hooksPath(inConfig text: String) -> String? {
        var inCore = false
        var found: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let header = line.dropFirst().prefix { $0 != "]" }
                inCore = header.trimmingCharacters(in: .whitespaces).lowercased() == "core"
                // `[core] hooksPath = x` on one line.
                guard inCore, let close = line.firstIndex(of: "]") else { continue }
                let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                if let value = hooksPathValue(rest) { found = value }
                continue
            }
            guard inCore, let value = hooksPathValue(line) else { continue }
            found = value
        }
        return found
    }

    private static func hooksPathValue(_ line: String) -> String? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
        guard key == "hookspath" else { return nil }
        var value = ""
        var quoted = false
        for character in line[line.index(after: equals)...] {
            if character == "\"" { quoted.toggle(); continue }
            if quoted == false, character == "#" || character == ";" { break }
            value.append(character)
        }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func readCapped(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumFileBytes + 1), data.count <= maximumFileBytes else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
