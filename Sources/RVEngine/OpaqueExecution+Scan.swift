import RVDomain

/// One command's observe-floor scan: whether it runs a program rv cannot
/// read, the program texts its readers are fed (literal pipes,
/// here-strings, heredocs, and an interpreter's string literals), which
/// the observe floor reads too, and whether the work budget ran out
/// (indeterminate: the caller fails closed).
package struct OpaqueScan {
    package let opaque: Bool
    package let innerTexts: [String]
    package let exhausted: Bool
    package let commands: Int
}

package func scanOpaqueProgram(_ command: ShellCommand) -> OpaqueScan {
    var state = ScanState()
    return scanOpaqueProgram(command, state: &state)
}

private func scanOpaqueProgram(_ command: ShellCommand, state: inout ScanState) -> OpaqueScan {
    let opaque = OpaqueExecution.scan(command.rawValue, depth: 0, inherited: { .empty }, state: &state)
    return OpaqueScan(
        opaque: opaque || state.exhausted, innerTexts: state.innerTexts,
        exhausted: state.exhausted, commands: state.commands
    )
}

/// Every text the observe floor reads for one command, built once under
/// one budget (`ScanState`): the command, each program text it feeds a
/// shell or interpreter (`OpaqueScan.innerTexts`), and each of their guard
/// readings (`ShellLexer.guardReadings`). The floor runs every detector
/// over every text, so no detector re-reads on its own. `exhausted`: the
/// scan or the readings ran out of budget before the set was whole, and
/// the caller must fail closed without reading any of it.
package struct ObserveTexts {
    package enum Origin: Sendable {
        /// The command as written.
        case command
        /// Program text a reader is fed (`OpaqueScan.innerTexts`).
        case fed
        /// A guard reading of the command or of a fed text.
        case reading
    }

    package struct Text: Sendable {
        package let raw: String
        package let origin: Origin
    }

    /// Readings past which nothing is read: each text and each of its list
    /// commands is one (an interpreter's string literals are texts too), so
    /// a 1500-line python script with two strings a line takes about 6000.
    /// The texts' total size is bounded by the scan's work budget; this
    /// bounds the per-reading overhead.
    package static let readingCap = ScanState.readingCap

    /// The command first, then its readings, then each fed text and its readings.
    package let texts: [Text]
    /// `OpaqueScan.opaque`: part of the command rv cannot read can take a
    /// command position.
    package let opaque: Bool
    package let exhausted: Bool
}

package func observeTexts(_ command: ShellCommand) -> ObserveTexts {
    var state = ScanState()
    let scan = scanOpaqueProgram(command, state: &state)
    guard scan.exhausted == false else { return ObserveTexts(texts: [], opaque: true, exhausted: true) }
    let fed = scan.innerTexts.filter { sameBytes($0, command.rawValue) == false }
    var texts: [ObserveTexts.Text] = []
    for (raw, origin) in [(command.rawValue, ObserveTexts.Origin.command)] + fed.map({ ($0, .fed) }) {
        let readings = ShellLexer.guardReadings(raw)
        guard state.charge(readings: 1 + readings.count) else {
            return ObserveTexts(texts: [], opaque: true, exhausted: true)
        }
        texts.append(ObserveTexts.Text(raw: raw, origin: origin))
        texts += readings.map { ObserveTexts.Text(raw: $0, origin: .reading) }
    }
    return ObserveTexts(texts: texts, opaque: scan.opaque, exhausted: false)
}

/// Byte-for-byte equality (`==` on String is canonical equivalence). The
/// readers of one feed share one string, so shared storage answers in O(1).
package func sameBytes(_ lhs: String, _ rhs: String) -> Bool {
    guard lhs.utf8.count == rhs.utf8.count else { return false }
    let shared = lhs.utf8.withContiguousStorageIfAvailable { left in
        rhs.utf8.withContiguousStorageIfAvailable { right in left.baseAddress == right.baseAddress }
    }
    if shared == true { return true }
    return lhs.utf8.elementsEqual(rhs.utf8)
}

