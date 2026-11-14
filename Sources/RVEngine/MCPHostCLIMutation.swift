import Foundation
import RVDomain

/// Whether `command` may run a host CLI that adds, removes or installs MCP
/// servers or plugins. The host may sit anywhere in argv, behind a launcher
/// rv does not strip (`npx @anthropic-ai/claude-code mcp add`, `bunx`,
/// `pnpm dlx`, `stdbuf`, `script`, `node …/cli.js`): any word naming a host
/// CLI or its package (`packageNames`), followed anywhere by its
/// `mcp`/`plugin`/`config` group, counts unless the words after it are
/// exactly a read-only form (`isReadOnlyHostForm`). So does an agent CLI
/// run as the program, or by a runner (`npx`, `node`, `stdbuf`, ...) that
/// may stand anywhere before it (`volta run npx …`), whose words rv cannot
/// see: one given an expansion that may stand for its subcommand (`claude
/// "$@"` in a function, `claude $SUB add`) or fed more words by
/// `xargs`/`parallel`; and a dynamic program given an agent CLI's group word
/// (`$C mcp add`), and a runner given the whole command line as one word
/// (`watch 'claude mcp add x'`, read through `reads`). Editors count with
/// `--add-mcp` anywhere after them. Installers that write host configs
/// themselves count: `fastmcp install`; `mcp install` as two adjacent
/// words anywhere (`op run -- mcp install s`, `chronic -q mcp install s`),
/// whatever the server, unless `mcp` is the value of a build tool's
/// directory option (`make -C mcp install`) or the command does not run its
/// operands (`isNonExecutor`); `mcp install` under a Python or plain runner
/// (`uv run mcp install`) or given a `.py` server; the `@smithery/cli`,
/// `install-mcp` and `add-mcp` package specs and programs anywhere, and any
/// spec of them a runner runs. Inside text nothing runs (`reads.inert`),
/// `mcp install` needs a Python runner or a `.py` server.
///
/// Where a word may run (`HostWordPlace.spelled`), it also counts as every
/// word its braces and globs may expand to (`WordSpelling`): a host spelled
/// `clau?e` or `m{c,}p`, a group or `install` spelled `m[c]p` or `{install,x}`
/// after a host, a brace word the shell splits into a whole host command
/// (`{claude,mcp} add`), and a brace or glob word rv cannot expand within
/// `SpellingBudget`. Elsewhere (an operand of a command that never runs one,
/// `leavesOperandsAlone`), and in text a non-executor or such a command
/// carries (`reads.literal`), only literal words count. Linear in the words: each is
/// spelled once and the facts about the words after it come from one pass
/// (`LaterWords`).
func isHostMCPMutation(_ command: LaunchedCommand, reads: inout HostTextReads) -> Bool {
    let words = command.guardArgv.map(foldedWord)
    if command.headIsDynamic, words.dropFirst().contains(where: dynamicGroupWords.contains) { return true }
    let head = commandName(command.head)
    let feedsWords = argvFeeders.contains(head)
    // A runner anywhere before a word may run it: `corepack pnpm dlx X`,
    // `mise exec -- npx X`, `chronic uvx mcp install s.py`.
    let firstRunner = words.firstIndex { hostRunners.contains(commandName($0)) }
    let firstPythonRunner = words.firstIndex { pythonRunners.contains(commandName($0)) }
    let runs = { (index: Int) in index == 0 || firstRunner.map { $0 < index } == true }
    let literalOnly = reads.literal
    let spell = { (word: String, budget: inout SpellingBudget) in
        literalOnly ? WordSpelling.asWritten(word) : WordSpelling.of(word, budget: &budget)
    }
    var spellings: [WordSpelling] = []
    spellings.reserveCapacity(words.count)
    for word in words { spellings.append(spell(word, &reads.spelling)) }
    let later = LaterWords(words, spellings, budget: &reads.spelling)
    reads.visit(words: 2 * words.count)
    // A dynamic word rv cannot read, used as the program at the head or after
    // a runner the parser does not strip (`stdbuf -o0 $c mcp add`), with a
    // group word (literal or a brace/glob spelling) after it: treated like a
    // dynamic head, which `headIsDynamic` only catches at index 0.
    for index in words.indices {
        reads.visit(words: 1)
        if runs(index), later.spelledGroups[index] != 0, wordIsDynamic(words[index]) { return true }
    }
    // argv holds the head's basename; the head as written is judged too, as
    // a path to a host binary its basename does not name
    // (`~/.local/share/claude/versions/2.0.14`, `…/@openai/codex/bin/codex.js`).
    // zsh runs `=claude` as the `claude` on PATH.
    var judged = words.indices.map { (index: $0, word: words[$0], spelling: spellings[$0]) }
    let written = foldedWord(command.head)
    if let first = words.first, written != first {
        judged.append((index: 0, word: written, spelling: spell(written, &reads.spelling)))
    }
    if written.hasPrefix("=") {
        let name = String(written.dropFirst())
        judged.append((index: 0, word: name, spelling: spell(name, &reads.spelling)))
    }
    let operandsRun = reads.inert == false && isNonExecutor(command) == false
    let operandsStayWords = leavesOperandsAlone(command)
    // A build tool's own directory options, or any of them heading a
    // re-split of operands already judged in their own command (`-C mcp
    // install`, `joinedReadsRun`).
    let options = directoryOptions[head]
        ?? (reads.resplit && command.head.hasPrefix("-") ? anyDirectoryOption : [])
    for (index, word, spelling) in judged {
        reads.visit(words: 1)
        if isConfigInstallerPackage(word) || configInstallerPrograms.contains(commandName(word)) { return true }
        if runs(index), packageNames(word).contains(where: configInstallerNames.contains) { return true }
        // A runner given a command line as one word (`watch 'claude mcp
        // add x'`, `su -c '…'`, `parallel '…' ::: x`, Linux `script -c`).
        if index > 0, runs(index), carriesHostMCPMutation(word, reads: &reads) { return true }
        let before = index == 0 ? nil : index == 1 ? command.head : command.guardArgv[index - 1]
        let mayRun = operandsRun && before.map(options.contains) != true
        let pythonRun = (index == 0 && reads.inert == false) || firstPythonRunner.map { $0 < index } == true
        let place = HostWordPlace(
            runs: runs(index), feedsWords: feedsWords, pythonRun: pythonRun, mayRun: mayRun,
            spelled: literalOnly == false && (runs(index) || mayRun || pythonRun)
                && (index > 0 && operandsStayWords) == false)
        var hosts = hostCLIs(word)
        if place.spelled, spelling.expands {
            // A brace or glob word that may run: one rv cannot expand may be
            // any words, and one the shell splits may be a whole command.
            guard let expansions = spelling.expansions else { return true }
            if expansionsRunHostMutation(expansions, budget: &reads.spelling) { return true }
            // The filesystem is not consulted: a wildcard or class is
            // assumed satisfiable (`clau?e`, `cod[e]x`, `m{c,}p`).
            for (name, host) in spelledHostNames
            where hosts.contains(host) == false && spelling.nameMayBe(name, budget: &reads.spelling) {
                hosts.append(host)
            }
        }
        for host in hosts {
            let mutates = hostWordMutates(
                host, at: index, words: words, spellings: spellings, later: later, place: place,
                budget: &reads.spelling)
            if mutates { return true }
        }
    }
    return false
}

