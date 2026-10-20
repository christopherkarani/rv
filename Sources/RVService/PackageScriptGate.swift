import Foundation
import RVDomain

/// `npm test` judge-blindness fix: the words "npm test" hide whatever
/// `scripts.test` contains. When the packs allowed a runner command, the
/// script bodies it would execute are themselves evaluated.
///
/// Tri-state, fail-closed: a runner invocation whose script graph cannot
/// be fully resolved (no cwd, untracked `cd`, missing or unparseable
/// package.json, nesting past the depth cap, a tree-mutating segment
/// earlier in the same chain) is `.unresolved`, never silently clear.
/// The caller keeps such commands out of the judge-skipping safe lane,
/// so they reach the judge or a human.
enum PackageScriptGate {
    enum Verdict {
        case clear
        case deny(EvaluationResult)
        case unresolved
    }

    static let runners: Set<String> = ["npm", "pnpm", "yarn", "bun"]
    static let verbs: Set<String> = ["test", "build", "lint"]
    /// `bun test` / `bun build` are bun builtins (test runner, bundler),
    /// not package-script invocations; only `bun run <name>` and non-
    /// builtin verbs like `bun lint` execute `scripts.*`.
    static let bunBuiltinVerbs: Set<String> = ["test", "build"]

    /// Evaluate every runner segment in the command. `evalBody` runs the
    /// product evaluation (semantics + probes) for one script body in
    /// the package directory.
    static func evaluate(
        command: ShellCommand,
        cwd: WorkingDirectory?,
        home: HomePath?,
        evalBody: (ShellCommand, WorkingDirectory?) -> EvaluationResult
    ) -> Verdict {
        let units = shellChainSegments(command.rawValue).map(tokens(in:))
        guard let cwd else {
            return units.contains(where: { scriptInvocation(in: $0) != nil }) ? .unresolved : .clear
        }
        var effectiveCwd: String? = cwd.rawValue
        var treeMutated = false
        var unresolved = false
        for unit in units {
            let headIndex = unit.firstIndex(where: { !isEnvAssignment($0) && $0 != "env" }) ?? unit.startIndex
            guard headIndex < unit.endIndex else { continue }
            let head = basename(unit[headIndex])
            if head == "cd" {
                effectiveCwd = resolveCD(unit, headIndex: headIndex, from: effectiveCwd, home: home)
                continue
            }
            if isTreeMutating(unit, headIndex: headIndex) { treeMutated = true }
            guard let invocation = scriptInvocation(in: unit) else { continue }
            // A mutation earlier in this same chain runs before the
            // script does; the package.json read now may not describe
            // what executes (TOCTOU), so the graph is unresolved.
            if treeMutated { unresolved = true; continue }
            let base: String?
            if let prefix = invocation.prefixDir {
                base = resolvePath(prefix, from: effectiveCwd, home: home)
            } else {
                base = effectiveCwd
            }
            guard let base, let packageDir = nearestPackageJSON(from: base) else {
                unresolved = true
                continue
            }
            guard let scripts = loadScripts(packageDir) else {
                unresolved = true
                continue
            }
            guard let packageCwd = WorkingDirectory(rawValue: packageDir.path) else {
                unresolved = true
                continue
            }
            for name in invocation.names {
                switch checkScript(
                    name, scripts: scripts, packageCwd: packageCwd, evalBody: evalBody, depth: 0
                ) {
                case .clear: continue
                case .deny(let hit): return .deny(hit)
                case .unresolved: unresolved = true
                }
            }
        }
        return unresolved ? .unresolved : .clear
    }

    /// Compatibility shim for pack-only tests: deny maps to the result,
    /// everything else to nil. Product paths use `evaluate` so the
    /// unresolved state is not lost.
    static func check(
        command: ShellCommand,
        cwd: WorkingDirectory?,
        session: EvaluateSession,
        enabledPacks: [PackID]
    ) -> EvaluationResult? {
        let verdict = evaluate(command: command, cwd: cwd, home: nil) { body, _ in
            session.evaluate(EvaluationRequest(command: body, enabledPacks: enabledPacks))
        }
        if case .deny(let hit) = verdict { return hit }
        return nil
    }

    static func scriptNames(in raw: String) -> [String]? {
        scriptInvocation(in: tokens(in: raw))?.names
    }

    // MARK: - Parsing

    struct Invocation {
        var names: [String]
        var prefixDir: String?
    }

    /// Parse one plain segment into dequoted whitespace tokens.
    static func tokens(in raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map { dequote(String($0)) }
    }

    static func dequote(_ token: String) -> String {
        token.filter { $0 != "'" && $0 != "\"" }
    }

    static func basename(_ token: String) -> String {
        token.split(separator: "/").last.map(String.init) ?? token
    }

