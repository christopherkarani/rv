import Foundation

/// The one work budget for reading text as command lines while judging one
/// command for the MCP host config guard, passed `inout` down every read.
/// Each distinct text is read once; at most `maxReads` texts are read and
/// `maxDepth` quoting levels nested, and a read past either counts as a
/// mutation (fail closed). Text no decoding of which names a host CLI, a
/// group or an installer (`mayNameHostMCP`) is never read, so ordinary
/// commands spend nothing. Text the shell tokenizer cannot follow
/// (`hasUnfollowableShellText`) that may name one counts too. Text scanned
/// as program text (`textNamesHostMCPMutation`) that holds a stem spends
/// pieces: at most `maxTokenPieces` in one text and `maxPieces` in all.
/// Brace and glob spellings spend `spelling` (`SpellingBudget`). A read
/// begun, or a command judged inside one, past `maxWordVisits` counts too,
/// so the work is bounded however the texts nest.
struct HostTextReads {
    static let maxReads = 512
    static let maxDepth = 6
    static let maxTokenPieces = 4_096
    static let maxPieces = 65_536
    /// Measured: no command in the test corpora (85,397 lines) visits more
    /// than 440 words; a visit costs about 6 to 9 microseconds on a loaded
    /// machine, so this ends the worst nested lines in about half a second.
    static let maxWordVisits = 65_536

    private var remaining = HostTextReads.maxReads
    private var depth = 0
    /// Reads begun and not yet finished, nested or flat.
    private var readsInProgress = 0
    private var seen: Set<String> = []
    /// Texts read as command lines so far.
    private(set) var readsDone = 0
    /// Pieces scanned as program text so far.
    private(set) var piecesExamined = 0
    /// A cap was reached, so a read or scan counted as a mutation.
    private(set) var exceeded = false
    /// The cap reached was the nesting depth.
    private(set) var depthExceeded = false
    /// The cap reached was `maxWordVisits`.
    private(set) var visitsExceeded = false
    /// Some text counted because the tokenizer cannot follow it.
    private(set) var unfollowable = false
    /// The read in progress is text nothing runs (`dataOnly`).
    private(set) var inert = false
    /// The read in progress re-splits operands already judged in their own
    /// command (`joinedReadsRun`).
    private(set) var resplit = false
    /// The read in progress is text a command that never runs its operands
    /// carries (`isNonExecutor`, not a printer: a `grep` pattern, a commit
    /// message): only literal words count there, as they did before brace
    /// and glob spellings were resolved.
    private(set) var literal = false
    /// No command on the line, nor in the text being read, may be defined
    /// or redefined (no function, alias, `PATH` change, sourced file,
    /// `eval` or dynamic program: `commandsMayBeRedefined`), so a plain
    /// command name is the program it names. Until the guard has checked
    /// the line it is false, and the operand list (`leavesOperandsAlone`)
    /// does not apply.
    var commandsArePlain = false
    /// The work budget for brace and glob spellings, across every read.
    var spelling = SpellingBudget()
    /// Words `isHostMCPMutation` visited, across every read: a structural
    /// bound on its work (each pass over a command's words counts them).
    private(set) var wordVisits = 0

    /// Test hook: set, each list of text variants (`ordered`) is read in an
    /// order drawn from it, as a per-process hash seed once ordered a `Set`
    /// of them. Nil reads them in the order written.
    var variantOrderSeed: UInt64?

    init() {}

    /// `variants` without repeats, each kept where first written: the order
    /// they are read in is fixed, so the verdict and these counters are the
    /// same in every process (`variantOrderSeed` aside).
    mutating func ordered(_ variants: [String]) -> [String] {
        var out: [String] = []
        for variant in variants where out.contains(variant) == false { out.append(variant) }
        guard var state = variantOrderSeed, out.count > 1 else { return out }
        for index in stride(from: out.count - 1, to: 0, by: -1) {
            // SplitMix64.
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            mixed ^= mixed >> 31
            out.swapAt(index, Int(mixed % UInt64(index + 1)))
        }
        variantOrderSeed = state
        return out
    }

