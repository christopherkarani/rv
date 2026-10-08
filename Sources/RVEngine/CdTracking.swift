import RVDomain

/// Static `cd`/`pushd`/`popd` working-directory tracking across chain
/// segments (P10e8, C-F3). Without this, `cd /tmp && touch evil` classifies
/// `evil` against the hook cwd (inside) while the runtime creates `/tmp/evil`
/// (outside). The tracker folds straight-line directory changes so later
/// segments resolve relative paths against the tracked cwd; anything
/// unmodelable (dynamic target, `-P`, `cd -`, unknown flags, bad stack
/// index) resolves to nil, and a nil cwd fails closed: relative paths can
/// never match the repository prefix, so later relative mutations deny.
///
/// Deliberate limits (documented residuals, all fail-closed except where
/// noted): subshell/paren groups, `&`/`|` boundaries, and substitution
/// inners share the flat segment list, so a `cd` inside them leaks forward
/// (over-approximate deny on bizarre shapes); loop- or conditional-carried
/// `cd` (`do cd …`, `then cd …`) is not modeled (blind: later segments keep
/// the outer cwd); bare-name `cd sub` assumes CDPATH is unset; `cd` through
/// a symlinked directory tracks the logical path (the live probe covers
/// single-segment symlink facts; chains are lexical-only).
struct DirectoryTracker {
    /// Tracked cwd for the current segment; nil means unknown (fail closed).
    var working: String?
    /// Pushd stack, top at the end; entries are nil when unknown.
    var stack: [String?] = []
    let home: String?

    init(working: String?, home: String?) {
        self.working = working
        self.home = home
    }

    /// Applies a `cd`/`pushd`/`popd` segment to the tracked state for LATER
    /// segments. Callers parse the segment itself with the pre-update cwd:
    /// `cd /tmp > f` truncates `f` before changing directory.
    mutating func apply(tokens: [String]) {
        guard tokens.isEmpty == false else { return }
        guard let head = builtinHead(tokens[0]) else {
            // Not a recognized builtin spelling. A slashless head carrying
            // shell metacharacters (backslash escapes, substitutions,
            // ANSI-C, globs, braces) can still resolve to a directory
            // builtin at runtime (`c\d`, `$'cd'`, `$(echo cd)`, `[c]d` all
            // execute `cd`); the decoded token lost the quote positions
            // needed to decide, so poison the tracked state (fail closed)
            // instead of ignoring the move. A literal slash survives every
            // expansion, so slash heads always execute externally (parent
            // cwd unchanged) and stay untracked (`$HOME/bin/x`).
            if isOpaqueHead(tokens[0]) {
                working = nil
                stack = []
            }
            return
        }
        // `command`/`builtin`/`time` prefixes and `!` negation still run
        // the verb in the current shell, but a `command -v`/`-V` query
        // never changes directory (`-p` is not a query: it executes with
        // the default PATH). `sudo`/`env` run the verb in a child: the
        // parent cwd is unchanged, so they stay untracked (no head).
        if head == "command" || head == "builtin" {
            applyCommandPrefix(rest: Array(tokens.dropFirst()))
            return
        }
        if head == "time" {
            // `time [-p] verb...`: -p only formats output; anything else
            // is the verb.
            var rest = Array(tokens.dropFirst())
            while rest.first == "-p" { rest.removeFirst() }
            applyPrefixVerb(rest: rest)
            return
        }
        if head == "!" {
            // Negation takes no options: the verb follows immediately.
            applyPrefixVerb(rest: Array(tokens.dropFirst()))
            return
        }
        if head == "eval" || head == "source" || head == "." {
            // Script execution in the current shell: operands are opaque
            // (a sourced file or eval string can cd arbitrarily).
            working = nil
            stack = []
            return
        }
        if head == "dirs" {
            // `dirs` only displays, except `-c`, which clears the stack
            // (later `popd` becomes a no-op instead of restoring the cwd).
            if tokens.dropFirst().contains("-c") {
                stack = []
            }
            return
        }
        applyVerb(head: head, words: stripWriterRedirectWords(Array(tokens.dropFirst())))
    }

    /// Exact builtin name for a decoded head word, or nil. Matching is
    /// case-sensitive with no path separator: `CD` is not `cd`, and
    /// `/bin/cd` executes an external command in a child (parent cwd
    /// unchanged). Backslash- or substitution-carrying heads never match
    /// here; the caller poisons on those instead of ignoring them.
    private func builtinHead(_ word: String) -> String? {
        guard word.contains("/") == false else { return nil }
        switch word {
        case "cd", "pushd", "popd", "command", "builtin", "dirs",
            "eval", "source", ".", "time", "!":
            return word
        default:
            return nil
        }
    }

    /// True when a non-builtin head could still reach a directory builtin
    /// at runtime: backslash escapes (`c\d`), command substitutions
    /// (`$(...)`, backticks), ANSI-C quotes (`$'...'`), and glob/brace
    /// expansion (`[c]d`, `{curl,}`). Slash heads always execute
    /// externally (a literal slash survives every expansion), so they
    /// are excluded: the parent cwd cannot change beneath them.
    private func isOpaqueHead(_ word: String) -> Bool {
        if word.contains("/") { return false }
        return word.contains("\\") || word.contains("$") || word.contains("`")
            || isGlobBraceHead(word)
    }

    private mutating func applyCommandPrefix(rest: [String]) {
        var rest = rest
        while let first = rest.first, first.hasPrefix("-"), first != "-" {
            if first == "--" {
                rest.removeFirst()
                break
            }
            // Only `-v`/`-V` are non-executing queries. `-p` (default
            // PATH) still runs the command — `command -p cd /tmp` cds —
            // so it falls through to the skip below (M-23).
            if first == "-v" || first == "-V" {
                return
            }
            rest.removeFirst()
        }
        applyPrefixVerb(rest: rest)
    }