    static func isEnvAssignment(_ token: String) -> Bool {
        guard let eq = token.firstIndex(of: "="), eq != token.startIndex else { return false }
        return token[..<eq].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Recognize `<runner> [flags] (run <name>|test|build|lint)` with
    /// `--prefix` / `--dir` / `-C` / `--cwd` honored anywhere in the
    /// segment. Env assignments and path spellings (`./node_modules/.bin/
    /// npm`) are seen through via basename matching.
    static func scriptInvocation(in tokens: [String]) -> Invocation? {
        var i = tokens.startIndex
        while i < tokens.endIndex, isEnvAssignment(tokens[i]) || tokens[i] == "env" { i += 1 }
        guard i < tokens.endIndex else { return nil }
        let runner = basename(tokens[i])
        guard runners.contains(runner) else { return nil }
        i += 1
        var prefixDir: String?
        func scanPrefix(_ t: String, _ next: String?) {
            for flag in ["--prefix", "--dir", "--cwd", "-C"] {
                if t == flag, let next { prefixDir = next }
                if t.hasPrefix(flag + "=") { prefixDir = String(t.dropFirst(flag.count + 1)) }
            }
        }
        var verb: String?
        var j = i
        while j < tokens.endIndex {
            let t = tokens[j]
            scanPrefix(t, j + 1 < tokens.endIndex ? tokens[j + 1] : nil)
            if t.hasPrefix("-") { j += 1; continue }
            verb = t
            j += 1
            break
        }
        guard let verb else { return nil }
        // Prefix flags may also trail the verb (`npm test --prefix=x`).
        var k = j
        while k < tokens.endIndex {
            scanPrefix(tokens[k], k + 1 < tokens.endIndex ? tokens[k + 1] : nil)
            k += 1
        }
        if verb == "run" {
            while j < tokens.endIndex, tokens[j].hasPrefix("-") { j += 1 }
            guard j < tokens.endIndex else { return nil }
            return Invocation(names: [tokens[j]], prefixDir: prefixDir)
        }
        guard verbs.contains(verb) else { return nil }
        if runner == "bun", bunBuiltinVerbs.contains(verb) { return nil }
        return Invocation(names: [verb], prefixDir: prefixDir)
    }

    /// Segments that rewrite the working tree: after one of these, a
    /// package.json read is not evidence about what a later runner in
    /// the same chain executes.
    static func isTreeMutating(_ tokens: [String], headIndex: Int) -> Bool {
        guard basename(tokens[headIndex]) == "git" else { return false }
        let rest = tokens[(headIndex + 1)...].filter { !$0.hasPrefix("-") }
        guard let sub = rest.first else { return false }
        if sub == "stash" { return rest.dropFirst().first.map { ["pop", "apply", "drop"].contains($0) } ?? false }
        return ["switch", "checkout", "pull", "merge", "rebase", "reset", "clean", "restore"].contains(sub)
    }

    // MARK: - Script graph

    private static func checkScript(
        _ name: String,
        scripts: [String: String],
        packageCwd: WorkingDirectory,
        evalBody: (ShellCommand, WorkingDirectory?) -> EvaluationResult,
        depth: Int
    ) -> Verdict {
        var unresolved = false
        for key in ["pre\(name)", name, "post\(name)"] {
            guard let body = scripts[key] else { continue }
            let result = evalBody(ShellCommand(rawValue: body), packageCwd)
            switch result.decision {
            case .allow: break
            case .deny, .indeterminate: return .deny(result)
            }
            // Follow nested runner invocations segment by segment, so
            // verb forms, flags, and `;`-glued names are all seen.
            for segment in shellChainSegments(body) {
                guard let nested = scriptInvocation(in: tokens(in: segment)) else { continue }
                guard depth < 3 else { unresolved = true; continue }
                for nestedName in nested.names {
                    switch checkScript(
                        nestedName, scripts: scripts, packageCwd: packageCwd,
                        evalBody: evalBody, depth: depth + 1
                    ) {
                    case .clear: continue
                    case .deny(let hit): return .deny(hit)
                    case .unresolved: unresolved = true
                    }
                }
            }
        }
        return unresolved ? .unresolved : .clear
    }

    // MARK: - Paths

    /// Resolve a `cd` segment. Bare `cd` goes home; `~` and `$HOME`
    /// expand; any other `$` expansion is untracked (nil).
    private static func resolveCD(
        _ tokens: [String], headIndex: Int, from cwd: String?, home: HomePath?
    ) -> String? {
        let homePath = home?.rawValue ?? FileManager.default.homeDirectoryForCurrentUser.path
        guard headIndex + 1 < tokens.endIndex else { return homePath }
        return resolvePath(tokens[headIndex + 1], from: cwd, home: home)
    }

    private static func resolvePath(_ target: String, from cwd: String?, home: HomePath?) -> String? {
        let homePath = home?.rawValue ?? FileManager.default.homeDirectoryForCurrentUser.path
        var value = target
        if value == "~" { return homePath }
        if value.hasPrefix("~/") { value = homePath + String(value.dropFirst()) }
        if value == "$HOME" { return homePath }
        if value.hasPrefix("$HOME/") { value = homePath + String(value.dropFirst(5)) }
        if value.contains("$") || value.contains("`") { return nil }
        if value.hasPrefix("/") { return value }
        guard let cwd else { return nil }
        return (cwd as NSString).appendingPathComponent(value)
    }

    private static func nearestPackageJSON(from cwd: String) -> URL? {
        var dir = URL(fileURLWithPath: cwd, isDirectory: true)
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("package.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    /// nil only when package.json exists but cannot be parsed (or its
    /// `scripts` is malformed). A missing `scripts` key is an empty
    /// graph: the runner errors and executes nothing.
    private static func loadScripts(_ packageDir: URL) -> [String: String]? {
        let file = packageDir.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let raw = root["scripts"] else { return [:] }
        guard let scripts = raw as? [String: String] else { return nil }
        return scripts
    }
}
