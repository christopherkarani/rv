import Foundation
import RVDomain
import RVEngine

/// `npm test` judge-blindness fix: the words "npm test" hide whatever
/// `scripts.test` contains. When the packs allowed a runner command, the
/// script bodies it would execute are themselves evaluated.
///
/// Runner spellings are read from launched argv (`launchedCommands`), so
/// launchers (`time`, `nohup`, `sudo`, `env`, `timeout`) and shell payloads
/// (`sh -c "npm test"`) are seen through. Recognised: global flags before
/// the verb (any flag may take a value, so every later word is a verb
/// candidate), `run`/`run-script`/`rum`/`urn`, `test`/`t`/`tst`, `start`,
/// `stop`, `restart`, `build`, `lint`, and yarn/pnpm/bun implicit names
/// (`yarn evil`) when the name is a `scripts` key.
///
/// Tri-state, fail-closed: a runner invocation whose script graph cannot
/// be fully resolved (no cwd, a `cd` that cannot be tracked, a workspace
/// or recursive run, a script-shell/node-options override, a malformed
/// package.json, a missing one after earlier chain work, nesting past the
/// depth cap, a cycle, the evaluation bound, a tree-mutating or
/// package.json-touching segment earlier in the same chain) is
/// `.unresolved`, never silently clear. The door floors such commands to
/// indeterminate whether or not a judge is loaded: the judge would only
/// see the top-level string, never the bodies.
///
/// A missing package.json with nothing earlier in the chain is `.clear`:
/// every runner errors out before executing any script.
enum PackageScriptGate {
    enum Verdict {
        /// Every body the command runs was read and allowed.
        /// `allBodiesSafe` is whether each is itself a safe-lane command:
        /// only then may the top-level command skip the judge.
        case clear(allBodiesSafe: Bool)
        case deny(EvaluationResult)
        case unresolved
    }

    static let runners: Set<String> = ["npm", "pnpm", "yarn", "bun"]
    /// Verbs that name scripts for every runner (npm aliases included).
    static let scriptVerbs: [String: [String]] = [
        "test": ["test"], "start": ["start"], "stop": ["stop"],
        "restart": ["restart", "stop", "start"], "build": ["build"], "lint": ["lint"],
    ]
    static let npmAliases: [String: String] = ["t": "test", "tst": "test"]
    static let runVerbs: Set<String> = ["run", "run-script", "rum", "urn"]
    /// `bun test` / `bun build` are bun builtins (test runner, bundler),
    /// not package-script invocations; only `bun run <name>` and non-
    /// builtin verbs like `bun lint` execute `scripts.*`.
    static let bunBuiltinVerbs: Set<String> = ["test", "build"]
    /// yarn/pnpm/bun subcommands that never name a package script; any
    /// other first word is an implicit script name when it is a key.
    static let builtins: [String: Set<String>] = [
        "yarn": [
            "add", "audit", "autoclean", "bin", "cache", "check", "config", "create", "dedupe",
            "dlx", "exec", "explain", "generate-lock-entry", "global", "help", "import", "info",
            "init", "install", "licenses", "link", "list", "login", "logout", "node", "npm",
            "outdated", "owner", "pack", "patch", "plugin", "policies", "publish", "rebuild",
            "remove", "search", "set", "tag", "team", "unlink", "unplug", "up", "upgrade",
            "upgrade-interactive", "version", "versions", "why",
        ],
        "pnpm": [
            "add", "audit", "bin", "config", "create", "dedupe", "deploy", "dlx", "doctor", "env",
            "exec", "fetch", "i", "import", "init", "install", "install-test", "licenses", "link",
            "list", "ls", "outdated", "pack", "patch", "patch-commit", "prune", "publish",
            "rebuild", "remove", "rm", "root", "server", "setup", "store", "un", "uninstall",
            "unlink", "up", "update", "why",
        ],
        "bun": [
            "a", "add", "audit", "build", "c", "create", "exec", "i", "info", "init", "install",
            "link", "outdated", "patch", "pm", "publish", "remove", "repl", "rm", "test", "unlink",
            "update", "upgrade", "why", "x",
        ],
    ]
    /// Flags that run scripts in other packages than the one found here.
    static let crossPackageFlags: Set<String> = [
        "-w", "--workspace", "--workspaces", "-ws", "--include-workspace-root",
        "-r", "--recursive", "--filter", "-F", "--filter-prod", "--workspace-root",
    ]
    /// Flags that swap the shell or preload code for every script.
    static let configOverrideFlags: Set<String> = [
        "--script-shell", "--node-options", "--userconfig", "--globalconfig", "--preload",
    ]
    static let prefixFlags = ["--prefix", "--dir", "--cwd", "-C"]

