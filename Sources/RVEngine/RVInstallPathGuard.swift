#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain

/// The agent rv guards must not stop or replace rvd through its files.
///
/// rv's install is what rvd runs from and how it is started:
/// `~/.local/bin/{rv,rvd,rv-*,…}` (rvd's IdleWatchdog exits when its
/// executable is replaced), the `dev.rv.*` LaunchAgent plists, everything
/// under `~/.config/systemd/user` (rv's unit and any unit or drop-in that
/// could conflict with it), `~/Applications/RVApprovals.app`, and the
/// Linux socket dir `$XDG_RUNTIME_DIR/rv`. (The macOS socket lives under
/// `~/.config/rv`, which `core.secrets:home-rv-config` already guards.)
///
/// `touchesInstall` is true when a shell command may write, move or remove
/// one of these. A directory or ancestor hit (`~`, `~/.local`,
/// `~/.local/bin`, `~/Library/LaunchAgents`, `/`) counts only for a
/// destructive program (`rm`, `mv`, `cp`, `ln`, `chmod`, `chown`,
/// `chflags`, `find -delete`/`-exec rm`, `rsync --delete`, `tar -x -C`,
/// …); an exact install file counts for any of those or a redirect onto it.
/// A `$(…)` substitution or `xargs` that feeds a destructive program and
/// names the install is held too. `~`, `$HOME`, `$XDG_RUNTIME_DIR`,
/// in-command `cd`, and `env -C`/`sudo -D` are resolved; globs are matched;
/// a variable inside a path may be any components. An assignment word
/// (`PATH=$HOME/.local/bin …`) is a value, not a path operand. A path held
/// entirely in a variable (`rm "$f"`) is not resolvable and is not flagged
/// unless the command assigns it. Reads (`ls`, `cat`, `stat`, `rg`, `open`,
/// `git`, running `~/.local/bin/rv`) stay allowed.
public enum RVInstallPathGuard {
    public static func touchesInstall(_ command: ShellCommand, home: HomePath?, cwd: WorkingDirectory?) -> Bool {
        let raw = command.rawValue
        let model = InstallPathModel(home: home)
        let launched = launchedCommandHeads(raw).filter { $0.truncated == false }
        let bases = trackedBases(launched, raw: raw, cwd: cwd, model: model)
        for command in launched where isDestructive(command) {
            let operands = command.guardArgv.dropFirst().filter { isAssignmentWord($0) == false }
            if operands.contains(where: { model.touches(word: $0, bases: bases) }) { return true }
        }
        // A redirect writes its exact target, even with no command (`> rvd`).
        if redirectTargets(raw).contains(where: { model.touchesExact(word: $0, bases: bases) }) { return true }
        // An assignment or `xargs` input that names an exact install file,
        // beside a destructive program (`f=~/.local/bin/rvd; rm $f`).
        if launched.contains(where: isDestructive),
           anchoredWords(raw).contains(where: { model.isProtected(word: $0, bases: nil) }) {
            return true
        }
        // A `$(…)`/xargs source that names the install fed to a destructive
        // program (`rm $(which rvd)`, `ls ~/.local/bin | xargs rm`).
        return feedsInstall(raw, launched: launched)
    }

    /// File door: whether a write or edit of `path` lands in rv's install.
    public static func isInstallFile(_ path: String, home: HomePath?) -> Bool {
        InstallPathModel(home: home).isProtected(word: path, bases: nil)
    }

    /// File door: a write or edit of `path`, or of what it resolves to (a
    /// symlink into the install is no way around), lands in rv's install.
    public static func writesInstall(_ path: String, resolution: SecretPathResolution?, home: HomePath?) -> Bool {
        let resolved = resolution?.resolve(path)
        return ([path] + (resolved.map { [$0] } ?? [])).contains { isInstallFile($0, home: home) }
    }
}

// MARK: commands

/// Programs that write, move or remove a path operand (directories too), so
/// a hit on an install file or a directory holding one is a mutation.
/// Everything else (readers, `make`, `docker`, `git`, viewers like `open`)
/// never mutates its operands here. `launchctl`/`systemctl` are
/// `RVDStopGuard`'s; `rv` is `SelfProtectionGuard`'s.
private let destructivePrograms: Set<String> = [
    "rm", "rmdir", "unlink", "mv", "cp", "ln", "link", "chmod", "chown", "chgrp", "chflags",
    "install", "rsync", "dd", "tee", "truncate", "touch", "shred", "ditto", "rename", "mkfifo",
]