/// What a stdin reader reads, and whether rv can read it. `parts`: the
/// producers' texts one by one, when their order is not known (a compound
/// command), each read alone besides the joined `text`.
struct Feed {
    let literal: Bool
    let text: String
    var parts: [String] = []

    static let unreadable = Feed(literal: false, text: "")
    static let empty = Feed(literal: true, text: "")

    /// Every text to read: the joined text, then each part alone.
    var texts: [String] {
        parts.count > 1 ? [text] + parts : [text]
    }
}

/// Shared by one scan and every text it recurses into.
struct ScanState {
    static let commandCap = 4096
    static let workCap = 4_000_000
    static let nestingCap = 32
    static let readingCap = 8192

    private(set) var commands = 0
    private(set) var work = 0
    private(set) var readings = 0
    private(set) var exhausted = false
    /// Fed program texts, each once, in first-seen order.
    private(set) var innerTexts: [String] = []
    // Keyed on bytes: String equality is canonical equivalence, and two
    // equivalent texts can read differently (`rv[\u{1E0D}]` vs
    // `rv[d\u{0323}]` as a pattern), so one must not stand for the other.
    private var recorded: Set<[UInt8]> = []
    private var codeRead: Set<[UInt8]> = []
    private var lastRecorded: String?
    private var lastCodeRead: String?
    /// Function and alias names the command defines.
    var definedNames: Set<String> = []
    /// The line may set a shell startup file (`BASH_ENV`, `ENV`): every
    /// shell it runs is opaque.
    var setsShellStartup = false

    /// Records a fed text; false when it was recorded before.
    mutating func record(_ text: String) -> Bool {
        if let last = lastRecorded, sameBytes(text, last) { return false }
        lastRecorded = text
        guard recorded.insert(Array(text.utf8)).inserted else { return false }
        innerTexts.append(text)
        return true
    }

    /// True the first time `text` is read as interpreter code (its string
    /// literals recorded), false after.
    mutating func firstCodeRead(_ text: String) -> Bool {
        if let last = lastCodeRead, sameBytes(text, last) { return false }
        lastCodeRead = text
        return codeRead.insert(Array(text.utf8)).inserted
    }

    /// Spends budget; false once it is gone.
    mutating func charge(commands: Int = 0, work: Int = 0) -> Bool {
        self.commands += commands
        self.work += work
        if self.commands > Self.commandCap || self.work > Self.workCap { exhausted = true }
        return exhausted == false
    }

    /// Spends reading budget (`ObserveTexts`); false once it is gone.
    mutating func charge(readings: Int) -> Bool {
        self.readings += readings
        if self.readings > Self.readingCap { exhausted = true }
        return exhausted == false
    }
}

/// A simple command of the line, with what it reads and runs.
struct LineCommand {
    let tokens: [CommandToken]
    /// The body its last `<<` reads; nil when it has none or the body was
    /// not found.
    let heredoc: ShellLexer.Heredoc?
    let piece: Int
    let stage: Int
    let substitutions: [String]
}

/// A text's commands, flattened through groups and function bodies.
/// `complex` (a compound command, a group, a definition) means the
/// pipeline topology is not tracked, so every other command of the text
/// counts as a reader's producer.
struct Line {
    var commands: [LineCommand] = []
    var complex = false
    var opaque = false
    var stdinRedirected = false
    var pieces = 0
}

extension OpaqueExecution {
    static let maxDepth = 4

    /// `inherited`: the stdin the text starts with, read only if needed.
    static func scan(_ text: String, depth: Int, inherited: @escaping () -> Feed, state: inout ScanState) -> Bool {
        guard depth <= maxDepth, state.exhausted == false else { return true }
        var line = Line()
        flatten(text, into: &line, nesting: 0, state: &state)
        if state.exhausted || line.opaque { return true }
        // Captured by every reader's feed, so its cache is shared by them.
        var producers = Producers(line, inherited: line.stdinRedirected ? { .unreadable } : inherited)
        for index in line.commands.indices {
            let command = line.commands[index]
            let feed: () -> Feed = { producers.feed(for: index) }
            let context = Context(
                segment: command.tokens, heredoc: command.heredoc, piped: command.stage > 0, feed: feed, depth: depth
            )
            if segmentRunsOpaque(context, state: &state) { return true }
            for inner in command.substitutions {
                if scan(inner, depth: depth + 1, inherited: feed, state: &state) { return true }
            }
        }
        return state.exhausted
    }