    /// Spends `count` pieces of one text; false (and `exceeded`) past a cap.
    mutating func examine(pieces count: Int) -> Bool {
        guard count <= Self.maxTokenPieces, piecesExamined + count <= Self.maxPieces else {
            exceeded = true
            return false
        }
        piecesExamined += count
        return true
    }

    /// Records text that counted because the tokenizer cannot follow it.
    mutating func noteUnfollowable() {
        unfollowable = true
    }

    /// Counts `count` words visited by one pass of `isHostMCPMutation`;
    /// false (and `visitsExceeded`) past `maxWordVisits` inside a read,
    /// where the command counts. Checked per command, not only where a read
    /// begins: one read launches many commands. The line's own commands,
    /// judged outside any read, are never refused here: its written ones
    /// cost their length, and its speculative ones (a dynamic program's
    /// operand suffixes, quadratic in them) are judged only while under the
    /// ceiling (`admitsSpeculative`).
    mutating func visit(words count: Int) -> Bool {
        wordVisits += count
        guard readsInProgress == 0 || wordVisits < Self.maxWordVisits else {
            exceeded = true
            visitsExceeded = true
            return false
        }
        return true
    }

    /// Whether one more speculative command may be judged: false (and
    /// `visitsExceeded`) at the ceiling, where the command counts.
    mutating func admitsSpeculative() -> Bool {
        guard wordVisits < Self.maxWordVisits else {
            exceeded = true
            visitsExceeded = true
            return false
        }
        return true
    }

    /// Whether `text`, read as a command line, runs a host MCP mutation. A
    /// `nested` read is a word's own quoting level: its words and joined
    /// tails are read in turn (`carriesHostMCPText`). A flat read is a
    /// re-split of words already read one by one (a joined tail): only its
    /// commands are judged. A `dataOnly` read is text nothing runs
    /// (`isInertLine`, `isNonExecutor`); reads inside it are data too. A
    /// `literalOnly` read, and every read inside it, judges literal words
    /// only (`literal`). Text that runs and that the tokenizer cannot follow
    /// counts.
    mutating func runsHostMCPMutation(
        _ text: String, nested: Bool = true, dataOnly: Bool = false, resplit splitting: Bool = false,
        literalOnly: Bool = false
    ) -> Bool {
        let reading = inert || dataOnly
        let literalReading = literal || literalOnly
        // A text is read once per depth: read again deeper, its nested reads
        // may reach `maxDepth` where the shallower read did not, so a
        // shallower copy read first never hides that ask.
        let key = (nested ? "n" : "f") + (reading ? "d" : "r") + (splitting ? "s" : "w")
            + (literalReading ? "l" : "e") + String(depth) + ":" + text
        let mayName = literalReading ? holdsHostMCPStem(text) : mayNameHostMCP(text, budget: &spelling)
        guard mayName, seen.insert(key).inserted else { return false }
        guard remaining > 0, depth < Self.maxDepth, wordVisits < Self.maxWordVisits else {
            exceeded = true
            if depth >= Self.maxDepth { depthExceeded = true }
            if wordVisits >= Self.maxWordVisits { visitsExceeded = true }
            return true
        }
        if reading == false, hasUnfollowableShellText(text) {
            unfollowable = true
            return true
        }
        remaining -= 1
        readsDone += 1
        let outerInert = inert
        let outerResplit = resplit
        let outerLiteral = literal
        let outerPlain = commandsArePlain
        inert = reading
        resplit = splitting
        literal = literalReading
        if nested { depth += 1 }
        readsInProgress += 1
        defer {
            readsInProgress -= 1
            if nested { depth -= 1 }
            inert = outerInert
            resplit = outerResplit
            literal = outerLiteral
            commandsArePlain = outerPlain
        }
        let launched = launchedCommandHeads(text)
        // Carried text may define a command its own heads show and the
        // line's do not (`watch 'alias ls=eval; ls mcp $X'`).
        commandsArePlain = outerPlain && commandsMayBeRedefined(text, launched) == false
        // Text the parser stopped following, or a segment the splitter could
        // not scan (`watch '{claude,x} mcp add'`), may hide a host CLI. A
        // literal read judges words as written, and an unscanned segment
        // has none left (`grep -E '(mcp|claude) add'`).
        if launched.contains(where: { $0.truncated || (literalReading == false && isUnscannedLaunch($0)) }) {
            return true
        }
        if launchedRunHostMCPMutation(launched, reads: &self) { return true }
        guard nested else { return false }
        // Words carried inside this text are not re-splits.
        resplit = false
        return carriesHostMCPText(launched, reads: &self)
    }
}