    static let maxDepth = 3
    /// Script bodies evaluated per top-level invocation; past it, unresolved.
    static let maxBodyEvaluations = 64
    private static let maxVerbCandidates = 16

    /// Evaluate every runner invocation in the command. `evalBody` runs the
    /// product evaluation (semantics + probes) for one script body in
    /// the package directory.
    static func evaluate(
        command: ShellCommand,
        cwd: WorkingDirectory?,
        home: HomePath?,
        evalBody: (ShellCommand, WorkingDirectory?) -> EvaluationResult
    ) -> Verdict {
        var effectiveCwd: String? = cwd?.rawValue
        var treeMutated = false
        var priorWork = false
        var unresolved = false
        var allBodiesSafe = true
        for unit in chainUnits(command.rawValue) {
            let launched = launchedCommands(unit.text)
            let unitTokens = tokens(in: unit.text)
            if let target = plainCD(unitTokens, launched) {
                // A cd in a pipeline or in the background runs in a subshell
                // (or, in zsh, maybe not), and one inside a group ends with
                // it: untracked either way.
                effectiveCwd = unit.inSubshell || unit.grouped
                    ? nil : resolveCD(target, from: effectiveCwd, home: home)
                continue
            }
            let wrapperMovesCwd = wrapperChangesDirectory(unitTokens)
            // Order inside one unit is not modelled (`npm test $(git
            // checkout x)` runs the substitution first), so any mutation in
            // the unit counts against every runner in it.
            let unitMutates = launched.contains { argv in
                isTreeMutating(argv) || (scriptInvocation(in: argv) == nil && touchesPackageManifest(argv))
            }
            if changesDirectory(launched, unitTokens) {
                // A cd inside a group, subshell, payload or launcher: its
                // scope is not modelled, so the cwd is now unknown.
                effectiveCwd = nil
            }
            // Input the launcher parser stopped following may hide a runner.
            if launchIsTruncated(unit.text) { unresolved = true }
            for argv in launched {
                guard let invocation = scriptInvocation(in: argv) else { continue }
                if invocation.unresolvable || hasConfigOverrideAssignment(unitTokens)
                    || treeMutated || unitMutates {
                    // A mutation earlier in this chain runs before the script
                    // does; the package.json read now may not describe what
                    // executes (TOCTOU).
                    unresolved = true
                    continue
                }
                switch check(
                    invocation, cwd: wrapperMovesCwd ? nil : effectiveCwd, home: home,
                    priorWork: priorWork || launched.count > 1, evalBody: evalBody
                ) {
                case .clear(let safe): allBodiesSafe = allBodiesSafe && safe
                case .deny(let hit): return .deny(hit)
                case .unresolved: unresolved = true
                }
            }
            if unitMutates { treeMutated = true }
            priorWork = true
        }
        return unresolved ? .unresolved : .clear(allBodiesSafe: allBodiesSafe)
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
        for argv in launchedCommands(raw) {
            if let invocation = scriptInvocation(in: argv) {
                return invocation.explicit + invocation.implicit
            }
        }
        return nil
    }

