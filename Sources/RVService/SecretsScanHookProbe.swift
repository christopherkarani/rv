import Foundation
import RVDomain
import RVEngine
import RVIsolation
import RVPolicy
import Synchronization

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
/// `SecretsScanGuard.weakensScan` asks it only for a command that could
/// skip, move or replace hooks (for the repository each command acts on,
/// `cd`/`-C`/`--git-dir` followed), and a file-tool write of a `pre-commit`
/// file asks it too, so ordinary evaluations pay nothing.
enum SecretsScanHookProbe {
    static let maximumFileBytes = 1024 * 1024
    /// The whole-hook marker an older `rv secrets hook install` wrote.
    static let legacyMarker = "# rv-secrets-hook"

    /// The `pre-commit` file holding rv's block, or nil.
    static func installedHook(cwd: WorkingDirectory?, home: HomeDirectory?) -> String? {
        guard let cwd else { return nil }
        return installedHook(near: cwd.rawValue, home: home)
    }

    /// The `pre-commit` holding rv's block for the repository at or above
    /// `directory`, which may be a git dir (`--git-dir`) or a path that does
    /// not exist yet (the nearest existing directory above it counts). The
    /// path is spelled from `directory` where the repository lies under it,
    /// so it compares with the command's own lexical paths.
    static func installedHook(near directory: String, home: HomeDirectory?) -> String? {
        guard directory.hasPrefix("/") else { return nil }
        var lexical = (directory as NSString).standardizingPath
        var hops = 0
        while resolveExistingDirectory(lexical) == nil {
            guard lexical != "/", hops < 64 else { return nil }
            lexical = (lexical as NSString).deletingLastPathComponent
            hops += 1
        }
        guard let start = resolveExistingDirectory(lexical) else { return nil }
        let root: String
        let gitdir: String
        if isGitDirectory(start) {
            gitdir = start
            root = (start as NSString).lastPathComponent == ".git" ? (start as NSString).deletingLastPathComponent : start
        } else {
            guard let found = FilesystemLiveProbe.discoverRepositoryRoot(from: start)?.rawValue,
                  let resolved = GitLiveProbe.resolvedGitDir(repoRoot: found)
            else { return nil }
            root = found
            gitdir = resolved
        }
        let common = commonDirectory(gitdir: gitdir)
        let hooks = hooksDirectory(root: root, common: common, home: home?.rawValue)
        let hook = ((hooks + "/pre-commit") as NSString).standardizingPath
        guard let text = readCapped(hook), holdsRVBlock(text) else { return nil }
        return respelled(hook, canonical: start, lexical: lexical)
    }

    /// `HEAD` beside `objects` or `config`: a git dir named directly.
    private static func isGitDirectory(_ path: String) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: path + "/HEAD")
            && (manager.fileExists(atPath: path + "/objects") || manager.fileExists(atPath: path + "/config"))
    }

    /// `hook` with the canonical spelling of an ancestor of `canonical`
    /// swapped for the matching ancestor of `lexical` (`/private/tmp` back
    /// to `/tmp`).
    private static func respelled(_ hook: String, canonical: String, lexical: String) -> String {
        var canonicalBase = canonical
        var lexicalBase = lexical
        while canonicalBase != "/", lexicalBase != "/" {
            if hook.hasPrefix(canonicalBase + "/") {
                return lexicalBase + hook.dropFirst(canonicalBase.count)
            }
            guard (canonicalBase as NSString).lastPathComponent == (lexicalBase as NSString).lastPathComponent else {
                break
            }
            canonicalBase = (canonicalBase as NSString).deletingLastPathComponent
            lexicalBase = (lexicalBase as NSString).deletingLastPathComponent
        }
        return hook
    }

    /// Raises any verdict but a pinned deny to the commit check's
    /// stop when the command weakens the scan: a pack deny alone (`git reset
    /// --hard && git config rv.secretsScan false`) would let one allow-once
    /// run the switch too.
    static func tighten(
        _ result: EvaluationResult, command: ShellCommand, cwd: WorkingDirectory?, home: HomeDirectory?
    ) -> EvaluationResult {
        // A pinned deny already holds (a protected-path write into
        // `.git`, a secret read): it keeps its own rule and message. A
        // command too large to evaluate is already refused.
        if case .deny = result.decision, HookAuthorization.isPinned(result) { return result }
        if case .indeterminate(.commandTooLarge) = result.decision { return result }
        guard weakensScan(command, cwd: cwd, home: home) else { return result }
        return SecretsScanGuard.deny(searchText: result.matchingView.rawValue)
    }

    /// `SecretsScanGuard.weakensScan` with the command's directories and
    /// this probe. One evaluation asks for the same command more than once
    /// (the verdict, then the observe floor): the answer is kept briefly.
    static func weakensScan(_ command: ShellCommand, cwd: WorkingDirectory?, home: HomeDirectory?) -> Bool {
        let key = Recent.Key(command: command.rawValue, cwd: cwd?.rawValue, home: home?.rawValue)
        let now = Date()
        if let known = recent.withLock({ $0.answer(for: key, at: now) }) { return known }
        let answer = SecretsScanGuard.weakensScan(command, home: home, cwd: cwd) { directory in
            installedHook(near: directory, home: home)
        }
        recent.withLock { $0.remember(answer, for: key, at: now) }
        return answer
    }

    private static let recent = Mutex(Recent())

    /// The last few answers, each for `lifetime` seconds.
    private struct Recent {
        struct Key: Equatable {
            let command: String
            let cwd: String?
            let home: String?
        }

        static let capacity = 4
        static let lifetime: TimeInterval = 2
        var entries: [(key: Key, answer: Bool, at: Date)] = []

        func answer(for key: Key, at now: Date) -> Bool? {
            entries.last { $0.key == key && now >= $0.at && now.timeIntervalSince($0.at) < Self.lifetime }?.answer
        }

        mutating func remember(_ answer: Bool, for key: Key, at now: Date) {
            entries.removeAll { $0.key == key }
            entries.append((key, answer, now))
            if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        }
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