/// Whether some command of `launched` is a host MCP mutation
/// (`isHostMCPMutation`). A speculative one (`launchedCommandHeads`: a
/// dynamic program as every suffix of its operands, a spaced operand
/// re-parsed) is judged only when some word of it may name a host MCP word
/// (`mayNameHostMCP`, the test every read begins with), each distinct word
/// tested once, and only below the ceiling (`admitsSpeculative`), which
/// asks. A dynamic program's plain operands then cost their length, not
/// its square.
func launchedRunHostMCPMutation(_ launched: [LaunchedCommand], reads: inout HostTextReads) -> Bool {
    var named: [String: Bool] = [:]
    for command in launched {
        if command.speculative, command.truncated == false {
            guard commandMayNameHostMCP(command, budget: &reads.spelling, named: &named) else { continue }
            guard reads.admitsSpeculative() else { return true }
        }
        if isHostMCPMutation(command, reads: &reads) { return true }
    }
    return false
}

/// Whether some word of `command` may name a host MCP word: the prefilter
/// `launchedRunHostMCPMutation` puts before judging a speculative command.
/// `named` caches each distinct word's answer.
///
/// Invariant: it never says no where `isHostMCPMutation` matches the
/// command, as `mayNameHostMCP` never says no for text launching a command
/// it matches (`prefilterCoversFullJudgement`). Each word is tested as text
/// and also spelled whole as the full judgement spells it
/// (`judgedSpellingMayName`), so splitting text never drops a word.
func commandMayNameHostMCP(
    _ command: LaunchedCommand, budget: inout SpellingBudget, named: inout [String: Bool]
) -> Bool {
    for word in [command.head] + command.guardArgv {
        let answer: Bool
        if let known = named[word] {
            answer = known
        } else {
            answer = mayNameHostMCP(word, budget: &budget) || judgedSpellingMayName(word, budget: &budget)
            named[word] = answer
        }
        if answer { return true }
    }
    return false
}

/// Whether the spelling `isHostMCPMutation` gives `word` (folded, and
/// without zsh's leading `=`) may be a word the host CLI checks match, or
/// may be any words.
private func judgedSpellingMayName(_ word: String, budget: inout SpellingBudget) -> Bool {
    let folded = foldedWord(word)
    for name in folded.hasPrefix("=") ? [folded, String(folded.dropFirst())] : [folded] {
        let spelling = WordSpelling.of(name, budget: &budget)
        if spelling.expansions == nil || spellingMayNameTableWord(spelling, budget: &budget) { return true }
    }
    return false
}

/// The heads `launchedCommandHeads` reports for `unscannableSegment`, which
/// the segment splitter puts in place of a segment it could not scan: a
/// head still `{`/`(` that does not peel (`{claude,zzqx} mcp add`), or
/// reserved-word stripping that never settled. That segment's words are gone.
private let unscannedHeads: Set<String> = Set(launchedCommandHeads(unscannableSegment).map(\.head))

/// Whether `command` stands for a segment the splitter could not scan.
func isUnscannedLaunch(_ command: LaunchedCommand) -> Bool {
    unscannedHeads.contains(command.head)
}