    // MARK: - One invocation

    private static func check(
        _ invocation: Invocation,
        cwd: String?,
        home: HomePath?,
        priorWork: Bool,
        evalBody: (ShellCommand, WorkingDirectory?) -> EvaluationResult
    ) -> Verdict {
        let base = invocation.prefixDir.map { resolvePath($0, from: cwd, home: home) } ?? cwd
        guard let base else { return .unresolved }
        guard let packageDir = nearestPackageJSON(from: base) else {
            // No package.json: the runner errors and executes nothing,
            // unless earlier work in the chain may create one first.
            return priorWork ? .unresolved : .clear(allBodiesSafe: true)
        }
        guard let scripts = loadScripts(packageDir),
              let packageCwd = WorkingDirectory(rawValue: packageDir.path)
        else { return .unresolved }
        // The graph never outlives this call.
        return withoutActuallyEscaping(evalBody) { evalBody in
            var graph = ScriptGraph(scripts: scripts, packageCwd: packageCwd, evalBody: evalBody)
            var unresolved = false
            for name in invocation.names(in: scripts) {
                switch graph.check(name, depth: 0) {
                case .clear: continue
                case .deny(let hit): return .deny(hit)
                case .unresolved: unresolved = true
                }
            }
            return unresolved ? .unresolved : .clear(allBodiesSafe: graph.allBodiesSafe)
        }
    }

    // MARK: - Parsing

    struct Invocation {
        /// Names the runner runs whether or not they are keys.
        var explicit: [String] = []
        /// yarn/pnpm/bun bare words: a script only when `scripts` has it.
        var implicit: [String] = []
        var prefixDir: String?
        /// Workspace/recursive run, config override, or an unbounded parse.
        var unresolvable = false

        var isEmpty: Bool { explicit.isEmpty && implicit.isEmpty && !unresolvable }

        func names(in scripts: [String: String]) -> [String] {
            explicit + implicit.filter { scripts[$0] != nil }
        }
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

    /// Recognize one launched argv (`argv[0]` already reduced to its
    /// folded command name) as a script-running runner invocation.
    static func scriptInvocation(in argv: [String]) -> Invocation? {
        guard let runner = argv.first.map(basename), runners.contains(runner.lowercased()) else { return nil }
        let runnerName = runner.lowercased()
        let words = Array(argv.dropFirst().prefix { $0 != "--" })
        var invocation = Invocation()
        let candidates = verbCandidates(words)
        if candidates.count > maxVerbCandidates { invocation.unresolvable = true }
        for index in candidates.prefix(maxVerbCandidates) {
            addNames(runner: runnerName, verbAt: index, words: words, into: &invocation)
        }
        guard !invocation.isEmpty else { return nil }
        // A workspace or override flag only matters when scripts run.
        scanFlags(words, into: &invocation)
        return invocation
    }

    /// Prefix, workspace, and override flags anywhere before `--`.
    private static func scanFlags(_ words: [String], into invocation: inout Invocation) {
        var crossPackage = false
        var override = false
        for (index, word) in words.enumerated() where word.hasPrefix("-") {
            let name = word.split(separator: "=", maxSplits: 1).first.map(String.init) ?? word
            if crossPackageFlags.contains(name) { crossPackage = true }
            if configOverrideFlags.contains(name) { override = true }
            for flag in prefixFlags {
                if word == flag, index + 1 < words.count { invocation.prefixDir = words[index + 1] }
                if word.hasPrefix(flag + "=") { invocation.prefixDir = String(word.dropFirst(flag.count + 1)) }
            }
        }
        if crossPackage || override { invocation.unresolvable = true }
    }

