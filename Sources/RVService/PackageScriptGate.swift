import Foundation
import RVDomain
import RVEngine

/// `npm test` judge-blindness fix: the words "npm test" hide whatever
/// `scripts.test` contains. When the packs allowed a runner command, the
/// script bodies it would execute are themselves evaluated.
///
/// Runner spellings are read from launched argv (`launchedCommands`), so
/// launchers (`time`, `nohup`, `sudo`, `env`, `timeout`) and shell payloads
/// (`sh -c "npm test"`) are seen through. What each argv runs is read by
/// the exact grammar in `PackageRunnerGrammar`: script verbs, lifecycle
/// verbs (their lifecycle scripts), read-only verbs, and everything else
/// unresolved. A runner behind a dynamic head or an unmodelled launcher
/// (`xargs npm test`) is unresolved too.
///
/// Tri-state, fail-closed: a runner invocation whose script graph cannot
/// be fully resolved (no cwd, a `cd` that cannot be tracked, a workspace
/// or recursive run, a script-shell/node-options/PATH override in the
/// unit or exported earlier in the chain, persistent runner config that
/// swaps the shell (`RunnerConfigScan`), a malformed
/// package.json, a missing one after earlier chain work, nesting past the
/// depth cap, a cycle, the evaluation bound, a tree-mutating or
/// package.json-touching segment earlier in the same chain) is
/// `.unresolved`, never silently clear. The door floors such commands to
/// indeterminate whether or not a judge is loaded: the judge would only
/// see the top-level string, never the bodies.
///
/// `.needsJudge` is for runs with no script body the judge cannot see: a
/// package bin (`npx tsc`, `yarn eslint .`, a global install of named
/// packages), a run behind a container or remote launcher, and a run
/// after earlier chain work when the current manifest runs no script
/// (`rm -rf node_modules && npm install` with no lifecycle scripts). The
/// judge, which reads the whole chain, decides with the safe lane closed.
/// Earlier work that names a manifest or runner config, or a script that
/// will run after a mutation (TOCTOU), stays `.unresolved`.
///
/// A missing package.json with nothing earlier in the chain is `.clear`
/// only when the cwd is absolute and every directory up to `/` was read
/// and holds no manifest of any kind: every runner then errors out
/// before executing any script.
enum PackageScriptGate {
    enum Verdict {
        /// Every body the command runs was read and allowed.
        /// `allBodiesSafe` is whether each is itself a safe-lane command:
        /// only then may the top-level command skip the judge.
        case clear(allBodiesSafe: Bool)
        case deny(EvaluationResult)
        /// No body the judge cannot see runs: the judge decides, with the
        /// safe lane closed.
        case needsJudge
        case unresolved
    }

    /// Heads that may run package scripts or package bins.
    static let runnerHeads: Set<String> = [
        "npm", "pnpm", "yarn", "yarnpkg", "bun", "npx", "pnpx", "bunx", "corepack", "deno",
    ]