private struct HostWordPlace {
    /// Index 0, or after a runner.
    let runs: Bool
    let feedsWords: Bool
    /// Index 0, or after a Python or plain runner.
    let pythonRun: Bool
    /// The word may be run as a program: its command may run its operands,
    /// the line is not text nothing runs, and it is no directory option's
    /// value.
    let mayRun: Bool
    /// The word may run (`runs`, `mayRun` or `pythonRun`) outside a literal
    /// read, and is no operand of a command that leaves its operands alone
    /// (`leavesOperandsAlone`), so brace, glob and dynamic spellings of it
    /// and of the words after it count.
    let spelled: Bool
}

/// For each word, facts about the words after it, built in one reverse pass.
private struct LaterWords {
    /// Bits (`groupBits`) of the group words some later word is.
    var literalGroups: [UInt32]
    /// Bits of the group words some later word is or may expand to.
    var spelledGroups: [UInt32]
    /// Some later word is `--add-mcp…`.
    var addMCP: [Bool]
    /// Some later word names a Python server.
    var pythonServer: [Bool]
    /// Some later word may stand for several words (`mayStandForWords`).
    var standsForWords: [Bool]
    /// The index of the first later word that is not `--`.
    var subcommand: [Int?]
    /// The same, also past words the shell expands to nothing (`{,}`).
    var spelledSubcommand: [Int?]