    /// The first positional word is the verb unless an earlier flag takes
    /// a value; a flag without `=` may, so the next positional is also a
    /// candidate, and so on until a positional follows a non-flag.
    private static func verbCandidates(_ words: [String]) -> [Int] {
        var candidates: [Int] = []
        var previousWasValuelessFlag = false
        for (index, word) in words.enumerated() {
            if word.hasPrefix("-"), word != "-" {
                previousWasValuelessFlag = !word.contains("=")
                continue
            }
            candidates.append(index)
            if !previousWasValuelessFlag { break }
            previousWasValuelessFlag = false
        }
        return candidates
    }

    private static func addNames(runner: String, verbAt index: Int, words: [String], into invocation: inout Invocation) {
        let verb = words[index]
        if runVerbs.contains(verb) {
            if let name = words[(index + 1)...].first(where: { !$0.hasPrefix("-") }) {
                invocation.explicit.append(name)
            }
            return
        }
        if runner == "yarn", verb == "workspace" || verb == "workspaces" {
            invocation.unresolvable = true
            return
        }
        let canonical = runner == "npm" ? npmAliases[verb] ?? verb : verb
        if let names = scriptVerbs[canonical] {
            if runner == "bun", bunBuiltinVerbs.contains(canonical) { return }
            invocation.explicit.append(contentsOf: names)
            return
        }
        guard runner != "npm", builtins[runner]?.contains(verb) != true else { return }
        invocation.implicit.append(verb)
    }

    /// `npm_config_*` and `NODE_OPTIONS` assignments in front of a runner
    /// change the script shell or preload code for every script.
    static func hasConfigOverrideAssignment(_ tokens: [String]) -> Bool {
        tokens.contains { token in
            guard isEnvAssignment(token) else { return false }
            let name = token.prefix { $0 != "=" }.lowercased()
            return name.hasPrefix("npm_config_") || name == "node_options"
        }
    }

    /// Segments that rewrite the working tree: after one of these, a
    /// package.json read is not evidence about what a later runner in
    /// the same chain executes.
    static func isTreeMutating(_ argv: [String]) -> Bool {
        guard argv.first.map(basename) == "git" else { return false }
        let rest = argv.dropFirst().filter { !$0.hasPrefix("-") }
        guard let sub = rest.first else { return false }
        if sub == "stash" { return rest.dropFirst().first.map { ["pop", "apply", "drop"].contains($0) } ?? false }
        return ["switch", "checkout", "pull", "merge", "rebase", "reset", "clean", "restore"].contains(sub)
    }

    /// A command naming package.json (or a glob that may match it) may
    /// rewrite it before a later runner reads it.
    static func touchesPackageManifest(_ argv: [String]) -> Bool {
        argv.dropFirst().contains { word in
            let lowered = word.lowercased()
            return lowered.contains("package.json") || lowered.contains(".npmrc")
                || (lowered.contains("pack") && lowered.contains(where: { "*?[".contains($0) }))
        }
    }

    // MARK: - Chain units

    struct ChainUnit {
        var text: String
        /// Next to a single `|` or `&`: runs in a subshell or the background.
        var inSubshell: Bool
        /// Opened or closed a `( … )` / `{ … }` group split across units.
        var grouped = false
    }