/// Whether some text the launched commands carry may, run by a shell,
/// scheduler or interpreter that reads it (`| sh`, `| $SHELL`, `| at now`,
/// `| crontab -`, `$(…)` as the program, `eval`, a here-string), be a host
/// MCP mutation. Any program may be that reader, so no consumer is
/// required. Read as command lines: every word holding whitespace, and its
/// ANSI-C or `printf`/`echo -e` decoded form (`'claude\x20mcp\x20add'`,
/// `$'claude\tmcp'`); each command's operands joined (`echo 'claude mcp'
/// 'add x'`), also without `echo`'s options or `printf`'s format; its argv
/// decoded (`$'\x63laude' mcp add`); and the joined output of every
/// `echo`/`printf`/`print` (`{ printf 'claude '; printf 'mcp add x'; }`).
/// Speculative suffixes of a dynamic program repeat words already read.
/// Given the top-level `line`, text nothing runs is read as data: the
/// words, joined operands and output of a command that never runs its
/// operands (`isNonExecutor`), alone on a line with no pipe, list,
/// redirect, here-string, substitution or parenthesis (`isInertLine`).
func carriesHostMCPText(_ launched: [LaunchedCommand], reads: inout HostTextReads, line: String? = nil) -> Bool {
    let lineInert = line.map { isInertLine($0, launched) } ?? false
    // Output rv cannot read may reach the reader of a printer's text and
    // define a command there (`{ cat ./defs.sh; echo 'ls mcp $X'; } | sh`):
    // beside such a command, a printer's text is never read as plain names.
    let opaqueWriter = launched.contains {
        $0.speculative == false && printers.contains(commandName($0.head)) == false
    }
    let outerPlain = reads.commandsArePlain
    defer { reads.commandsArePlain = outerPlain }
    var printed: [String] = []
    for command in launched where command.speculative == false && command.truncated == false {
        let args = Array(command.argv.dropFirst())
        let values = command.assignments.compactMap { word in
            word.firstIndex(of: "=").map { String(word[word.index(after: $0)...]) }
        }
        let name = commandName(command.head)
        let isPrinter = printers.contains(name)
        reads.commandsArePlain = outerPlain && (isPrinter == false || opaqueWriter == false)
        // Text nothing runs: a plain operand of a non-executor on an inert line.
        let dataOnly = lineInert && isNonExecutor(command)
        // A non-executor that is no printer (`grep`, `rg`, `git commit`):
        // its operands are patterns, paths or messages to it, so only their
        // literal words count. It may still print one (`rg -r TEXT`, `grep
        // --label`); that output is still read literally only. So are the
        // operands of a command that never runs one (`leavesOperandsAlone`:
        // `ls mcp $DIR` re-read as `mcp $DIR`), as written, on a line that
        // defines no command (`commandsArePlain`).
        let operandsStayWords = reads.commandsArePlain && leavesOperandsAlone(command)
        let literalOnly = isPrinter == false && (isNonExecutor(command) || operandsStayWords)
        for word in args + values {
            for variant in reads.ordered([word, word.ansiCDecodedIfMarked, decodedWord(word)])
            where variant.contains(where: \.isWhitespace) {
                if reads.runsHostMCPMutation(variant, dataOnly: dataOnly, literalOnly: literalOnly) { return true }
            }
        }
        var tails = [args]
        if isPrinter {
            let operands = Array(args.drop(while: { $0.hasPrefix("-") }))
            tails.append(operands)
            if name == "printf" { tails.append(Array(operands.dropFirst())) }
            printed.append(contentsOf: operands)
        }
        for tail in tails where tail.isEmpty == false {
            if joinedReadsRun(tail, &reads, dataOnly: dataOnly, literalOnly: literalOnly) { return true }
        }
        let argv = [command.head] + args
        let decoded = argv.map(\.ansiCDecodedIfMarked)
        if decoded != argv,
           reads.runsHostMCPMutation(decoded.joined(separator: " "), nested: false, literalOnly: literalOnly)
        {
            return true
        }
    }
    guard printed.isEmpty == false else { return false }
    reads.commandsArePlain = outerPlain && opaqueWriter == false
    return joinedReadsRun(printed, &reads, dataOnly: lineInert && launched.allSatisfy(isNonExecutor))
}