    init(_ words: [String], _ spellings: [WordSpelling], budget: inout SpellingBudget) {
        literalGroups = Array(repeating: 0, count: words.count)
        spelledGroups = literalGroups
        addMCP = Array(repeating: false, count: words.count)
        pythonServer = addMCP
        standsForWords = addMCP
        subcommand = Array(repeating: nil, count: words.count)
        spelledSubcommand = subcommand
        var literalSeen: UInt32 = 0
        var spelledSeen: UInt32 = 0
        var seenAddMCP = false
        var seenPythonServer = false
        var seenStandsForWords = false
        var next: Int?
        var spelledNext: Int?
        for index in words.indices.reversed() {
            literalGroups[index] = literalSeen
            spelledGroups[index] = spelledSeen
            addMCP[index] = seenAddMCP
            pythonServer[index] = seenPythonServer
            standsForWords[index] = seenStandsForWords
            subcommand[index] = next
            spelledSubcommand[index] = spelledNext
            let word = words[index]
            let literalBit = groupBits[word] ?? 0
            literalSeen |= literalBit
            spelledSeen |= spellings[index].expands ? groupMask(spellings[index], budget: &budget) : literalBit
            if word == "--add-mcp" || word.hasPrefix("--add-mcp=") { seenAddMCP = true }
            if namesPythonServer(word) { seenPythonServer = true }
            if mayStandForWords(word) { seenStandsForWords = true }
            if word != "--" {
                next = index
                if spellings[index].vanishes == false { spelledNext = index }
            }
        }
    }
}

/// The group words (`dynamicGroupWords`, `--add-mcp` among them), one bit each.
private let groupUniverse: [String] = dynamicGroupWords.sorted()
private let groupBits: [String: UInt32] = Dictionary(
    uniqueKeysWithValues: groupUniverse.enumerated().map { ($1, UInt32(1) << UInt32($0)) })
private let addMCPBit: UInt32 = groupBits["--add-mcp"] ?? 0
private let hostGroupMasks: [String: UInt32] = hostGroups.mapValues { groups in
    groups.reduce(UInt32(0)) { $0 | (groupBits[$1] ?? 0) }
}

/// The bits of the group words `spelling` may expand to; every bit for a
/// word rv cannot expand.
private func groupMask(_ spelling: WordSpelling, budget: inout SpellingBudget) -> UInt32 {
    guard spelling.expansions != nil else { return UInt32.max }
    var mask: UInt32 = 0
    for (bit, group) in groupUniverse.enumerated() where spelling.mayBe(group, budget: &budget) {
        mask |= UInt32(1) << UInt32(bit)
    }
    return mask
}

/// The words of a brace word the shell splits into several, judged as a
/// command of their own: one that may run a host CLI followed, inside the
/// same word, by one that may make it mutate (`{claude,mcp} add`, `chronic
/// {mcp,install} srv`, `{code,--add-mcp}`), or by a value rv cannot read
/// after an agent CLI or installer. Read-only forms are not looked for
/// (fail closed).
private func expansionsRunHostMutation(_ expansions: [String], budget: inout SpellingBudget) -> Bool {
    guard expansions.count > 1 else { return false }
    // Every element-follower pair may be compared, by a glob or by equality.
    guard budget.spend(expansions.count * expansions.count) else { return true }
    for (offset, element) in expansions.enumerated().dropLast() {
        let name = commandName(element)
        for (spelling, host) in spelledHostNames where patternMayBe(name, spelling, budget: &budget) {
            for follower in expansions[(offset + 1)...] {
                if editorHosts.contains(host), follower.hasPrefix("--add-mcp") { return true }
                if agentHosts.contains(host), mayStandForWords(follower) { return true }
                if pythonInstallers.contains(host), wordIsDynamic(follower) { return true }
                for word in hostMutatingWords[host] ?? [] where patternMayBe(follower, word, budget: &budget) {
                    return true
                }
            }
        }
    }
    return false
}

