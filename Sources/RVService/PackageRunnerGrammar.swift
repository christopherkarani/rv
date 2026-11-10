import Foundation

/// The exact package-runner command lines the script gate can read.
///
/// One argv (argv[0] already reduced to its folded command name) is read
/// as: not a runner (nil), a runner that executes no package script, the
/// script names it runs, or unresolvable. Anything outside the tables
/// below is unresolvable, never silently "no scripts": npm accepts command
/// abbreviations and camelCase spellings, and nopt expands unambiguous
/// abbreviations of long flags (`--scri` is `--script-shell`), so a verb
/// or flag the gate does not know may still run a script or swap the
/// shell every script runs under.
///
/// Lifecycle verbs (`install`, `ci`, `pack`, `publish`, `version`,
/// `rebuild`, …) run the root package's lifecycle scripts; those names are
/// read like any other script (the graph adds each `pre`/`post` itself).
/// Dependency lifecycle scripts live in packages the gate cannot read.
enum PackageRunnerGrammar {
    struct Reading: Equatable {
        /// Script names run when they are `scripts` keys (absent: nothing).
        var explicit: [String] = []
        /// yarn/pnpm/bun bare words: a script when it is a key, otherwise
        /// a package bin or a command the gate does not model (unresolved).
        var implicit: [String] = []
        var prefixDir: String?
        var unresolvable = false

        var runsNothing: Bool { explicit.isEmpty && implicit.isEmpty && !unresolvable }

        /// The script names to read in `scripts`; nil when a bare word is
        /// not a key (it would run a package bin or an unmodelled command).
        func names(in scripts: [String: String]) -> [String]? {
            guard implicit.allSatisfy({ scripts[$0] != nil }) else { return nil }
            return explicit + implicit
        }
    }

    /// Root lifecycle scripts an install-like verb may run.
    static let installLifecycle = ["install", "prepare", "prepublish", "dependencies"]
    static let packLifecycle = ["pack", "prepare"]
    static let publishLifecycle = ["prepublishOnly", "pack", "prepare", "publish"]
    static let versionLifecycle = ["version"]

    static func read(_ argv: [String]) -> Reading? {
        guard let head = argv.first.map(basename)?.lowercased() else { return nil }
        let words = Array(argv.dropFirst())
        switch head {
        case "npm": return readRunner(.npm, words)
        case "yarn", "yarnpkg": return readRunner(.yarn, words)
        case "pnpm": return readRunner(.pnpm, words)
        case "bun": return readRunner(.bun, words)
        case "npx", "pnpx", "bunx", "corepack":
            return Reading(unresolvable: true)
        case "node":
            return readNodeRun(words)
        case "deno":
            let positional = words.first { !$0.hasPrefix("-") }
            return positional == "task" ? Reading(unresolvable: true) : nil
        default:
            return nil
        }
    }

    // MARK: - Runners

    enum Runner { case npm, yarn, pnpm, bun }

    private static func readRunner(_ runner: Runner, _ argv: [String]) -> Reading {
        let words = Array(argv.prefix { $0 != "--" })
        var reading = Reading()
        var index = 0
        var infoFlag = false
        // Leading flags: every one must be known, or the next word may be
        // its value and the verb is unknowable.
        while index < words.count, isFlag(words[index]) {
            let word = words[index]
            if ["-v", "--version", "-h", "--help"].contains(word) { infoFlag = true }
            index = consumeFlag(at: index, in: words, into: &reading, strict: true)
        }
        guard index < words.count else {
            // No verb: help/version, or (yarn) an install.
            if runner == .yarn, !infoFlag { reading.explicit += installLifecycle }
            return reading
        }
        let verb = words[index]
        let rest = Array(words[(index + 1)...])
        // npm parses flags anywhere before `--`; yarn/pnpm/bun hand words
        // after the script name to the script, so only npm is rescanned.
        if runner == .npm { scanTrailingFlags(rest, into: &reading) }
        switch runner {
        case .npm: readNpmVerb(verb, rest, into: &reading)
        case .yarn: readYarnVerb(verb, rest, into: &reading)
        case .pnpm: readPnpmVerb(verb, rest, into: &reading)
        case .bun: readBunVerb(verb, rest, into: &reading)
        }
        return reading
    }