/// Whether `raw` counts because the tokenizer cannot follow it
/// (`hasUnfollowableShellText`) and it may name a host CLI. An inert line
/// does not: nothing on it runs, and its program and the words
/// `isNonExecutor` reads are read exactly (`isInertLine`).
func hostMCPTextIsUnfollowable(_ raw: String, _ launched: [LaunchedCommand], reads: inout HostTextReads) -> Bool {
    guard hasUnfollowableShellText(raw), mayNameHostMCP(raw, budget: &reads.spelling) else { return false }
    if isInertLine(raw, launched), launched.allSatisfy(isNonExecutor) { return false }
    reads.noteUnfollowable()
    return true
}

/// A line whose text nothing runs: one command, plainly named (no dynamic
/// head, launcher, launcher guess or truncation), with no assignment or
/// redirect, and no pipe, list, background, substitution, redirect,
/// here-string, newline or parenthesis character anywhere in it (a quoted
/// one counts too: fail closed; `(` covers zsh `=(…)`, process
/// substitution and glob qualifiers). Its program and the subcommand words
/// `isNonExecutor` reads must be its first words, with no backslash: the
/// tokenizer reads every word before the first backslash exactly.
private func isInertLine(_ raw: String, _ launched: [LaunchedCommand]) -> Bool {
    guard launched.count == 1, let command = launched.first,
          command.speculative == false, command.truncated == false, command.headIsDynamic == false,
          command.redirects.isEmpty, command.assignments.isEmpty
    else { return false }
    guard raw.contains(where: { "|&;<>`\n()".contains($0) }) == false else { return false }
    let subcommandWords = ["git": 1, "gh": 2][commandName(command.head)] ?? 0
    let leading = ShellPipeline.tokenize(raw).prefix(1 + subcommandWords)
    return leading.first?.lexeme == command.head && leading.allSatisfy { $0.lexeme.contains("\\") == false }
}

/// Whether `ShellPipeline.tokenize` may split or quote `text` differently
/// from a shell, so its words cannot be trusted: a backslash escape it
/// keeps as text where the shell does not (outside single quotes, a
/// backslash before a quote or a blank, as in `'\''`, `"a \"b\""` or
/// `a\ b`; `\'` inside `$'…'`), a zsh `=(…)` process substitution, which
/// runs its text with none of the characters the splitter knows, or `$IFS`
/// / `${IFS…}`, which the shell splits into words where the tokenizer sees
/// none (`claude${IFS}mcp add`). `$IFS` counts in any quoting and under any
/// name starting `IFS` (fail closed): a quoted one may reach a shell that
/// expands it (`sh -c 'claude${IFS}mcp add'`), whose text is not re-read.
func hasUnfollowableShellText(_ text: String) -> Bool {
    if text.contains("=(") || text.contains("$IFS") || text.contains("${IFS") { return true }
    enum Quote { case bare, single, double, ansi }
    var quote = Quote.bare
    var previous: Character?
    var iterator = text.makeIterator()
    while let char = iterator.next() {
        defer { previous = char }
        if char == "\\", quote != .single {
            guard let next = iterator.next() else { return false }
            switch quote {
            case .bare where next == "'" || next == "\"": return true
            case .bare where next.isWhitespace && next != "\n" && next != "\r\n": return true
            case .double where next == "\"": return true
            case .ansi where next == "'": return true
            default: continue
            }
        }
        switch (quote, char) {
        case (.bare, "'"): quote = previous == "$" ? .ansi : .single
        case (.bare, "\""): quote = .double
        case (.single, "'"), (.ansi, "'"), (.double, "\""): quote = .bare
        default: break
        }
    }
    return false
}

/// `words` joined into one command line, as written and decoded, read flat
/// as a re-split of operands already judged in their own command.
private func joinedReadsRun(
    _ words: [String], _ reads: inout HostTextReads, dataOnly: Bool = false, literalOnly: Bool = false
) -> Bool {
    for line in reads.ordered([words.joined(separator: " "), words.map(decodedWord).joined(separator: " ")]) {
        if reads.runsHostMCPMutation(line, nested: false, dataOnly: dataOnly, resplit: true, literalOnly: literalOnly) {
            return true
        }
    }
    return false
}