/// Per host a spelled name may run, the words after it that make it mutate.
private let hostMutatingWords: [String: [String]] = Dictionary(
    spelledHostNames.map { pair -> (String, [String]) in
        let host = pair.1
        let installs: [String] = pythonInstallers.contains(host) ? ["install"] : []
        let addMCP: [String] = editorHosts.contains(host) ? ["--add-mcp"] : []
        return (host, Array(hostGroups[host] ?? []) + installs + addMCP)
    },
    uniquingKeysWith: { first, _ in first })

/// Per build tool, the options whose next word is a directory, workspace
/// or package filter (`make -C mcp install`, `pnpm --filter mcp install`,
/// `npm --prefix mcp install x`), as written and confirmed in each tool's
/// own help or option table: GNU make `-C`/`--directory` (`-w` is
/// `--print-directory`, a flag); npm `-C` (`--prefix`), `--prefix`, `-w`
/// and `--workspace`; pnpm `-C`/`--dir` and `--filter` (`-w` is
/// `--workspace-root`, a flag); bun `--cwd` and `-F`/`--filter`. Under any
/// other program (`nsenter -w mcp install s`, `yarn --cwd …`) the word
/// after one may run.
private let directoryOptions: [String: Set<String>] = [
    "make": ["-C", "--directory"],
    "gmake": ["-C", "--directory"],
    "npm": ["-C", "--prefix", "-w", "--workspace"],
    "pnpm": ["-C", "--dir", "--filter"],
    "bun": ["--cwd", "-F", "--filter"],
]

private let anyDirectoryOption: Set<String> = directoryOptions.values.reduce(into: []) { $0.formUnion($1) }

/// A command rv knows never runs its operands' text, run by its plain
/// name: `grep`/`egrep`/`fgrep`, `rg` without `--pre` or `--hostname-bin`,
/// `echo`/`printf`, `git commit`/`git tag` with no global option, and `gh
/// pr|issue create|comment|edit`. Any other program may be an executor.
func isNonExecutor(_ command: LaunchedCommand) -> Bool {
    let head = foldedWord(command.head)
    guard command.headIsDynamic == false, head.contains("/") == false, commandName(command.head) == head else {
        return false
    }
    let words = command.guardArgv.dropFirst().map(foldedWord)
    switch head {
    case "grep", "egrep", "fgrep", "echo", "printf":
        return true
    case "rg":
        // `--pre` and `--hostname-bin` both name a program rg runs.
        return words.contains(where: { $0.hasPrefix("--pre") || $0.hasPrefix("--hostname-bin") }) == false
    case "git":
        return words.first.map { ["commit", "tag"].contains($0) } == true
    case "gh":
        return words.count >= 2 && ["pr", "issue"].contains(words[0])
            && ["create", "comment", "edit"].contains(words[1])
    default:
        return false
    }
}

/// A command run by its plain name that never runs an operand as a program
/// or command line: `ls`, `cp`, `mv`, `rm`, `mkdir`, `touch`, `cat`, and `git
/// add|status|diff|rm` with the subcommand first. None has an option that
/// runs a program it is given. Unlike `isNonExecutor`, its operands are
/// still read as written (`ls 'chronic mcp install x'`, `ls mcp install`);
/// only their brace, glob and dynamic spellings are not, since a word it
/// is given is never run (`ls mcp *`, `cp -r packages/mcp "$DEST"`, `touch
/// {a..z}{0..9}`).
func leavesOperandsAlone(_ command: LaunchedCommand) -> Bool {
    let head = foldedWord(command.head)
    guard command.headIsDynamic == false, head.contains("/") == false, commandName(command.head) == head else {
        return false
    }
    switch head {
    case "ls", "cp", "mv", "rm", "mkdir", "touch", "cat":
        return true
    case "git":
        return command.guardArgv.dropFirst().first.map { ["add", "status", "diff", "rm"].contains(foldedWord($0)) }
            == true
    default:
        return false
    }
}