    static let npmInstallVerbs: Set<String> = [
        "install", "i", "in", "ins", "inst", "insta", "instal", "isnt", "isnta", "isntal", "isntall", "add",
        "ci", "clean-install", "ic", "install-clean", "isntall-clean", "update", "up", "upgrade", "udpate",
        "dedupe", "ddp", "prune", "rebuild", "rb", "link", "ln", "uninstall", "unlink", "remove", "rm",
        "r", "un",
    ]
    static let npmReadOnlyVerbs: Set<String> = [
        "help", "ls", "list", "la", "ll", "view", "info", "show", "v", "outdated", "search", "s", "se",
        "find", "prefix", "root", "bin", "whoami", "ping", "doctor", "fund", "explain", "why", "query",
        "docs", "home", "bugs", "repo", "issues", "owner", "author", "access", "team", "token", "profile",
        "login", "logout", "adduser", "add-user", "cache", "completion", "help-search", "diff", "sbom",
        "star", "stars", "unstar", "deprecate", "dist-tag", "dist-tags", "hook", "org", "get",
    ]
    static let runVerbs: Set<String> = ["run", "run-script", "rum", "urn"]

    private static func readNpmVerb(_ verb: String, _ rest: [String], into reading: inout Reading) {
        // Only `run <name>` depends on which word is positional: an unknown
        // flag there may swallow the name. Elsewhere npm reads unknown
        // flags as config (`npm test --runInBand`); dangerous ones were
        // already caught by the trailing scan.
        var probe = Reading()
        let first = firstPositional(rest, into: &probe)
        switch verb {
        case _ where runVerbs.contains(verb):
            if probe.unresolvable { reading.unresolvable = true }
            if let name = first { reading.explicit.append(name) }
        case "test", "t", "tst": reading.explicit.append("test")
        case "start", "stop": reading.explicit.append(verb)
        case "restart": reading.explicit += ["restart", "stop", "start"]
        case "install-test", "it", "install-ci-test", "cit": reading.explicit += installLifecycle + ["test"]
        case _ where npmInstallVerbs.contains(verb): reading.explicit += installLifecycle
        case "pack": reading.explicit += packLifecycle
        case "publish": reading.explicit += publishLifecycle
        case "version", "verison": reading.explicit += versionLifecycle
        case "audit":
            if first == "fix" { reading.explicit += installLifecycle }
        case "config", "c":
            if !["get", "list", "ls"].contains(first ?? "list") { reading.unresolvable = true }
        case "pkg":
            if first != "get" { reading.unresolvable = true }
        case _ where npmReadOnlyVerbs.contains(verb):
            break
        default:
            // exec/x/init/create/explore/edit/set, abbreviations, camelCase.
            reading.unresolvable = true
        }
    }

    static let yarnInstallVerbs: Set<String> = [
        "install", "add", "remove", "upgrade", "up", "upgrade-interactive", "import", "link", "unlink",
        "dedupe", "rebuild",
    ]
    static let yarnReadOnlyVerbs: Set<String> = [
        "info", "list", "why", "outdated", "help", "versions", "bin", "cache", "licenses", "owner", "team",
        "login", "logout", "audit", "check", "tag", "autoclean", "generate-lock-entry", "explain",
    ]
    static let yarnUnresolvedVerbs: Set<String> = [
        "dlx", "exec", "node", "create", "plugin", "set", "workspace", "workspaces", "patch",
        "patch-commit", "unplug", "constraints", "global", "policies", "init", "stage", "sdks",
    ]

    private static func readYarnVerb(_ verb: String, _ rest: [String], into reading: inout Reading) {
        var probe = Reading()
        let first = firstPositional(rest, into: &probe)
        switch verb {
        case "run": readRunName(rest, into: &reading)
        case _ where yarnInstallVerbs.contains(verb): reading.explicit += installLifecycle
        case "pack": reading.explicit += packLifecycle
        case "publish": reading.explicit += publishLifecycle
        case "version": reading.explicit += versionLifecycle
        case "config":
            if !["get", "list"].contains(first ?? "list") { reading.unresolvable = true }
        case "npm":
            switch first {
            case "info", "whoami", "login", "logout", "audit", "tag": break
            case "publish": reading.explicit += publishLifecycle
            default: reading.unresolvable = true
            }
        case _ where yarnReadOnlyVerbs.contains(verb): break
        case _ where yarnUnresolvedVerbs.contains(verb): reading.unresolvable = true
        default: reading.implicit.append(verb)
        }
    }

    static let pnpmInstallVerbs: Set<String> = [
        "install", "i", "add", "update", "up", "upgrade", "remove", "rm", "uninstall", "un", "link", "ln",
        "unlink", "dedupe", "prune", "rebuild", "rb", "import", "fetch", "deploy",
    ]
    static let pnpmReadOnlyVerbs: Set<String> = [
        "ls", "list", "ll", "la", "why", "outdated", "audit", "root", "bin", "store", "help", "licenses",
        "view", "info", "show", "doctor",
    ]
    static let pnpmUnresolvedVerbs: Set<String> = [
        "exec", "dlx", "create", "env", "setup", "self-update", "server", "patch", "patch-commit", "init",
        "approve-builds", "x",
    ]