    private mutating func applyPrefixVerb(rest: [String]) {
        guard let next = rest.first else { return }
        guard let verb = builtinHead(next) else {
            if isOpaqueHead(next) {
                working = nil
                stack = []
            }
            return
        }
        if verb == "command" || verb == "builtin" || verb == "time" || verb == "!" {
            // Nested prefixes (`command command cd`) are bizarre; the
            // decoded stream cannot cheaply prove the arity, so poison.
            working = nil
            stack = []
            return
        }
        if verb == "eval" || verb == "source" || verb == "." {
            working = nil
            stack = []
            return
        }
        guard verb == "cd" || verb == "pushd" || verb == "popd" else { return }
        applyVerb(head: verb, words: stripWriterRedirectWords(Array(rest.dropFirst())))
    }

    private mutating func applyVerb(head: String, words: [String]) {
        switch head {
        case "cd":
            applyCd(words)
        case "pushd":
            applyPushd(words)
        case "popd":
            applyPopd(words)
        default:
            break
        }
    }

    private mutating func applyCd(_ words: [String]) {
        var args = words
        var physical = false
        while let first = args.first, first.hasPrefix("-"), first != "-" {
            if first == "--" {
                args.removeFirst()
                break
            }
            for letter in first.dropFirst() {
                switch letter {
                case "P":
                    physical = true
                case "L", "e", "q", "s":
                    break
                default:
                    working = nil
                    return
                }
            }
            args.removeFirst()
        }
        if physical {
            working = nil
            return
        }
        switch args.count {
        case 0:
            working = home
        case 1:
            working = resolve(args[0])
        default:
            // `cd a b` substitutes in $PWD: unmodelable without the value.
            working = nil
        }
    }

    private mutating func applyPushd(_ words: [String]) {
        var args = words
        var noCd = false
        while let first = args.first, first == "-n" {
            noCd = true
            args.removeFirst()
        }
        if args.isEmpty {
            if noCd { return }
            // Bare `pushd` swaps the cwd with the stack top; an empty stack
            // is a no-op (bash errors, cwd unchanged).
            if stack.isEmpty == false {
                let top = stack.removeLast()
                stack.append(working)
                working = top
            }
            return
        }
        if args.count == 1, let index = stackIndex(args[0]) {
            rotateBringingToTop(index, fromRight: args[0].hasPrefix("-"))
            return
        }
        if args.count == 1 {
            let dir = resolve(args[0])
            if noCd {
                stack.append(dir)
                return
            }
            stack.append(working)
            working = dir
            return
        }
        working = nil
        stack = []
    }

    private mutating func applyPopd(_ words: [String]) {
        var args = words
        var noCd = false
        while let first = args.first, first == "-n" {
            noCd = true
            args.removeFirst()
        }
        if args.isEmpty {
            // Bare `popd` cds to the popped top; an empty stack is a no-op.
            if let popped = stack.popLast() {
                if noCd == false {
                    working = popped
                }
            }
            return
        }
        if args.count == 1, let index = stackIndex(args[0]) {
            removeStackEntry(index, fromRight: args[0].hasPrefix("-"), noCd: noCd)
            return
        }
        working = nil
        stack = []
    }

    /// DIRSTACK index: `+n` from the left (0 is the cwd), `-n` from the right.
    private func stackIndex(_ word: String) -> Int? {
        guard word.count >= 2 else { return nil }
        let sign = word.first
        guard sign == "+" || sign == "-" else { return nil }
        let digits = String(word.dropFirst())
        guard digits.isEmpty == false, digits.allSatisfy({ $0.isNumber }) else {
            return nil
        }
        return Int(digits)
    }

    private func dirstack() -> [String?] {
        [working] + stack.reversed()
    }

    private mutating func rotateBringingToTop(_ n: Int, fromRight: Bool) {
        var entries = dirstack()
        guard entries.isEmpty == false else { return }
        let index = fromRight ? entries.count - 1 - n : n
        guard index >= 0, index < entries.count else {
            working = nil
            stack = []
            return
        }
        entries = Array(entries[index...]) + entries[..<index]
        working = entries[0]
        stack = Array(entries.dropFirst().reversed())
    }

    private mutating func removeStackEntry(_ n: Int, fromRight: Bool, noCd: Bool) {
        var entries = dirstack()
        guard entries.isEmpty == false else { return }
        let index = fromRight ? entries.count - 1 - n : n
        guard index >= 0, index < entries.count else {
            working = nil
            stack = []
            return
        }
        let keptWorking = working
        entries.remove(at: index)
        if entries.isEmpty {
            working = noCd ? keptWorking : nil
            stack = []
            return
        }
        working = noCd ? keptWorking : entries[0]
        stack = Array(entries.dropFirst().reversed())
    }

    /// Resolves a static directory operand against the tracked cwd. Dynamic
    /// operands, `cd -` ($OLDPWD), other-user homes, and relative operands
    /// under an unknown cwd resolve to nil (fail closed).
    private func resolve(_ dir: String) -> String? {
        if dir == "-" { return nil }
        if dir.hasPrefix("~"), isHomeAliasPath(dir) == false { return nil }
        if dir.contains("$") || dir.contains("`") {
            if isHomeAliasPath(dir) == false { return nil }
        }
        if isHomeAliasPath(dir), home == nil { return nil }
        if dir.hasPrefix("/") == false, working == nil { return nil }
        let workingDirectory = working.flatMap(WorkingDirectory.init(validating:))
        let homeDirectory = home.flatMap(HomePath.init(validating:))
        return lexicalFilesystemPath(
            dir,
            workingDirectory: workingDirectory,
            homeDirectory: homeDirectory
        )
    }
}