private let findActions: Set<String> = [
    "-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls",
]

/// Whether `command` mutates a path operand. A dynamic head may be `rm`
/// (fail closed). `find`, `tar`, `curl`/`wget`, `plutil`, `sed`, `defaults`
/// mutate only in certain forms.
private func isDestructive(_ command: LaunchedCommand) -> Bool {
    guard command.headIsDynamic == false, let program = command.guardArgv.first else { return true }
    let args = command.guardArgv.dropFirst()
    func hasDynamic() -> Bool { args.contains { $0.contains(where: { $0 == "$" || $0 == "`" }) } }
    switch program {
    case "find":
        return args.contains { findActions.contains(foldedWord($0)) } || hasDynamic()
    case "tar":
        // Extraction (`-x`) overwrites; create/list do not.
        return args.contains { arg in
            let f = foldedWord(arg)
            return f == "--extract" || (f.hasPrefix("-") && f.hasPrefix("--") == false && f.contains("x"))
        } || hasDynamic()
    case "curl", "wget":
        return args.contains { ["-o", "-O", "--output", "--remote-name", "--output-document"].contains(foldedWord($0)) }
    case "plutil":
        return args.contains { ["-replace", "-insert", "-remove", "-convert"].contains(foldedWord($0)) }
    case "sed":
        return args.contains { foldedWord($0) == "-i" || foldedWord($0).hasPrefix("-i") && foldedWord($0).hasPrefix("--") == false }
    case "defaults":
        return args.first.map { ["write", "delete", "import", "rename"].contains(foldedWord($0)) } ?? false
    default:
        return destructivePrograms.contains(program)
    }
}

/// `2>&1` → `1`, `>file` → `file`, a bare operator → "".
private func redirectTarget(_ word: String) -> String {
    var rest = Substring(word)
    rest = rest.drop(while: \.isNumber)
    if rest.first == "&" { rest = rest.dropFirst() }
    rest = rest.drop(while: { $0 == "<" || $0 == ">" })
    if rest.first == "&" || rest.first == "|" { rest = rest.dropFirst() }
    return String(rest)
}

/// Every output-redirect target in `raw`, across all segments, even a
/// segment with no command (`cd dir; > rvd`). The resolve() path drops a
/// commandless redirect, so this scans the tokens directly.
private func redirectTargets(_ raw: String) -> [String] {
    var targets: [String] = []
    for segment in splitSegments(raw) {
        let tokens = ShellPipeline.tokenize(segment).filter { $0.isNewline == false }
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let skip = token.wasQuoted ? 0 : redirectWordCount(token.lexeme)
            guard skip > 0, token.lexeme.contains("<") == false else { index += max(skip, 1); continue }
            if skip == 1 {
                targets.append(redirectTarget(token.lexeme))
            } else if index + 1 < tokens.count {
                targets.append(tokens[index + 1].lexeme)
            }
            index += skip
        }
    }
    return targets
}

/// A `$(…)`/backtick substitution or an `xargs` pipeline that feeds a
/// destructive program and names rv's install (`rm $(which rvd)`,
/// `ls ~/.local/bin | xargs rm`). Coarse by design: it only raises the bar.
private func feedsInstall(_ raw: String, launched: [LaunchedCommand]) -> Bool {
    for command in launched where isDestructive(command) {
        if command.guardArgv.dropFirst().contains(where: { carriesSubstitution($0) && mentionsInstall($0) }) {
            return true
        }
    }
    // `… | xargs <destructive>`: the destructive program is xargs's operand,
    // so it is not a launched command of its own. The producer text names it.
    let xargsDestructive = launched.contains { command in
        guard command.headIsDynamic == false, command.guardArgv.first == "xargs" else { return false }
        return command.guardArgv.dropFirst().contains { isDestructiveName($0) }
    }
    return xargsDestructive && mentionsInstall(raw)
}

private func isDestructiveName(_ word: String) -> Bool {
    destructivePrograms.contains(commandName(word))
}