/// Whether the host CLI `host`, run by the word at `index`, is given words
/// that make it mutate, judged from the facts about the words after it.
private func hostWordMutates(
    _ host: String, at index: Int, words: [String], spellings: [WordSpelling], later: LaterWords,
    place: HostWordPlace, budget: inout SpellingBudget
) -> Bool {
    if editorHosts.contains(host) {
        if later.addMCP[index] || (place.spelled && later.spelledGroups[index] & addMCPBit != 0) { return true }
        if host != "cursor" { return false }
    }
    // `--` ends options and leaves the subcommand (`mcp -- install s`).
    // Where the host may run, a brace or glob spelling that can produce
    // `install` counts (`mcp {a,install}`, `mcp instal?`), past words the
    // shell expands to nothing (`mcp {,} install`), as does a value rv
    // cannot read (`mcp $(printf install) srv`, `mcp $SUB srv`).
    var installs = later.subcommand[index].map { words[$0] == "install" } == true
    if installs == false, place.spelled, let next = later.spelledSubcommand[index] {
        installs = wordIsDynamic(words[next]) || spellings[next].mayBe("install", budget: &budget)
    }
    if host == "fastmcp" { return installs }
    if host == "mcp" {
        // `mcp` is a common directory and package name (`make -C mcp
        // install`): a word that may run, the program under a Python
        // runner, or given a Python server file.
        guard installs else { return false }
        return place.mayRun || place.pythonRun || later.pythonServer[index]
    }
    guard let groups = hostGroupMasks[host] else { return false }
    if agentHosts.contains(host), place.runs, place.feedsWords || later.standsForWords[index] { return true }
    // A later word that is one of the host's group words or, where the host
    // may run, that a brace/glob spelling can produce (`claude m{c,}p add`,
    // `gemini ext*s install`).
    let found = place.spelled ? later.spelledGroups[index] : later.literalGroups[index]
    guard found & groups != 0 else { return false }
    // Every read-only form holds at most three words.
    let after = words.count - index - 1
    return after > 3 || isReadOnlyHostForm(host: host, Array(words[(index + 1)...])) == false
}

/// Every host CLI a word may run: its program name, or a package that
/// ships it in any spec shape (`@anthropic-ai/claude-code@latest`,
/// `…/claude-code/cli.js`, `nixpkgs#claude-code`, `mcp[cli]@1.6`), or
/// Claude Code's native build (`~/.local/share/claude/versions/2.0.14`).
private func hostCLIs(_ word: String) -> [String] {
    var hosts: [String] = []
    let name = commandName(word)
    if hostGroups[name] != nil || editorHosts.contains(name) || pythonInstallers.contains(name) { hosts.append(name) }
    if name == "claude-code" || ("/" + word).contains("/claude/versions/") { hosts.append("claude") }
    for (package, host) in hostPackages where word.contains(package) { hosts.append(host) }
    for package in packageNames(word) {
        if let host = hostPackageNames[package] { hosts.append(host) }
        if pythonInstallers.contains(package) { hosts.append(package) }
    }
    var seen: Set<String> = []
    return hosts.filter { seen.insert($0).inserted }
}

/// A word holding a whole command line that runs a host MCP CLI (`'claude
/// mcp add x'` given to a runner, echoed into a shell, or a here-string).
func carriesHostMCPMutation(_ word: String, reads: inout HostTextReads) -> Bool {
    guard word.contains(where: \.isWhitespace) else { return false }
    return reads.runsHostMCPMutation(word)
}