    // MARK: Flattening

    static func flatten(_ text: String, into line: inout Line, nesting: Int, state: inout ScanState) {
        guard nesting <= ScanState.nestingCap else { line.opaque = true; return }
        guard state.charge(work: text.unicodeScalars.count) else { return }
        let list = ShellLexer.walk(text, split: .list)
        if list.ambiguous { line.opaque = true }
        for piece in list.pieces {
            let pieceID = line.pieces
            line.pieces += 1
            guard state.charge(work: piece.text.unicodeScalars.count) else { return }
            let pipeline = ShellLexer.walk(piece.text, split: .pipe)
            if pipeline.ambiguous { line.opaque = true }
            var heredocs = piece.heredocs[...]
            for (stageIndex, stage) in pipeline.pieces.enumerated() {
                guard state.charge(commands: 1, work: stage.text.unicodeScalars.count) else { return }
                let shape = ShellLexer.walk(stage.text, split: .none)
                if shape.ambiguous { line.opaque = true }
                let outer = shape.pieces.first ?? ShellLexer.Piece(text: "")
                let tokens = ShellLexer.words(outer.text)
                var heredoc: ShellLexer.Heredoc?
                for token in tokens where token.wasQuoted == false {
                    let op = redirectOperator(token.decoded)
                    if op == "<<" || op == "<<-" { heredoc = heredocs.popFirst() }
                }
                classify(tokens, groups: outer.groups, into: &line, nesting: nesting, state: &state)
                line.commands.append(
                    LineCommand(
                        tokens: tokens, heredoc: heredoc, piece: pieceID, stage: stageIndex,
                        substitutions: outer.substitutions
                    )
                )
                for body in outer.groups {
                    line.complex = true
                    flatten(body, into: &line, nesting: nesting + 1, state: &state)
                }
            }
        }
    }

    /// Line-wide facts one command shows: a compound command, a
    /// definition, `coproc`/`>&p`, `hash -p`, `exec < …`.
    private static func classify(
        _ tokens: [CommandToken], groups: [String], into line: inout Line, nesting: Int, state: inout ScanState
    ) {
        var index = 0
        while index < tokens.count, tokens[index].wasQuoted == false,
              isAssignment(tokens[index].decoded) || tokens[index].decoded == "!"
        {
            index += 1
        }
        if tokens.contains(where: { mentionsName($0.decoded, "BASH_ENV") || mentionsName($0.decoded, "ENV") }) {
            // `BASH_ENV=/dev/stdin bash -c true`, `set -a; ENV=…; sh -i`: a
            // shell reads that file first. Checked for every command,
            // assignment-only ones included.
            state.setsShellStartup = true
        }
        guard index < tokens.count else { return }
        let first = tokens[index]
        let word = first.wasQuoted ? "" : first.decoded
        let name = commandName(first.decoded)
        if compoundWords.contains(word) || groups.isEmpty == false { line.complex = true }
        if word == "coproc" { line.opaque = true }
        for (position, token) in tokens.enumerated() where token.wasQuoted == false {
            let op = redirectOperator(token.decoded)
            if op == ">&" || op == "<&", tokens.dropFirst(position + 1).first?.decoded == "p" { line.opaque = true }
        }
        if let names = definedFunctionNames(tokens, from: index, groups: groups) {
            for defined in names { define(defined, into: &line, state: &state) }
        }
        if name == "alias" {
            for argument in tokens.dropFirst(index + 1) where argument.decoded.hasPrefix("-") == false {
                guard let equals = argument.decoded.firstIndex(of: "=") else { continue }
                define(String(argument.decoded[..<equals]), into: &line, state: &state)
                flatten(String(argument.decoded[argument.decoded.index(after: equals)...]), into: &line, nesting: nesting + 1, state: &state)
            }
        }
        if variableSetters.contains(name),
           setsDynamicName(name, droppingRedirects(Array(tokens.dropFirst(index + 1))).map(\.decoded))
        {
            // `export "$(cat vars)"`, `declare -n r=$v`: the variable it
            // sets may be `BASH_ENV` or `ENV`.
            state.setsShellStartup = true
        }
        if name == "hash", tokens.dropFirst(index + 1).contains(where: { $0.decoded == "-p" || $0.decoded.contains("=") }) {
            // `hash -p /usr/bin/base64 echo` makes `echo` run another program.
            line.opaque = true
        }
        if case .none = commandStart(tokens), tokens.contains(where: { commandName($0.decoded) == "exec" }),
           redirectsInput(tokens)
        {
            // `exec < f`, `exec 0<&3`, `exec 0>&3`: later readers read that.
            line.stdinRedirected = true
        }
    }