/// Install tokens in free text (a substitution body or a pipe producer):
/// the binary names, an install directory, or a `which`/`command -v` of rv.
private func mentionsInstall(_ text: String) -> Bool {
    let folded = text.folding(options: .caseInsensitive, locale: nil)
    if ["rvd", "dev.rv", ".local/bin/rv", "launchagents/dev.rv", "/rv\"", "/rv'", "which rv",
        "command -v rv", "-name rv"].contains(where: { folded.contains($0) }) {
        return true
    }
    return folded.hasSuffix("/rv") || folded.contains(".local/bin")
}

/// Directories relative words may resolve against: the hook cwd plus every
/// `cd`/`pushd` target and every `env -C`/`env --chdir`/`sudo -D` directory.
/// Nil when one is unknown (relative words then match any directory, fail
/// closed).
private func trackedBases(
    _ launched: [LaunchedCommand], raw: String, cwd: WorkingDirectory?, model: InstallPathModel
) -> [[Comp]]? {
    guard let cwd else { return nil }
    var bases = [model.components(of: cwd.rawValue, bases: nil).first ?? []]
    func add(_ target: String) -> Bool {
        let resolved = model.components(of: unescapeBackslashPairs(target), bases: bases)
        if resolved.isEmpty || resolved.contains(where: { $0.contains(.any) }) { return false }
        bases.append(contentsOf: resolved)
        return bases.count <= maxBases
    }
    for command in launched where command.guardArgv.first == "cd" || command.guardArgv.first == "pushd" {
        guard command.headIsDynamic == false else { return nil }
        // `cd -` returns to a directory this command never names.
        if command.guardArgv.contains("-") { return nil }
        let targets = command.guardArgv.dropFirst().filter { $0.hasPrefix("-") == false }
        guard let target = targets.first else {
            guard let home = model.homeComponents else { return nil }
            bases.append(home.map(Comp.name))
            continue
        }
        guard add(target) else { return nil }
    }
    for dir in chdirLauncherDirs(raw) where add(dir) == false { return nil }
    return bases
}

/// `env -C dir`, `env --chdir dir`/`--chdir=dir`, `sudo -D dir`: the
/// directory a launcher runs its command from, so relative operands resolve
/// against it just like `cd`. The flag case is significant (`-C`/`-D`, not
/// a shell `-c`), and only in a segment that runs `env`/`sudo`.
private func chdirLauncherDirs(_ raw: String) -> [String] {
    var dirs: [String] = []
    for segment in splitSegments(raw) {
        let words = ShellPipeline.tokenize(segment).filter { $0.isNewline == false }.map { unescapeBackslashPairs($0.lexeme) }
        guard words.contains(where: { ["env", "sudo"].contains(commandName($0)) }) else { continue }
        var index = 0
        while index < words.count {
            let word = words[index]
            let next = index + 1 < words.count ? words[index + 1] : nil
            if word.hasPrefix("--chdir=") {
                dirs.append(String(word.drop(while: { $0 != "=" }).dropFirst()))
            } else if (word == "-C" || word == "-D" || word == "--chdir"), let next, next.hasPrefix("-") == false {
                dirs.append(next)
                index += 1
            }
            index += 1
        }
    }
    return dirs
}

private let maxBases = 32

/// Raw-text words that spell an absolute or home-anchored path.
private func anchoredWords(_ raw: String) -> [String] {
    raw.split(whereSeparator: { anchoredWordBreaks.contains($0) })
        .map { unescapeBackslashPairs(String($0)) }
        .filter { $0.hasPrefix("/") || $0.hasPrefix("~") || $0.hasPrefix("$HOME") || $0.hasPrefix("${HOME}")
            || $0.hasPrefix("$XDG_RUNTIME_DIR") || $0.hasPrefix("${XDG_RUNTIME_DIR}") }
}

private let anchoredWordBreaks: Set<Character> = [
    " ", "\t", "\n", "\r", ";", "|", "&", "(", ")", "<", ">", "'", "\"", "`", "=", ",",
]

// MARK: path model

/// One path component as the shell may expand it.
enum Comp: Equatable {
    /// A literal name, case-folded (APFS is case-insensitive).
    case name(String)
    /// A glob for one component.
    case glob(String)
    /// A variable or substitution: zero or more components.
    case any
}