    /// Drop the unbalanced `(`/`{` opening and `)`/`}` closing a group that
    /// the separator split cut through (`(cd sub`, `npm test)`, `{ npm
    /// test`), so the launcher parser sees the command inside. Balanced
    /// pairs (`$(…)`, `${HOME}`) are kept. Quotes are not modelled here: an
    /// extra strip only exposes more words to judge.
    static func stripGroupDelimiters(_ text: String) -> String {
        var text = text
        func excess(_ open: Character, over close: Character) -> Bool {
            text.filter { $0 == open }.count > text.filter { $0 == close }.count
        }
        while let first = text.first, (first == "(" && excess("(", over: ")")) || (first == "{" && excess("{", over: "}")) {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        while let last = text.last, (last == ")" && excess(")", over: "(")) || (last == "}" && excess("}", over: "{")) {
            text = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// Quote-aware split at `;`, newline, `&&`, `||`, `|`, `&`, recording
    /// which units sit next to a pipe or background operator.
    static func chainUnits(_ raw: String) -> [ChainUnit] {
        var units: [ChainUnit] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var subshellBefore = false
        let chars = Array(raw)
        var i = 0
        func flush(subshellAfter: Bool) {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = stripGroupDelimiters(trimmed)
            if !text.isEmpty {
                units.append(ChainUnit(
                    text: text, inSubshell: subshellBefore || subshellAfter, grouped: text != trimmed
                ))
            }
            current = ""
            subshellBefore = subshellAfter
        }
        while i < chars.count {
            let ch = chars[i]
            if ch == "'", !inDouble { inSingle.toggle() }
            else if ch == "\"", !inSingle { inDouble.toggle() }
            else if !inSingle, !inDouble {
                if ch == ";" || ch == "\n" { flush(subshellAfter: false); i += 1; continue }
                // `2>&1`, `&>file`, `<&3` are redirects, not separators.
                let redirect = ch == "&" && ((i > 0 && "<>".contains(chars[i - 1]))
                    || (i + 1 < chars.count && chars[i + 1] == ">"))
                if !redirect, ch == "&" || ch == "|" {
                    if i + 1 < chars.count, chars[i + 1] == ch {
                        flush(subshellAfter: false); i += 2; continue
                    }
                    flush(subshellAfter: true); i += 1; continue
                }
            }
            current.append(ch)
            i += 1
        }
        flush(subshellAfter: false)
        return units
    }

    /// The target of a unit that is exactly a top-level `cd` (bare `cd` is
    /// home, returned as `~`); nil for anything else.
    private static func plainCD(_ unitTokens: [String], _ launched: [[String]]) -> String?? {
        guard unitTokens.first == "cd", launched.count == 1, launched[0].first == "cd" else { return nil }
        let args = launched[0].dropFirst().filter { $0 != "--" }
        return .some(args.first)
    }

    private static let groupOpeners = CharacterSet(charactersIn: "({$`!")

    /// Whether a unit or body changes directory anywhere: a launched `cd`,
    /// or a cd word the launcher parser could not attach to a command
    /// (`(cd sub`, `{ cd sub`). Over-claims (`echo cd`), never under-claims.
    static func changesDirectory(_ launched: [[String]], _ unitTokens: [String]) -> Bool {
        launched.contains(where: { $0.first.map(movesDirectory) ?? false })
            || unitTokens.contains(where: { movesDirectory($0.trimmingCharacters(in: groupOpeners)) })
    }

    private static func movesDirectory(_ head: String) -> Bool {
        ["cd", "pushd", "popd", "chdir"].contains(basename(head))
    }

    /// `env -C dir` / `sudo -D dir` / `--chdir` in front of the runner.
    private static func wrapperChangesDirectory(_ unitTokens: [String]) -> Bool {
        for token in unitTokens {
            if runners.contains(basename(token).lowercased()) { return false }
            if token.hasPrefix("--chdir") { return true }
            if token.hasPrefix("-"), !token.hasPrefix("--"), token.contains(where: { $0 == "C" || $0 == "D" }) {
                return true
            }
        }
        return false
    }

    // MARK: - Script graph

    /// Memoised walk over one package's scripts: each name is evaluated at
    /// most once, a cycle is unresolved, and the total number of bodies
    /// evaluated is bounded. A body the packs allowed but that carries an
    /// inline program only the judge could read is unresolved (the judge
    /// never sees bodies); `allBodiesSafe` records whether every body read
    /// is itself a safe-lane command.
    private struct ScriptGraph {
        let scripts: [String: String]
        let packageCwd: WorkingDirectory
        let evalBody: (ShellCommand, WorkingDirectory?) -> EvaluationResult
        var memo: [String: Verdict] = [:]
        var onStack: Set<String> = []
        var evaluations = 0
        var allBodiesSafe = true

        mutating func check(_ name: String, depth: Int) -> Verdict {
            if let known = memo[name] { return known }
            if onStack.contains(name) { return .unresolved }
            onStack.insert(name)
            defer { onStack.remove(name) }
            var unresolved = false
            for key in ["pre\(name)", name, "post\(name)"] {
                guard let body = scripts[key] else { continue }
                evaluations += 1
                guard evaluations <= PackageScriptGate.maxBodyEvaluations else { return .unresolved }
                let result = evalBody(ShellCommand(rawValue: body), packageCwd)
                switch result.decision {
                case .allow: break
                case .deny, .indeterminate: return .deny(result)
                }
                if InlineProgramGuard.requiresJudge(ShellCommand(rawValue: body)) {
                    unresolved = true
                }
                allBodiesSafe = allBodiesSafe && SafeCommandLane.isSafe(body)
                switch nested(body, depth: depth) {
                case .clear: break
                case .deny(let hit): return .deny(hit)
                case .unresolved: unresolved = true
                }
            }
            let verdict: Verdict = unresolved ? .unresolved : .clear(allBodiesSafe: true)
            memo[name] = verdict
            return verdict
        }

        /// Runner invocations inside one body, followed in this package.
        /// A cd, prefix, workspace or override inside the body means the
        /// nested runner may read another package: unresolved.
        private mutating func nested(_ body: String, depth: Int) -> Verdict {
            let launched = launchedCommands(body)
            let bodyTokens = PackageScriptGate.tokens(in: body)
            let movesCwd = PackageScriptGate.changesDirectory(launched, bodyTokens)
            let overrides = PackageScriptGate.hasConfigOverrideAssignment(bodyTokens)
                || PackageScriptGate.wrapperChangesDirectory(bodyTokens)
            var unresolved = launchIsTruncated(body)
            for argv in launched {
                guard let invocation = PackageScriptGate.scriptInvocation(in: argv) else { continue }
                if invocation.unresolvable || invocation.prefixDir != nil || movesCwd || overrides
                    || depth >= PackageScriptGate.maxDepth {
                    unresolved = true
                    continue
                }
                for name in invocation.names(in: scripts) {
                    switch check(name, depth: depth + 1) {
                    case .clear: continue
                    case .deny(let hit): return .deny(hit)
                    case .unresolved: unresolved = true
                    }
                }
            }
            return unresolved ? .unresolved : .clear(allBodiesSafe: true)
        }
    }

    // MARK: - Paths

    /// Resolve a `cd` target. Bare `cd` (nil) goes home; `~` and `$HOME`
    /// expand; any other `$` expansion is untracked (nil).
    private static func resolveCD(_ target: String?, from cwd: String?, home: HomePath?) -> String? {
        guard let target else {
            return home?.rawValue ?? FileManager.default.homeDirectoryForCurrentUser.path
        }
        return resolvePath(target, from: cwd, home: home)
    }

    private static func resolvePath(_ target: String, from cwd: String?, home: HomePath?) -> String? {
        let homePath = home?.rawValue ?? FileManager.default.homeDirectoryForCurrentUser.path
        var value = target
        if value == "~" { return homePath }
        if value.hasPrefix("~/") { value = homePath + String(value.dropFirst()) }
        if value == "$HOME" { return homePath }
        if value.hasPrefix("$HOME/") { value = homePath + String(value.dropFirst(5)) }
        if value == "-" || value.contains("$") || value.contains("`") || value.contains("~") { return nil }
        if value.hasPrefix("/") { return value }
        guard let cwd else { return nil }
        return (cwd as NSString).appendingPathComponent(value)
    }

    /// Walks up to the filesystem root, as the runners do.
    private static func nearestPackageJSON(from cwd: String) -> URL? {
        var dir = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
        while true {
            let candidate = dir.appendingPathComponent("package.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
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