    private static func readPnpmVerb(_ verb: String, _ rest: [String], into reading: inout Reading) {
        var probe = Reading()
        let first = firstPositional(rest, into: &probe)
        switch verb {
        case "run", "run-script":
            if let name = firstPositional(rest, into: &reading) { reading.explicit.append(name) }
        case "test", "t", "tst": reading.explicit.append("test")
        case "start": reading.explicit.append("start")
        case "restart": reading.explicit += ["restart", "stop", "start"]
        case "install-test", "it": reading.explicit += installLifecycle + ["test"]
        case _ where pnpmInstallVerbs.contains(verb): reading.explicit += installLifecycle
        case "pack": reading.explicit += packLifecycle
        case "publish": reading.explicit += publishLifecycle
        case "config", "c":
            if !["get", "list"].contains(first ?? "list") { reading.unresolvable = true }
        case _ where pnpmReadOnlyVerbs.contains(verb): break
        case _ where pnpmUnresolvedVerbs.contains(verb): reading.unresolvable = true
        default: reading.implicit.append(verb)
        }
    }

    static let bunInstallVerbs: Set<String> = ["install", "i", "add", "a", "remove", "rm", "update", "link", "unlink"]
    static let bunReadOnlyVerbs: Set<String> = ["info", "outdated", "why", "audit", "help", "test", "build"]
    static let bunUnresolvedVerbs: Set<String> = ["x", "exec", "create", "c", "init", "upgrade", "pm", "repl", "patch"]

    private static func readBunVerb(_ verb: String, _ rest: [String], into reading: inout Reading) {
        switch verb {
        case "run": readRunName(rest, into: &reading, filesAreNotScripts: true)
        case _ where bunInstallVerbs.contains(verb): reading.explicit += installLifecycle
        case "publish": reading.explicit += publishLifecycle
        case _ where bunReadOnlyVerbs.contains(verb): break
        case _ where bunUnresolvedVerbs.contains(verb): reading.unresolvable = true
        // `bun ./x.ts` runs a file, like `node x.js`: not a package script.
        case _ where looksLikeFile(verb): break
        default: reading.implicit.append(verb)
        }
    }

    /// `yarn run <name>` / `bun run <name>`: a script when it is a key,
    /// otherwise a package bin (unresolved). `bun run ./x.ts` is a file.
    private static func readRunName(_ rest: [String], into reading: inout Reading, filesAreNotScripts: Bool = false) {
        guard let name = firstPositional(rest, into: &reading) else { return }
        if filesAreNotScripts, looksLikeFile(name) { return }
        reading.implicit.append(name)
    }

    /// The first word after the verb that is not a flag or a flag's value.
    /// Runner flags there (`pnpm run --filter app test`) apply to the
    /// runner; an unknown one may take the next word, so it is unresolvable.
    private static func firstPositional(_ rest: [String], into reading: inout Reading) -> String? {
        var index = 0
        while index < rest.count, isFlag(rest[index]) {
            index = consumeFlag(at: index, in: rest, into: &reading, strict: true)
        }
        return index < rest.count ? rest[index] : nil
    }

    /// `node --run <name>` runs `scripts.<name>` (no pre/post, but reading
    /// them too only adds bodies to judge).
    private static func readNodeRun(_ words: [String]) -> Reading? {
        for (index, word) in words.prefix(while: { $0 != "--" }).enumerated() {
            if word == "--run" {
                guard index + 1 < words.count else { return Reading(unresolvable: true) }
                return Reading(explicit: [words[index + 1]])
            }
            if word.hasPrefix("--run=") { return Reading(explicit: [String(word.dropFirst(6))]) }
            if !isFlag(word) { return nil }
        }
        return nil
    }

    // MARK: - Flags