/// Text no shell parse splits into words, such as inline program code or
/// a quoted string (`os.system("claude mcp add x")`, `X='claude mcp add
/// x'`), cut at every character a program or package name cannot hold: a
/// host CLI or package whose next non-option piece is one of its groups,
/// unless the pieces after it are exactly a read-only form; an installer's
/// package or program; `fastmcp install`; `mcp install` given a `.py`
/// server; an editor given `--add-mcp`. Over-reports on prose that names a
/// host mutation, as a commit message or a grep pattern may. Linear in the
/// pieces, which count against `reads` (past its cap: a mutation) unless
/// no piece holds a stem.
func textNamesHostMCPMutation(_ text: String, reads: inout HostTextReads) -> Bool {
    let pieces = textPieces(text)
    guard pieces.count > 1 else { return false }
    // Sound early exit: every check below that can return true tests a
    // table word (each holds a stem, `hostMCPTableWords`) by equality,
    // prefix or containment against one of: a piece, its `commandName`, a
    // `packageNames` name of it, or a later piece (a group word or
    // `--add-mcp`); `install` and `.py` are only tested once a host
    // matched. A `packageNames` name of a piece with no `%` is a substring
    // of it, or two joined by `/`, which no stem holds; with a `%` the names
    // are tested themselves. Decoding (`$'…'`, backslashes) happens before
    // this text is formed, so the stems are tested on exactly the strings
    // the checks see. So text no piece of which passes cannot match here.
    guard pieces.contains(where: pieceMayNameHostMCP) else { return false }
    guard reads.examine(pieces: pieces.count) else { return true }
    let later = LaterPieces(pieces)
    for (index, piece) in pieces.enumerated() {
        if isConfigInstallerPackage(piece) || configInstallerPrograms.contains(commandName(piece)) { return true }
        if packageNames(piece).contains(where: configInstallerNames.contains) { return true }
        let first = later.subcommand[index].map { pieces[$0] }
        for host in hostCLIs(piece) {
            if editorHosts.contains(host), later.addMCP[index] { return true }
            if host == "fastmcp", first == "install" { return true }
            if host == "mcp", first == "install", later.pythonServer[index] { return true }
            guard let groups = hostGroups[host], let next = later.nextOperand[index], groups.contains(pieces[next])
            else { continue }
            // Every read-only form holds at most three words.
            let restCount = pieces.count - index - 1
            if restCount > 3 || isReadOnlyHostForm(host: host, Array(pieces[(index + 1)...])) == false { return true }
        }
    }
    return false
}

/// For each piece, facts about the pieces after it, built in one pass.
private struct LaterPieces {
    /// Some later piece is `--add-mcp…`.
    var addMCP: [Bool]
    /// Some later piece names a Python server.
    var pythonServer: [Bool]
    /// The index of the first later piece that is not an option.
    var nextOperand: [Int?]
    /// The index of the first later piece that is not `--`.
    var subcommand: [Int?]

    init(_ pieces: [String]) {
        addMCP = Array(repeating: false, count: pieces.count)
        pythonServer = Array(repeating: false, count: pieces.count)
        nextOperand = Array(repeating: nil, count: pieces.count)
        subcommand = Array(repeating: nil, count: pieces.count)
        var seenAddMCP = false
        var seenPythonServer = false
        var operand: Int?
        var word: Int?
        for index in pieces.indices.reversed() {
            addMCP[index] = seenAddMCP
            pythonServer[index] = seenPythonServer
            nextOperand[index] = operand
            subcommand[index] = word
            let piece = pieces[index]
            if piece.hasPrefix("--add-mcp") { seenAddMCP = true }
            if namesPythonServer(piece) { seenPythonServer = true }
            if piece.hasPrefix("-") == false { operand = index }
            if piece != "--" { word = index }
        }
    }
}

/// Case-folded runs of characters a program, package spec or option can
/// hold; a run with no letter or digit (`+`, `.`) is dropped unless it is
/// an option (`--`).
private func textPieces(_ text: String) -> [String] {
    text.folding(options: .caseInsensitive, locale: nil)
        .split(whereSeparator: { ($0.isLetter || $0.isNumber || pieceCharacters.contains($0)) == false })
        .map(String.init)
        .filter { piece in piece.hasPrefix("-") || piece.contains(where: { $0.isLetter || $0.isNumber }) }
}

