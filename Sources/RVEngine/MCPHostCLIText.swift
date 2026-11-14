import Foundation

/// The one work budget for reading text as command lines while judging one
/// command for the MCP host config guard. Each distinct text is read once;
/// at most `maxReads` texts are read and `maxDepth` quoting levels nested,
/// and a read past either counts as a mutation (fail closed). Text no
/// decoding of which names a host CLI, a group or an installer
/// (`mayNameHostMCP`) is never read, so ordinary commands spend nothing.
final class HostTextReads {
    static let maxReads = 512
    static let maxDepth = 6

    private var remaining = HostTextReads.maxReads
    private var depth = 0
    private var seen: Set<String> = []

    /// Whether `text`, read as a command line, runs a host MCP mutation. A
    /// `nested` read is a word's own quoting level: its words and joined
    /// tails are read in turn (`carriesHostMCPText`). A flat read is a
    /// re-split of words already read one by one (a joined tail): only its
    /// commands are judged.
    func runsHostMCPMutation(_ text: String, nested: Bool = true) -> Bool {
        guard mayNameHostMCP(text), seen.insert((nested ? "n" : "f") + text).inserted else { return false }
        guard remaining > 0, depth < Self.maxDepth else { return true }
        remaining -= 1
        if nested { depth += 1 }
        defer { if nested { depth -= 1 } }
        let launched = launchedCommandHeads(text)
        if launched.contains(where: \.truncated) { return true }
        if launched.contains(where: { isHostMCPMutation($0, reads: self) }) { return true }
        return nested && carriesHostMCPText(launched, reads: self)
    }
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
func carriesHostMCPText(_ launched: [LaunchedCommand], reads: HostTextReads) -> Bool {
    var printed: [String] = []
    for command in launched where command.speculative == false && command.truncated == false {
        let args = Array(command.argv.dropFirst())
        let values = command.assignments.compactMap { word in
            word.firstIndex(of: "=").map { String(word[word.index(after: $0)...]) }
        }
        for word in args + values {
            for variant in Set([word, word.ansiCDecodedIfMarked, decodedWord(word)])
            where variant.contains(where: \.isWhitespace) && reads.runsHostMCPMutation(variant) {
                return true
            }
        }
        var tails = [args]
        let name = commandName(command.head)
        if printers.contains(name) {
            let operands = Array(args.drop(while: { $0.hasPrefix("-") }))
            tails.append(operands)
            if name == "printf" { tails.append(Array(operands.dropFirst())) }
            printed.append(contentsOf: operands)
        }
        for tail in tails where tail.isEmpty == false && joinedReadsRun(tail, reads) { return true }
        let argv = [command.head] + args
        let decoded = argv.map(\.ansiCDecodedIfMarked)
        if decoded != argv, reads.runsHostMCPMutation(decoded.joined(separator: " "), nested: false) { return true }
    }
    return printed.isEmpty == false && joinedReadsRun(printed, reads)
}

/// `words` joined into one command line, as written and decoded, read flat.
private func joinedReadsRun(_ words: [String], _ reads: HostTextReads) -> Bool {
    Set([words.joined(separator: " "), words.map(decodedWord).joined(separator: " ")]).contains {
        reads.runsHostMCPMutation($0, nested: false)
    }
}

/// A word as the shell (`$'…'`) and then `printf`/`echo -e` decode it.
private func decodedWord(_ word: String) -> String {
    decodingAnsiCEscapes(word.ansiCDecodedIfMarked)
}

private let printers: Set<String> = ["echo", "printf", "print"]

/// Every shell word of `raw`, as written and decoded, read as program text
/// (`textNamesHostMCPMutation`): inline interpreter code, quoted strings
/// and assignments that never become a command of their own.
func hostMCPTextNamesMutation(_ raw: String) -> Bool {
    for view in Set([raw, raw.replacingOccurrences(of: "\\\n", with: "")]) {
        for token in ShellPipeline.tokenize(view) {
            for variant in Set([unescapeBackslashPairs(token.lexeme), decodingAnsiCEscapes(token.lexeme)])
            where textNamesHostMCPMutation(variant) {
                return true
            }
        }
    }
    return false
}

/// Whether `text` may hold a word the host CLI checks match: some
/// substring in `hostMCPStems`, once quote marks, backslashes and newlines
/// are dropped (the tokenizer joins quoted runs, a line continuation joins
/// lines), `%XX` decoded (`packageNames`), and case-folded as `foldedWord`
/// folds, after any number of ANSI-C decodings (`\x63laude`). Every word
/// those checks match holds a stem (`hostMCPTableWords`).
func mayNameHostMCP(_ text: String) -> Bool {
    var layer = text
    for _ in 0..<HostTextReads.maxDepth + 2 {
        let plain = String(layer.filter { "'\"\\\n".contains($0) == false })
        for candidate in [plain, percentDecoded(plain)] {
            let folded = candidate.folding(options: .caseInsensitive, locale: nil)
            if hostMCPStems.contains(where: { folded.contains($0) }) { return true }
        }
        let next = decodingAnsiCEscapes(layer)
        if next == layer { return false }
        layer = next
    }
    return true
}

let hostMCPStems = ["claude", "code", "gemini", "cursor", "windsurf", "mcp", "smithery", "plugin", "config", "extensions"]