    /// Exact flags that move the package root the scripts are read from.
    static let prefixFlags: Set<String> = ["--prefix", "--dir", "--cwd", "-C"]
    /// Full names whose (nopt-abbreviated) spelling runs scripts in other
    /// packages, swaps the shell, preloads code, or moves the config.
    static let dangerousLongNames = [
        "prefix", "dir", "cwd", "script-shell", "node-options", "userconfig", "globalconfig", "npmrc",
        "preload", "workspace", "workspaces", "include-workspace-root", "workspace-root", "recursive",
        "filter", "filter-prod", "global", "location", "shell-emulator", "shell", "require", "config",
        "call", "eval", "print", "loader", "import", "experimental-loader", "env-file", "conditions",
        "use-node-version", "node-linker", "package-import-method",
    ]
    /// Short letters for workspace/recursive/filter/global/call/prefix.
    static let dangerousShortLetters: Set<Character> = ["w", "r", "F", "g", "c", "C"]
    static let knownValuelessLongNames: Set<String> = [
        "silent", "quiet", "verbose", "json", "parseable", "long", "if-present", "ignore-scripts", "offline",
        "prefer-offline", "prefer-online", "frozen-lockfile", "immutable", "pure-lockfile", "production",
        "prod", "dev", "save", "save-dev", "save-exact", "save-optional", "save-prod", "save-peer", "no-save",
        "force", "legacy-peer-deps", "strict-peer-deps", "no-audit", "audit", "no-fund", "fund",
        "non-interactive", "no-progress", "progress", "no-color", "stream", "parallel", "aggregate-output",
        "help", "version", "yes", "dry-run", "check-files", "flat", "exact", "tilde", "optional", "peer",
        "no-lockfile", "no-optional", "skip-integrity-check", "ignore-engines", "ignore-optional",
        "ignore-platform", "prefer-dedupe", "bail", "watch", "coverage", "update-checksums",
        "check-cache", "inline-builds", "no-bin-links", "foreground-scripts", "no-foreground-scripts",
    ]
    static let knownValuedLongNames: Set<String> = [
        "loglevel", "registry", "tag", "otp", "access", "scope", "reporter", "depth", "omit", "include",
        "before", "network-concurrency", "cache-folder", "mutex", "modules-folder", "color",
        "workspace-concurrency", "mode", "network-timeout", "link-folder", "child-concurrency",
    ]
    static let knownShortFlags: Set<String> = [
        "-s", "-q", "-d", "-dd", "-ddd", "-D", "-E", "-P", "-O", "-S", "-B", "-f", "-y", "-h", "-v", "-l",
    ]

    static func isFlag(_ word: String) -> Bool { word.hasPrefix("-") && word != "-" }

    /// Reads one flag at `index`, returning the index after it (and its
    /// value). `strict`: an unknown flag before the verb is unresolvable,
    /// since it may take the next word as its value.
    private static func consumeFlag(at index: Int, in words: [String], into reading: inout Reading, strict: Bool) -> Int {
        let word = words[index]
        let parts = word.split(separator: "=", maxSplits: 1).map(String.init)
        let name = parts[0]
        let hasValue = parts.count == 2
        if prefixFlags.contains(name) {
            if hasValue { reading.prefixDir = parts[1]; return index + 1 }
            guard index + 1 < words.count else { reading.unresolvable = true; return index + 1 }
            reading.prefixDir = words[index + 1]
            return index + 2
        }
        if isDangerous(name) { reading.unresolvable = true; return index + 1 }
        let long = name.hasPrefix("--") ? String(name.dropFirst(2)) : nil
        if let long, knownValuedLongNames.contains(long) {
            return hasValue ? index + 1 : index + 2
        }
        if let long, knownValuelessLongNames.contains(long) { return index + 1 }
        if long == nil, knownShortFlags.contains(name) { return index + 1 }
        // Unknown: with `=value` it consumes nothing; without, the next
        // word may be its value.
        if strict, !hasValue { reading.unresolvable = true }
        return index + 1
    }

    /// npm rescans every flag before `--`: dangerous spellings and prefix
    /// flags anywhere count.
    private static func scanTrailingFlags(_ rest: [String], into reading: inout Reading) {
        var index = 0
        while index < rest.count {
            guard isFlag(rest[index]) else { index += 1; continue }
            index = consumeFlag(at: index, in: rest, into: &reading, strict: false)
        }
    }

    static func isDangerous(_ flag: String) -> Bool {
        if flag.hasPrefix("--") {
            var name = String(flag.dropFirst(2)).lowercased()
            if knownValuelessLongNames.contains(name) || knownValuedLongNames.contains(name) { return false }
            if name.hasPrefix("no-") { name = String(name.dropFirst(3)) }
            guard !name.isEmpty else { return false }
            return dangerousLongNames.contains { $0.hasPrefix(name) || name.hasPrefix($0) }
        }
        let letters = flag.dropFirst()
        if knownShortFlags.contains(flag) { return false }
        if letters.contains(where: dangerousShortLetters.contains) { return true }
        // `-prefix=x`: nopt may read a multi-letter single-dash word as a
        // long option.
        let name = String(letters).lowercased()
        return name.count > 1 && dangerousLongNames.contains { $0.hasPrefix(name) || name.hasPrefix($0) }
    }

    // MARK: - Words

    static func basename(_ token: String) -> String {
        token.split(separator: "/").last.map(String.init) ?? token
    }

    private static func looksLikeFile(_ word: String) -> Bool {
        word.contains("/") || word.contains(".")
    }
}