private let pieceCharacters: Set<Character> = ["_", "@", "/", ".", "-", "%", ":", "#", "~"]

/// Whether a piece, its program name, or (with a `%`) a package name it
/// decodes to holds a `hostMCPStems` stem.
func pieceMayNameHostMCP(_ piece: String) -> Bool {
    let holdsStem = { (word: String) in hostMCPStems.contains { word.contains($0) } }
    if holdsStem(piece) || holdsStem(commandName(piece)) { return true }
    return piece.contains("%") && packageNames(piece).contains(where: holdsStem)
}

/// Every word the tables in this file match on, for the `hostMCPStems` check.
func hostMCPTableWords() -> [String] {
    var words = Array(hostGroups.keys) + hostGroups.values.flatMap { $0 } + Array(dynamicGroupWords)
    words += Array(editorHosts) + Array(pythonInstallers) + hostPackages.map(\.0) + Array(hostPackageNames.keys)
    words += configInstallerPackages + Array(configInstallerPrograms) + Array(configInstallerNames)
    return words + ["claude-code", "/claude/versions/"]
}

/// An expansion rv cannot read that may become the subcommand or several
/// words (`$SUB`, `"$@"`, `$(printf 'mcp add')`, `--$X`). A quoted word
/// with a literal space outside its substitutions (`"fix $FILE"`) stays one
/// word that is no group name, unless it carries `@` (`"x $@"` splits).
private func mayStandForWords(_ word: String) -> Bool {
    guard word.contains("$") || word.contains("`") else { return false }
    let literal = collapsingSubstitutions(word)
    return literal.contains(where: \.isWhitespace) == false || word.contains("@")
}

/// A config installer's package spec anywhere (`@smithery/cli`,
/// `install-mcp@1.2`, `…/node_modules/install-mcp/…`): a word that is the
/// spec itself, not one that contains it (`add-mcp-support`).
private func isConfigInstallerPackage(_ word: String) -> Bool {
    configInstallerPackages.contains { package in
        word == package || word.hasPrefix(package + "@") || word.contains("node_modules/" + package + "/")
    }
}

/// `server.py`, `server.py:app`, `pkg/server.py`.
private func namesPythonServer(_ word: String) -> Bool {
    word.hasPrefix("-") == false && (word.hasSuffix(".py") || word.contains(".py:"))
}

private let editorHosts: Set<String> = ["code", "code-insiders", "cursor", "windsurf"]

/// Programs that append words of their own to the command they run.
private let argvFeeders: Set<String> = ["xargs", "parallel"]

private let agentHosts: Set<String> = ["claude", "codex", "gemini", "opencode", "cursor-agent"]

/// Programs that run a later word of their argv as a program or package.
/// Under any other program a host name is data (`grep claude "$f"`).
private let hostRunners: Set<String> = argvFeeders.union([
    "npx", "bunx", "pnpx", "pnpm", "yarn", "npm", "bun", "node", "deno", "stdbuf", "caffeinate", "arch",
    "script", "unbuffer", "find", "watch", "chrt", "ionice", "taskset", "setsid", "flock", "su", "runuser",
    "tmux", "screen",
])

/// The Python MCP SDK's and FastMCP's CLIs write Claude Desktop and other
/// host configs: `mcp install server.py`, `fastmcp install cursor`.
private let pythonInstallers: Set<String> = ["mcp", "fastmcp"]

/// Runners that start a Python program by name, plus the plain launchers
/// (not the JavaScript package managers: `pnpm --filter mcp install`).
private let pythonRunners: Set<String> = argvFeeders.union([
    "uv", "uvx", "pipx", "poetry", "pdm", "hatch", "rye", "python", "python3", "stdbuf", "caffeinate", "arch",
    "script", "unbuffer", "watch", "chrt", "ionice", "taskset", "setsid", "flock", "su", "runuser",
])

private let hostGroups: [String: Set<String>] = [
    // `config` writes the host's settings (`claude config set|add|remove`):
    // only `config`, `config list` and `config get NAME` stay read-only.
    "claude": ["mcp", "plugin", "plugins", "config"],
    "codex": ["mcp", "mcp-server", "config"],
    "gemini": ["mcp", "extensions", "config"],
    "opencode": ["mcp", "config"],
    "cursor": ["mcp"],
    "cursor-agent": ["mcp"],
]