/// What one template position accepts.
private enum Slot {
    case fixed(String)
    case binary
    case rvJob
    case anyOne
}

/// rv's install as component templates (`~` already a prefix).
private struct InstallPathModel {
    let homeComponents: [String]?
    let sequences: [(slots: [Slot], anchorCount: Int)]

    init(home: HomePath?) {
        let known = home.map { foldedComponents($0.rawValue) }
        homeComponents = known
        var homes: [[Slot]] = [
            [.fixed("users"), .anyOne], [.fixed("home"), .anyOne], [.fixed("root")], [.fixed("var"), .fixed("root")],
            [.fixed("private"), .fixed("var"), .fixed("root")],
            [.fixed("system"), .fixed("volumes"), .fixed("data"), .fixed("users"), .anyOne],
        ]
        if let known { homes.insert(known.map(Slot.fixed), at: 0) }
        let tails: [[Slot]] = [
            [.fixed(".local"), .fixed("bin"), .binary],
            [.fixed("library"), .fixed("launchagents"), .rvJob],
            [.fixed(".config"), .fixed("systemd"), .fixed("user"), .anyOne],
            // Further systemd unit search dirs, scoped to rv's `dev.rv.*` unit
            // and its `.d` drop-ins (not every unit there).
            [.fixed(".config"), .fixed("systemd"), .fixed("user.control"), .rvJob],
            [.fixed(".local"), .fixed("share"), .fixed("systemd"), .fixed("user"), .rvJob],
            [.fixed("applications"), .fixed("rvapprovals.app")],
        ]
        var sequences = homes.flatMap { home in tails.map { (home + $0, home.count) } }
        sequences.append(([.fixed("run"), .fixed("user"), .anyOne, .fixed("rv")], 3))
        // System and runtime systemd dirs, rv's unit only.
        sequences.append(([.fixed("etc"), .fixed("systemd"), .fixed("user"), .rvJob], 3))
        sequences.append(([.fixed("run"), .fixed("user"), .anyOne, .fixed("systemd"), .fixed("user"), .rvJob], 3))
        sequences.append(([.fixed("run"), .fixed("user"), .anyOne, .fixed("systemd"), .fixed("transient"), .rvJob], 3))
        self.sequences = sequences
    }

    /// A protected path, a directory holding one, or (with unknown bases)
    /// a relative spelling of either.
    func touches(word: String, bases: [[Comp]]?) -> Bool {
        candidates(of: word).contains { candidate in
            components(of: candidate, bases: bases, relativeUnknown: { relative in
                matchesSuffix(relative, ancestors: true)
            }).contains { protects($0) || isAncestor($0) }
        }
    }

    func isProtected(word: String, bases: [[Comp]]?) -> Bool {
        components(of: unescapeBackslashPairs(word), bases: bases, relativeUnknown: { relative in
            matchesSuffix(relative, ancestors: false)
        }).contains(where: protects)
    }

    /// An exact install file (not a directory holding one): for a redirect
    /// target, which always names a file.
    func touchesExact(word: String, bases: [[Comp]]?) -> Bool {
        candidates(of: word).contains { candidate in
            components(of: candidate, bases: bases, relativeUnknown: { matchesSuffix($0, ancestors: false) })
                .contains(where: protects)
        }
    }

    /// Absolute components of `word` against each base. A relative word
    /// with unknown bases is decided by `relativeUnknown` and yields
    /// `[[.any]]` when it matches (so callers see a hit), else nothing.
    func components(
        of word: String, bases: [[Comp]]?, relativeUnknown: (([Comp]) -> Bool)? = nil
    ) -> [[Comp]] {
        let expanded = expandAnchors(word)
        let spellings = SecretPathGlob.expandBraces(expanded, limit: SecretPathGlob.expansionLimit) ?? [expanded]
        return spellings.flatMap { spelling -> [[Comp]] in
            let comps = splitComponents(spelling)
            if spelling.hasPrefix("/") { return [collapsed(comps)] }
            // A relative word with blanks is program text or a message, not a path.
            if spelling.contains(where: \.isWhitespace) { return [] }
            // A word that is nothing but a variable cannot be resolved.
            if comps.allSatisfy({ $0 == .any }) { return [] }
            // A leading variable may hold any directory, absolute or not.
            let unanchored = relativeUnknown?(collapsed(comps, relative: true)) == true ? [[Comp.any]] : []
            if comps.first == .any { return unanchored }
            guard let bases else { return unanchored }
            return bases.map { collapsed($0 + comps) }
        }
    }