    static let maxDepth = 3
    /// Script bodies evaluated per top-level invocation; past it, unresolved.
    static let maxBodyEvaluations = 64

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
        var needsJudge = false
        var allBodiesSafe = true
        var chainOverride = false
        var configNamed = false
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
            // checkout x)` runs the substitution first), so any command in
            // the unit outside the read-only allowlist counts against every
            // runner in it. Its own redirects only count for later units.
            let unitMutates = !launchedCommandsAsWritten(unit.text).allSatisfy(isReadOnly)
            if changesDirectory(launched, unitTokens) {
                // A cd inside a group, subshell, payload or launcher: its
                // scope is not modelled, so the cwd is now unknown.
                effectiveCwd = nil
            }
            // Input the launcher parser stopped following may hide a runner,
            // and so may a dynamic head or a launcher the parser does not
            // unwrap (`xargs npm test`, `watch npm test`).
            if launchIsTruncated(unit.text) { unresolved = true }
            switch hiddenRunner(unit.text, launched) {
            case .none: break
            case .remote: needsJudge = true
            case .hidden: unresolved = true
            }
            let overridden = chainOverride || hasConfigOverrideAssignment(unitTokens)
            let unitNamesConfig = namesRunnerConfig(unit.text)
            for argv in launched {
                guard let invocation = scriptInvocation(in: argv) else { continue }
                if invocation.runsNothing { continue }
                // A mutation earlier in this chain (or in this unit) runs
                // before the runner reads its manifest (TOCTOU).
                let mutatedBefore = treeMutated || unitMutates
                if invocation.unresolvable || overridden || (mutatedBefore && (configNamed || unitNamesConfig)) {
                    unresolved = true
                    continue
                }
                switch check(
                    invocation, cwd: wrapperMovesCwd ? nil : effectiveCwd, home: home,
                    priorWork: priorWork || launched.count > 1, mutatedBefore: mutatedBefore,
                    evalBody: evalBody
                ) {
                case .clear(let safe): allBodiesSafe = allBodiesSafe && safe
                case .needsJudge: needsJudge = true
                case .deny(let hit): return .deny(hit)
                case .unresolved: unresolved = true
                }
            }
            if unitMutates || !unitIsReadOnly(unit.text) { treeMutated = true }
            if setsOverride(unitTokens, launched) { chainOverride = true }
            if unitNamesConfig { configNamed = true }
            priorWork = true
        }
        if unresolved { return .unresolved }
        return needsJudge ? .needsJudge : .clear(allBodiesSafe: allBodiesSafe)
    }

    /// Files that decide what a runner executes: the manifests and the
    /// runner configs (`RunnerConfigScan`). Earlier work naming one may
    /// rewrite what the runner then reads.
    static let runnerConfigNames = [
        "package.json", "package.yaml", "package.json5", ".npmrc", ".yarnrc", "bunfig.toml", ".pnpmfile",
        "pnpm-workspace.yaml", "deno.json",
    ]

    static func namesRunnerConfig(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return runnerConfigNames.contains { lowered.contains($0) }
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

    /// `mutatedBefore`: earlier work in the chain (or this unit) may have
    /// changed the tree. A script that will run then is TOCTOU
    /// (unresolved); a run with no script to run goes to the judge, which
    /// reads the earlier work in the same command.
    private static func check(
        _ invocation: Invocation,
        cwd: String?,
        home: HomePath?,
        priorWork: Bool,
        mutatedBefore: Bool,
        evalBody: (ShellCommand, WorkingDirectory?) -> EvaluationResult
    ) -> Verdict {
        let base = invocation.prefixDir.map { resolvePath($0, from: cwd, home: home) } ?? cwd
        guard let base else { return .unresolved }
        let packageDir: URL
        switch locateManifest(from: base) {
        case .unknown:
            return .unresolved
        case .none:
            // No manifest anywhere up to `/`: a script runner errors and
            // executes nothing, unless earlier work may create one first
            // (the judge reads that work). A bin still runs.
            if RunnerConfigScan.swapsShellOrPreloads(
                packageDir: URL(fileURLWithPath: base, isDirectory: true), home: home) {
                return .unresolved
            }
            if invocation.runsUnreadBody(in: [:]) { return .unresolved }
            if invocation.runsBin || !invocation.implicit.isEmpty || priorWork || mutatedBefore {
                return .needsJudge
            }
            return .clear(allBodiesSafe: true)
        case .found(let dir):
            packageDir = dir
        }
        guard !RunnerConfigScan.swapsShellOrPreloads(packageDir: packageDir, home: home) else { return .unresolved }
        if invocation.onlyBin { return .needsJudge }
        guard let scripts = loadScripts(packageDir),
              let packageCwd = WorkingDirectory(rawValue: packageDir.path)
        else { return .unresolved }
        if invocation.runsUnreadBody(in: scripts) { return .unresolved }
        let names = invocation.scriptNames(in: scripts)
        let runsBin = invocation.runsBin(in: scripts)
        // The graph never outlives this call.
        return withoutActuallyEscaping(evalBody) { evalBody in
            var graph = ScriptGraph(scripts: scripts, packageCwd: packageCwd, evalBody: evalBody)
            var unresolved = false
            for name in names {
                switch graph.check(name, depth: 0) {
                case .clear, .needsJudge: continue
                case .deny(let hit): return .deny(hit)
                case .unresolved: unresolved = true
                }
            }
            if unresolved { return .unresolved }
            if mutatedBefore, graph.evaluations > 0 { return .unresolved }
            if mutatedBefore || runsBin { return .needsJudge }
            return .clear(allBodiesSafe: graph.allBodiesSafe)
        }
    }

    // MARK: - Parsing

    typealias Invocation = PackageRunnerGrammar.Reading

    /// Parse one plain segment into dequoted whitespace tokens.
    static func tokens(in raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map { dequote(String($0)) }
    }

    static func dequote(_ token: String) -> String {
        token.filter { $0 != "'" && $0 != "\"" }
    }

    static func basename(_ token: String) -> String {
        PackageRunnerGrammar.basename(token)
    }

    static func isEnvAssignment(_ token: String) -> Bool {
        guard let eq = token.firstIndex(of: "="), eq != token.startIndex else { return false }
        return token[..<eq].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Recognize one launched argv (`argv[0]` already reduced to its
    /// folded command name) as a package-runner invocation
    /// (`PackageRunnerGrammar`); nil when it is not a runner at all.
    static func scriptInvocation(in argv: [String]) -> Invocation? {
        PackageRunnerGrammar.read(argv)
    }

    /// Heads that only print or search text: a runner word in their
    /// operands (`git commit -m "npm test"`) is data, not a launch.
    static let textOnlyHeads: Set<String> = [
        "echo", "printf", "git", "gh", "grep", "egrep", "fgrep", "rg", "ag", "ack", "man", "which", "type",
        "whereis", "whatis", "apropos", "cat", "less", "more", "head", "tail", "wc", "sort", "uniq", "cut",
        "tr", "brew", "apt", "apt-get", "dnf", "yum", "pacman", "port", "winget", "choco", "scoop", "jq",
        // Process patterns and names: matched, never launched.
        "pkill", "pgrep", "killall", "ps",
    ]
    /// Operand words that make a dynamic head look like a runner call.
    static let runnerVerbWords: Set<String> = [
        "run", "run-script", "test", "t", "tst", "start", "stop", "restart", "install", "i", "ci", "it",
        "cit", "add", "pack", "publish", "version", "rebuild", "exec", "x", "dlx", "task", "--run",
        "create", "init", "update", "up", "upgrade",
    ]

    /// Heads that run their operand command somewhere else (a container
    /// or another host): a runner there reads that place's manifest, not
    /// the cwd's as the gate would. Its words go to the judge.
    static let remoteHeads: Set<String> = ["docker", "podman", "nerdctl", "ssh"]

    enum HiddenRunner { case none, remote, hidden }

    /// A runner the launcher parser did not surface as a command of its
    /// own: behind a dynamic head (`$NPM test`, `"$(which npm)" test`) or
    /// an unmodelled launcher (`xargs`, `find -exec`, `watch`, `script`,
    /// `caffeinate`, `arch`), which is `.hidden`. One behind a container or
    /// remote head (`docker run node npm test`, `ssh host npm test`) is
    /// `.remote`. Over-claims, never under-claims a modelled spelling.
    static func hiddenRunner(_ unitText: String, _ launched: [[String]]) -> HiddenRunner {
        for argv in dynamicHeadLaunches(unitText) {
            let head = argv[0].lowercased()
            if runnerHeads.contains(where: { head.contains($0) }) || head.contains("node") { return .hidden }
            if argv.dropFirst().contains(where: { runnerVerbWords.contains($0.lowercased()) }) { return .hidden }
        }
        var found = HiddenRunner.none
        for argv in launched {
            guard let head = argv.first.map(basename)?.lowercased(),
                  scriptInvocation(in: argv) == nil, !textOnlyHeads.contains(head)
            else { continue }
            let words = argv.dropFirst().flatMap { tokens(in: $0) }.map { basename($0).lowercased() }
            for (index, word) in words.enumerated() where index + 1 < words.count {
                if runnerHeads.contains(word) || (word == "node" && words[index + 1].hasPrefix("--run")) {
                    guard remoteHeads.contains(head) else { return .hidden }
                    found = .remote
                }
            }
        }
        return found
    }

    static func hidesRunner(_ unitText: String, _ launched: [[String]]) -> Bool {
        hiddenRunner(unitText, launched) != .none
    }

    /// Environment names that change what a script runs: the runner's
    /// config (`npm_config_script_shell`, `YARN_*`), preloaded code
    /// (`NODE_OPTIONS`), or which program a body's words resolve to (`PATH`).
    static func isOverrideName(_ raw: String) -> Bool {
        let name = raw.lowercased()
        return ["npm_config_", "yarn_", "pnpm_", "bun_config_"].contains { name.hasPrefix($0) }
            || ["node_options", "node_path", "path", "bash_env", "env", "shell"].contains(name)
    }

    /// An override assignment anywhere in the unit (`FOO=x npm test`,
    /// `export NODE_OPTIONS=…`, `env PATH=… npm test`).
    static func hasConfigOverrideAssignment(_ tokens: [String]) -> Bool {
        tokens.contains { token in
            guard isEnvAssignment(token) else { return false }
            return isOverrideName(String(token.prefix { $0 != "=" }))
        }
    }

    /// A unit that changes the environment for the rest of the chain: an
    /// override assignment or export, or sourcing a file that may set any.
    static func setsOverride(_ unitTokens: [String], _ launched: [[String]]) -> Bool {
        if hasConfigOverrideAssignment(unitTokens) { return true }
        return launched.contains { argv in
            guard let head = argv.first.map(basename) else { return false }
            if head == "source" || head == "." { return true }
            if head == "set" { return argv.contains { $0.hasPrefix("-") && $0.contains("a") } }
            return ["export", "declare", "typeset", "readonly"].contains(head)
                && argv.dropFirst().contains { isOverrideName(String($0.prefix { $0 != "=" })) }
        }
    }

    /// A chain unit after which a package.json read still describes what
    /// a later runner executes: every launched command is read-only, no
    /// output redirect other than an fd dup or `/dev/null`, and nothing
    /// the launcher parser could not follow. Anything else may rewrite a
    /// manifest (TOCTOU), so later runners are unresolved.
    static func unitIsReadOnly(_ text: String) -> Bool {
        !launchIsTruncated(text) && dynamicHeadLaunches(text).isEmpty
            && !writesOutput(text) && launchedCommandsAsWritten(text).allSatisfy(isReadOnly)
    }

    /// Heads that read or print only. A path head (`./ls`) is not one.
    static let readOnlyHeads: Set<String> = [
        "ls", "pwd", "true", "false", ":", "echo", "printf", "cat", "head", "tail", "wc", "grep", "egrep",
        "fgrep", "which", "type", "date", "whoami", "uname", "printenv", "test", "[", "sleep", "stat", "du",
        "df", "realpath", "readlink", "basename", "dirname", "set", "export",
    ]
    static let readOnlyGitSubcommands: Set<String> = [
        "status", "log", "diff", "show", "rev-parse", "describe", "ls-files",
    ]
    static let versionFlags: Set<String> = ["--version", "-V"]

    /// One launched argv (head as written, no redirects) that cannot write
    /// the tree. A recognised runner counts: its bodies are evaluated
    /// themselves (an unresolvable one already leaves the graph unresolved).
    static func isReadOnly(_ argv: [String]) -> Bool {
        guard let raw = argv.first.map(dequote) else { return true }
        if scriptInvocation(in: argv) != nil { return true }
        if isEnvAssignment(raw) { return argv.count == 1 }
        if raw.contains("/") && !(raw.hasPrefix("/bin/") || raw.hasPrefix("/usr/bin/")) { return false }
        let head = basename(raw)
        let rest = Array(argv.dropFirst())
        if rest.count == 1, versionFlags.contains(rest[0]) { return true }
        switch head {
        case "env": return rest.isEmpty
        case "rg": return !rest.contains { $0.hasPrefix("--pre") }
        case "git": return isReadOnlyGit(rest)
        default: return readOnlyHeads.contains(head)
        }
    }

    /// `git <read-only subcommand>` with no global option (`-c` can run a
    /// configured program) and no `--output`; `branch`, `remote` and
    /// `config` only in their listing forms.
    static func isReadOnlyGit(_ args: [String]) -> Bool {
        guard let sub = args.first, !sub.hasPrefix("-") else { return false }
        let rest = args.dropFirst()
        if rest.contains(where: { $0.hasPrefix("--output") || $0 == "-o" }) { return false }
        switch sub {
        case _ where readOnlyGitSubcommands.contains(sub): return true
        case "branch":
            let listing: Set<String> = ["-a", "-r", "-v", "-vv", "-l", "--list", "--all", "--remotes",
                                        "--verbose", "--show-current", "--no-color"]
            return rest.allSatisfy { listing.contains($0) }
        case "remote": return rest.allSatisfy { $0 == "-v" || $0 == "--verbose" }
        case "config":
            return rest.first.map { ["--get", "--get-all", "--get-regexp", "--list", "-l"].contains($0) } ?? false
        default: return false
        }
    }

    /// An output redirect to anything but an fd dup (`2>&1`, `>&-`) or
    /// `/dev/null`. Only single quotes hide a `>`: inside double quotes a
    /// `$(… > f)` still runs, so a quoted `>` over-claims.
    static func writesOutput(_ text: String) -> Bool {
        let chars = Array(text)
        var index = 0
        var inSingle = false
        while index < chars.count {
            let char = chars[index]
            if char == "'" { inSingle.toggle() }
            guard char == ">", !inSingle else { index += 1; continue }
            var next = index + 1
            if next < chars.count, chars[next] == "(" { return true }
            if next < chars.count, chars[next] == ">" || chars[next] == "|" { next += 1 }
            if next < chars.count, chars[next] == "&" {
                next += 1
                var digits = next
                while digits < chars.count, chars[digits].isNumber { digits += 1 }
                let end = digits == next && digits < chars.count && chars[digits] == "-" ? digits + 1 : digits
                if end > next, end == chars.count || " \t;|&)".contains(chars[end]) {
                    index = end
                    continue
                }
            }
            while next < chars.count, chars[next] == " " || chars[next] == "\t" { next += 1 }
            var target = ""
            while next < chars.count, !" \t;|&()<>".contains(chars[next]) { target.append(chars[next]); next += 1 }
            if dequote(target) != "/dev/null" { return true }
            index = next
        }
        return false
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
            if runnerHeads.contains(basename(token).lowercased()) { return false }
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
                case .unresolved, .needsJudge: unresolved = true
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
            let overrides = PackageScriptGate.setsOverride(bodyTokens, launched)
                || PackageScriptGate.wrapperChangesDirectory(bodyTokens)
            var unresolved = launchIsTruncated(body)
            if PackageScriptGate.hidesRunner(body, launched) { unresolved = true }
            // As at the top level: a unit outside the read-only allowlist
            // may rewrite the manifest before a nested runner in it or
            // after it reads one.
            var treeMutated = false
            for unit in PackageScriptGate.chainUnits(body) {
                let unitLaunched = launchedCommands(unit.text)
                let unitMutates = !launchedCommandsAsWritten(unit.text).allSatisfy(PackageScriptGate.isReadOnly)
                for argv in unitLaunched {
                    guard let invocation = PackageScriptGate.scriptInvocation(in: argv) else { continue }
                    if invocation.runsNothing { continue }
                    // Nested runs stay strict: a bin run inside a body is
                    // hidden from the judge, which never sees bodies.
                    guard !invocation.unresolvable, !invocation.runsBin(in: scripts), invocation.prefixDir == nil,
                          !movesCwd, !overrides, !treeMutated, !unitMutates, depth < PackageScriptGate.maxDepth
                    else {
                        unresolved = true
                        continue
                    }
                    for name in invocation.scriptNames(in: scripts) {
                        switch check(name, depth: depth + 1) {
                        case .clear: continue
                        case .deny(let hit): return .deny(hit)
                        case .unresolved, .needsJudge: unresolved = true
                        }
                    }
                }
                if unitMutates || !PackageScriptGate.unitIsReadOnly(unit.text) { treeMutated = true }
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

    enum ManifestLookup: Equatable {
        case found(URL)
        /// Absolute cwd, every directory up to `/` read, no manifest.
        case none
        /// A relative cwd (rvd's own cwd is not the agent's), a directory
        /// that could not be read, or another manifest format (pnpm's
        /// `package.yaml`/`package.json5`) the gate does not parse.
        case unknown
    }

    static let alternateManifests = ["package.yaml", "package.json5"]

    /// Walks up to the filesystem root, as the runners do.
    static func locateManifest(from cwd: String) -> ManifestLookup {
        guard cwd.hasPrefix("/") else { return .unknown }
        var dir = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
        while true {
            let manifest = entry(dir.appendingPathComponent("package.json").path)
            if manifest == .unknown { return .unknown }
            for alternate in alternateManifests where entry(dir.appendingPathComponent(alternate).path) != .absent {
                return .unknown
            }
            if manifest == .present { return .found(dir) }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return .none }
            dir = parent
        }
    }

    private enum Entry { case present, absent, unknown }

    /// Present, positively absent (ENOENT), or unknown (no permission, a
    /// path component that is not a directory, any other error).
    private static func entry(_ path: String) -> Entry {
        var info = stat()
        if stat(path, &info) == 0 { return .present }
        return errno == ENOENT ? .absent : .unknown
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