    private static let variableSetters: Set<String> = [
        "export", "declare", "typeset", "local", "readonly", "read", "printf", "getopts",
    ]

    /// A setter whose variable name rv cannot read (`export "$x=…"`,
    /// `read "$v"`, `printf -v "$v"`), or a nameref whose target is not a
    /// literal name other than `BASH_ENV`/`ENV` (`declare -n r=${x}_ENV`,
    /// `declare -n r`, which takes its target later). Only name positions
    /// count: a dynamic value names nothing, except a nameref's.
    private static func setsDynamicName(_ command: String, _ words: [String]) -> Bool {
        switch command {
        case "printf":
            // Options up to the format; a dynamic one may be `-v`.
            var index = 0
            while index < words.count {
                let word = words[index]
                if isDynamic(word) { return true }
                guard word != "--", word.hasPrefix("-") else { return false }
                if word == "-v" {
                    index += 1
                    if index < words.count, isDynamic(words[index]) { return true }
                }
                index += 1
            }
            return false
        case "getopts":
            // `getopts [--] optstring name`: bash drops a leading `--`, so
            // skip it and any option-looking word (fail closed: each one
            // moves the name later). An unquoted dynamic optstring may
            // split and move the name, so any dynamic word up to and
            // including the name position counts.
            var index = 0
            while index < words.count {
                let word = words[index]
                if isDynamic(word) { return true }
                guard word.hasPrefix("-") else { break }
                index += 1
                if word == "--" { break }
            }
            return words.dropFirst(index).prefix(2).contains { isDynamic($0) }
        case "read":
            // Option values differ between shells (zsh `-p` takes none),
            // so every word may be a name.
            return words.contains { isDynamic($0) }
        default:
            let nameref = words.contains { $0.hasPrefix("-") && $0.dropFirst().contains("n") }
            for word in words {
                if word.hasPrefix("-") || word.hasPrefix("+") {
                    if isDynamic(word) { return true }
                    continue
                }
                if isDynamic(word.prefix { $0 != "=" }) { return true }
                guard nameref else { continue }
                guard let equals = word.firstIndex(of: "=") else { return true }
                let target = word[word.index(after: equals)...]
                if isLiteralName(target) == false || target == "BASH_ENV" || target == "ENV" { return true }
            }
            return false
        }
    }

    private static func isDynamic(_ word: some StringProtocol) -> Bool {
        word.contains("$") || word.contains("`")
    }