    private func candidates(of word: String) -> [String] {
        let unescaped = unescapeBackslashPairs(word)
        var out = [unescaped]
        if let equals = unescaped.firstIndex(of: "=") {
            out.append(String(unescaped[unescaped.index(after: equals)...]))
        }
        if unescaped.hasPrefix("-"), unescaped.hasPrefix("--") == false, unescaped.count > 2 {
            out.append(String(unescaped.dropFirst(2)))
        }
        return out
    }

    private func expandAnchors(_ word: String) -> String {
        let home = homeComponents.map { "/" + $0.joined(separator: "/") } ?? "/users/~"
        for (anchor, value) in [("${HOME}", home), ("$HOME", home), ("${XDG_RUNTIME_DIR}", "/run/user/xdg"),
                                ("$XDG_RUNTIME_DIR", "/run/user/xdg")] {
            if word == anchor || word.hasPrefix(anchor + "/") { return value + word.dropFirst(anchor.count) }
        }
        if word == "~" || word.hasPrefix("~/") { return home + word.dropFirst(1) }
        // `~user/...`: some user's home.
        if word.hasPrefix("~") { return "/users/" + word.dropFirst(1) }
        return word
    }

    private func protects(_ comps: [Comp]) -> Bool {
        if comps == [.any] { return true }
        return sequences.contains { matches(comps[...], $0.slots[...], extraAllowed: true) }
    }

    private func isAncestor(_ comps: [Comp]) -> Bool {
        sequences.contains { sequence in
            (0..<sequence.slots.count).contains { matches(comps[...], sequence.slots[..<$0], extraAllowed: false) }
        }
    }

    /// A relative word under an unknown directory: a tail of a protected
    /// path (or of a directory holding one, past the home or run prefix).
    /// The word must name part of the install literally (`rvd`, `bin`):
    /// a bare glob or `{}` under an unknown directory is not judged.
    private func matchesSuffix(_ comps: [Comp], ancestors: Bool) -> Bool {
        guard comps.contains(where: namesInstallPart) else { return false }
        return sequences.contains { sequence in
            let slots = sequence.slots
            return (1..<slots.count).contains { start in
                // A tail of nothing but "any name" would match every word.
                guard slots[start...].contains(where: { if case .anyOne = $0 { false } else { true } }) else {
                    return false
                }
                if matches(comps[...], slots[start...], extraAllowed: true) { return true }
                guard ancestors else { return false }
                let firstEnd = max(start, sequence.anchorCount) + 1
                guard firstEnd < slots.count else { return false }
                return (firstEnd..<slots.count).contains { matches(comps[...], slots[start..<$0], extraAllowed: false) }
            }
        }
    }
}

/// Whether `comps` spell `slots` (`.any` stands for zero or more
/// components; `extraAllowed` admits descendants). Table-driven, so a word
/// of many variables stays linear.
private func namesInstallPart(_ comp: Comp) -> Bool {
    guard case .name(let name) = comp else { return false }
    return installParts.contains(name) || isInstalledBinary(name) || name.hasPrefix("dev.rv.")
}

private let installParts: Set<String> = [
    ".local", "bin", "library", "launchagents", ".config", "systemd", "user", "applications",
    "rvapprovals.app", "run", "rv", "share", "user.control", "transient", "etc",
]

private func matches(_ comps: ArraySlice<Comp>, _ slots: ArraySlice<Slot>, extraAllowed: Bool) -> Bool {
    let comps = Array(comps)
    let slots = Array(slots)
    let (n, m) = (comps.count, slots.count)
    // row[j] holds f(i + 1, j) while row i is built.
    var next = [Bool](repeating: false, count: m + 1)
    next[m] = true
    for i in stride(from: n - 1, through: 0, by: -1) {
        var row = [Bool](repeating: false, count: m + 1)
        for j in stride(from: m, through: 0, by: -1) {
            if comps[i] == .any {
                row[j] = next[j] || (j < m && row[j + 1])
            } else if j == m {
                row[j] = extraAllowed
            } else {
                row[j] = accepts(slots[j], comps[i]) && next[j + 1]
            }
        }
        next = row
    }
    return next[0]
}