/// Group words a dynamic program (`$C`) may be given.
private let dynamicGroupWords: Set<String> = hostGroups.values.reduce(into: ["--add-mcp"]) { $0.formUnion($1) }

private let hostPackages: [(String, String)] = [
    ("@anthropic-ai/claude-code", "claude"),
    ("@openai/codex", "codex"),
    ("@google/gemini-cli", "gemini"),
    ("opencode-ai", "opencode"),
]

/// `packageNames` of an agent CLI's package in any spec shape (`github:
/// google-gemini/gemini-cli`, `…/anthropic-ai-claude-code-2.0.14.tgz`).
private let hostPackageNames: [String: String] = [
    "@anthropic-ai/claude-code": "claude", "anthropic-ai-claude-code": "claude", "claude-code": "claude",
    "@openai/codex": "codex", "openai-codex": "codex", "codex": "codex",
    "@google/gemini-cli": "gemini", "google-gemini-cli": "gemini", "gemini-cli": "gemini",
    "opencode-ai": "opencode",
]

/// Packages and programs whose job is writing a server into host configs.
private let configInstallerPackages: [String] = ["@smithery/cli", "install-mcp", "add-mcp"]
private let configInstallerPrograms: Set<String> = ["smithery", "install-mcp", "add-mcp"]
/// `packageNames` of an installer in any spec shape, for a word a runner runs.
private let configInstallerNames: Set<String> = [
    "@smithery/cli", "smithery-cli", "smithery-ai/cli", "install-mcp", "add-mcp",
]

/// The exact argv tails (after the host word) that only print. `NAME`
/// stands for one non-option word. `claude mcp serve` and `codex
/// mcp-server` are not here: they run the host's own tools (shell, file
/// edits) for whatever client writes to their stdin, outside rv's hooks.
private func isReadOnlyHostForm(host: String, _ rest: [String]) -> Bool {
    let forms: [[String]]
    switch host {
    case "claude":
        forms = [
            ["mcp"], ["mcp", "list"], ["mcp", "get", "NAME"],
            ["plugin"], ["plugin", "list"], ["plugin", "validate", "NAME"],
            ["plugins"], ["plugins", "list"],
            ["plugin", "marketplace"], ["plugin", "marketplace", "list"],
        ]
    case "codex":
        forms = [["mcp"], ["mcp", "list"], ["mcp", "get", "NAME"]]
    case "gemini":
        forms = [["mcp"], ["mcp", "list"], ["extensions"], ["extensions", "list"]]
    case "opencode":
        forms = [["mcp"], ["mcp", "list"], ["mcp", "ls"]]
    default:
        forms = [["mcp"], ["mcp", "list"]]
    }
    let configForms: [[String]] = hostGroups[host]?.contains("config") == true
        ? [["config"], ["config", "list"], ["config", "get", "NAME"]]
        : []
    // `<group> help`, `<group> --help`, `<group> <sub> --help` only print.
    // A bare `help` elsewhere is an operand (`claude plugin install help`).
    if (2...3).contains(rest.count), hostGroups[host]?.contains(rest[0]) == true,
       rest[1] == "help" || ["--help", "-h"].contains(rest[rest.count - 1])
    {
        return true
    }
    return (forms + configForms).contains { form in
        form.count == rest.count
            && zip(form, rest).allSatisfy { expected, word in
                expected == "NAME" ? word.hasPrefix("-") == false : expected == word
            }
    }
}

// MARK: - Brace and glob spellings

/// Plain host program names (not package specs) a brace or glob spelling may
/// stand for, each mapped to the host it runs.
private let spelledHostNames: [(String, String)] = {
    var pairs: [(String, String)] = []
    for name in hostGroups.keys { pairs.append((name, name)) }
    for name in editorHosts { pairs.append((name, name)) }
    for name in pythonInstallers { pairs.append((name, name)) }
    pairs.append(("claude-code", "claude"))
    return pairs
}()