/// A word as the shell (`$'…'`) and then `printf`/`echo -e` decode it.
private func decodedWord(_ word: String) -> String {
    decodingAnsiCEscapes(word.ansiCDecodedIfMarked)
}

private let printers: Set<String> = ["echo", "printf", "print"]

/// Every shell word of `raw`, as written and decoded, read as program text
/// (`textNamesHostMCPMutation`): inline interpreter code, quoted strings
/// and assignments that never become a command of their own. Each distinct
/// text is scanned once, under the pieces budget of `reads`.
func hostMCPTextNamesMutation(_ raw: String, reads: inout HostTextReads) -> Bool {
    var scanned: Set<String> = []
    for view in reads.ordered([raw, raw.replacingOccurrences(of: "\\\n", with: "")]) {
        for token in ShellPipeline.tokenize(view) {
            for variant in reads.ordered([unescapeBackslashPairs(token.lexeme), decodingAnsiCEscapes(token.lexeme)])
            where scanned.insert(variant).inserted {
                if textNamesHostMCPMutation(variant, reads: &reads) { return true }
            }
        }
    }
    return false
}

/// Whether `text` may hold a word the host CLI checks match: some
/// substring in `hostMCPStems`, or a brace or glob word that may expand to
/// such a word (`spellsHostMCPTableWord`: `m?p`, `mc{o..p}`), spending
/// `budget`. Each test runs once quote marks, backslashes and newlines are
/// dropped (the tokenizer joins quoted runs, a line continuation joins
/// lines), `%XX` decoded (`packageNames`), and case-folded as `foldedWord`
/// folds, after any number of ANSI-C decodings (`\x63laude`). Every word
/// those checks match holds a stem (`hostMCPTableWords`). A stem is also
/// found with `[…]` groups between its letters, which `packageNames` drops
/// from a spec (`install-m[x]cp` names `install-mcp`: `holdsPastExtras`).
func mayNameHostMCP(_ text: String, budget: inout SpellingBudget) -> Bool {
    decodedLayersMayName(text) { folded in
        hostMCPStems.contains(where: { folded.contains($0) }) || holdsPastExtras(folded, hostMCPStems)
            || spellsHostMCPTableWord(folded, budget: &budget)
    }
}

/// `mayNameHostMCP` with a budget of its own.
func mayNameHostMCP(_ text: String) -> Bool {
    var budget = SpellingBudget()
    return mayNameHostMCP(text, budget: &budget)
}

/// Whether some decoding of `text` holds a `hostMCPStems` stem as written,
/// brace and glob words judged as their own text: the prefilter for a read
/// that judges literal words only (`HostTextReads.literal`). A literal word
/// is still read past its `[…]` extras (`packageNames`), so a stem broken
/// only by them counts (`holdsPastExtras`).
func holdsHostMCPStem(_ text: String) -> Bool {
    decodedLayersMayName(text) { folded in
        hostMCPStems.contains(where: { folded.contains($0) }) || holdsPastExtras(folded, hostMCPStems)
    }
}

/// `test` on each quote-free, `%XX`-decoded and case-folded ANSI-C decoding
/// layer of `text`; true past the decoding depth.
private func decodedLayersMayName(_ text: String, _ test: (String) -> Bool) -> Bool {
    var layer = text
    for _ in 0..<HostTextReads.maxDepth + 2 {
        let plain = String(layer.filter { "'\"\\\n".contains($0) == false })
        for candidate in [plain, percentDecoded(plain)] {
            if test(candidate.folding(options: .caseInsensitive, locale: nil)) { return true }
        }
        let next = decodingAnsiCEscapes(layer)
        if next == layer { return false }
        layer = next
    }
    return true
}

let hostMCPStems = ["claude", "code", "gemini", "cursor", "windsurf", "mcp", "smithery", "plugin", "config", "extensions"]