private func accepts(_ slot: Slot, _ comp: Comp) -> Bool {
    switch (slot, comp) {
    case (_, .any), (.anyOne, _):
        return true
    case (.fixed(let name), .name(let value)):
        return name == value
    case (.fixed(let name), .glob(let pattern)):
        return globMatches(pattern, name)
    case (.binary, .name(let value)):
        return isInstalledBinary(value)
    case (.binary, .glob(let pattern)):
        return binarySamples.contains { globMatches(pattern, $0) }
    case (.rvJob, .name(let value)):
        return value.hasPrefix("dev.rv.")
    case (.rvJob, .glob(let pattern)):
        return jobSamples.contains { globMatches(pattern, $0) }
    }
}

/// What `install.sh` stages in `~/.local/bin`: `rv`, `rvd`, `rv-*`
/// siblings, their `.installing` temporaries, pack bundles, and the Swift
/// runtime libraries beside them.
private func isInstalledBinary(_ name: String) -> Bool {
    name == "rv" || name == "rvd" || name.hasPrefix("rv-") || name.hasPrefix(".rv")
        || name.contains("_rvpacks.") || name.hasSuffix(".dylib") || name.hasSuffix(".so") || name.contains(".so.")
}

private let binarySamples = [
    "rv", "rvd", "rv-cli", "rv-workspace-host", "rv-isolation-exec", "rv-pty-claim", "rv-microvm",
    "rv-guest-relay", "rv-macvm", "rv-macvm-agent", ".rvd.installing", "rv_rvpacks.bundle",
    "rv_rvpacks.resources", "libswiftcompatibilityspan.dylib", "libswiftcore.so",
]

private let jobSamples = ["dev.rv.evaluate.plist", "dev.rv.mcp-custodian.plist", "dev.rv.audit-forward.plist"]

private func globMatches(_ pattern: String, _ name: String) -> Bool {
    fnmatch(pattern, name, 0) == 0
}

private func foldedComponents(_ path: String) -> [String] {
    path.split(separator: "/").map { String($0).folding(options: .caseInsensitive, locale: nil) }
}

/// Splits after collapsing `$(...)`, `${...}` and backticks (they may hold
/// slashes) into one `$`.
private func splitComponents(_ path: String) -> [Comp] {
    collapsingSubstitutionsForPaths(path).split(separator: "/").map { part in
        let text = String(part).folding(options: .caseInsensitive, locale: nil)
        if text.contains("$") || text.contains("**") { return .any }
        // A brace left after expansion (`{}` from xargs/find) is any one name.
        if text.contains("{") || text.contains("}") { return .glob("*") }
        if text.contains(where: { "*?[".contains($0) }) { return .glob(text) }
        return .name(text)
    }
}

private func collapsed(_ comps: [Comp], relative: Bool = false) -> [Comp] {
    var out: [Comp] = []
    for comp in comps {
        switch comp {
        case .name("."):
            continue
        case .name(".."):
            if let last = out.last, last != .any { out.removeLast() } else if relative { out = [.any] }
        default:
            out.append(comp)
        }
    }
    return out
}

private func collapsingSubstitutionsForPaths(_ word: String) -> String {
    var out = ""
    let chars = Array(word)
    var index = 0
    while index < chars.count {
        let char = chars[index]
        if char == "`" {
            index += 1
            while index < chars.count, chars[index] != "`" { index += 1 }
            index += 1
            out.append("$")
            continue
        }
        if char == "$", index + 1 < chars.count, chars[index + 1] == "(" || chars[index + 1] == "{" {
            let open = chars[index + 1]
            let close: Character = open == "(" ? ")" : "}"
            var depth = 1
            index += 2
            while index < chars.count, depth > 0 {
                if chars[index] == open { depth += 1 } else if chars[index] == close { depth -= 1 }
                index += 1
            }
            out.append("$")
            continue
        }
        out.append(char)
        index += 1
    }
    return out
}