    private static func isLiteralName(_ word: Substring) -> Bool {
        guard let first = word.first, first == "_" || first.isASCII && first.isLetter else { return false }
        return word.allSatisfy { $0 == "_" || $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// `name() …`, `name () …`, `function name …`: the names defined.
    /// A definition whose body is not a group is opaque (zsh `f() cmd`).
    private static func definedFunctionNames(_ tokens: [CommandToken], from index: Int, groups: [String]) -> [String]? {
        let words = tokens.dropFirst(index).map(\.decoded)
        guard let first = words.first else { return nil }
        if first == "function", tokens[index].wasQuoted == false {
            let names = words.dropFirst().prefix { $0 != "()" }.map { $0.hasSuffix("()") ? String($0.dropLast(2)) : $0 }
            return groups.isEmpty ? ["function"] : names
        }
        if first.hasSuffix("()") {
            return groups.isEmpty ? ["function"] : [String(first.dropLast(2))].filter { $0.isEmpty == false }
        }
        if words.count > 1, words[1] == "()" {
            return groups.isEmpty ? ["function"] : [first]
        }
        return nil
    }

    private static func define(_ raw: String, into line: inout Line, state: inout ScanState) {
        let name = commandName(raw)
        line.complex = true
        state.definedNames.insert(name)
        if raw == "function" || redefinitionHides(name) { line.opaque = true }
    }

    /// A name whose meaning the floor relies on.
    private static func redefinitionHides(_ name: String) -> Bool {
        wrapperValueOptions[name] != nil || shells.contains(name) || isInterpreter(name)
            || lifecycleVerbs.contains(name) || readerNames.contains(name)
    }

    private static let readerNames: Set<String> = [
        "echo", "printf", "print", "cat", "eval", "source", ".", "trap", "ssh", "xargs", "parallel", "find",
        "awk", "gawk", "mawk", "nawk", "sed", "gsed", "read", "hash", "alias", "unalias", "enable",
        "at", "batch", "crontab",
        // Read as silent producers.
        "cd", "true", "false", ":", "test", "[", "export", "unset", "local", "readonly", "shift", "exit",
        "return", "sleep", "wait", "set",
    ]

    private static let compoundWords: Set<String> = [
        "if", "then", "elif", "else", "fi", "while", "until", "for", "select", "case", "esac", "do", "done",
        "function", "coproc", "repeat",
    ]
}

/// The literal producers of each reader, computed once and only when a
/// reader asks.
struct Producers {
    private struct Facts {
        let outputs: [String?]
        let unreadableCount: Int
        /// Producers whose text could splice with another's: not ending
        /// in a newline, or holding a backslash.
        let splicedCount: Int
        /// Per command: index of its pipeline's first stage, and how many
        /// unreadable producers come before it in that pipeline.
        let pipelineStarts: [(start: Int, unreadableBefore: Int)]
    }

    private let line: Line
    private let inherited: () -> Feed
    private var inheritedFeed: Feed?
    private var facts: Facts?

    init(_ line: Line, inherited: @escaping () -> Feed) {
        self.line = line
        self.inherited = inherited
    }

    mutating func feed(for index: Int) -> Feed {
        if line.complex {
            let facts = loadFacts()
            // Order and repetition are unknown, so each producer must emit
            // whole lines (no `echo -n`, no continuation) that are read
            // alone as well as joined: no two can splice into one command.
            let others = facts.unreadableCount - (facts.outputs[index] == nil ? 1 : 0)
            let start = loadInherited()
            guard start.literal, others == 0, facts.splicedCount == 0 else { return .unreadable }
            let parts = ([start.text] + facts.outputs.compactMap { $0 }).filter { $0.isEmpty == false }
            return Feed(literal: true, text: parts.joined(), parts: parts)
        }
        let command = line.commands[index]
        guard command.stage > 0 else { return loadInherited() }
        let facts = loadFacts()
        let pipeline = facts.pipelineStarts[index]
        guard pipeline.unreadableBefore == 0 else { return .unreadable }
        return Feed(literal: true, text: facts.outputs[pipeline.start..<index].compactMap { $0 }.joined())
    }

    private mutating func loadInherited() -> Feed {
        if let inheritedFeed { return inheritedFeed }
        let feed = inherited()
        inheritedFeed = feed
        return feed
    }

    private mutating func loadFacts() -> Facts {
        if let facts { return facts }
        let outputs = line.commands.map(OpaqueExecution.producerOutput)
        var starts: [(start: Int, unreadableBefore: Int)] = []
        var start = 0
        var unreadable = 0
        for (index, command) in line.commands.enumerated() {
            if index == 0 || command.piece != line.commands[index - 1].piece {
                start = index
                unreadable = 0
            }
            starts.append((start, unreadable))
            if outputs[index] == nil { unreadable += 1 }
        }
        let spliced = outputs.filter { output in
            guard let output, output.isEmpty == false else { return false }
            return output.hasSuffix("\n") == false || output.contains("\\")
        }.count
        let loaded = Facts(
            outputs: outputs, unreadableCount: outputs.filter { $0 == nil }.count, splicedCount: spliced,
            pipelineStarts: starts
        )
        facts = loaded
        return loaded
    }
}
