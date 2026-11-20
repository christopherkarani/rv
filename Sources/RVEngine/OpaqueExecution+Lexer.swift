/// The shell structure the observe floor needs, read the way the shell
/// reads it: quotes (`'…'`, `"…"`, `$'…'` with its escapes, backticks),
/// `$(…)`/`<(…)`/`>(…)`/`=(…)`/`$((…))` nesting, `{ … }` and `( … )`
/// groups, comments, backslash-newline continuations, and heredoc bodies.
/// A top-level heredoc body is lifted out of the text onto its piece; a
/// nested one is kept verbatim but never read as code, so an apostrophe in
/// a body cannot desync the quoting of the lines after it.
///
/// `ambiguous` marks text the shells may split differently than this walk
/// does (an unbalanced group, a `}` in argument position, which zsh reads
/// as a closer and bash as a word): the caller fails closed on it.
enum ShellLexer {
    struct Heredoc {
        let body: String
        /// A quoted delimiter, or a body with no `$`, backtick or
        /// backslash: the text the reader gets is the text written.
        let literal: Bool
    }

    struct Piece {
        var text: String
        var heredocs: [Heredoc] = []
        /// Inner texts of the piece's `$(…)`, backticks, `<(…)`, `>(…)`,
        /// `=(…)` and arithmetic, outside any other command text.
        var substitutions: [String] = []
        /// Bodies of the piece's `{ … }`/`( … )` groups (`.none` only;
        /// the group is cut from `text`).
        var groups: [String] = []
    }

    enum Split {
        case list
        case pipe
        case none
    }

    struct Result {
        var pieces: [Piece] = []
        var ambiguous = false
    }

    private enum ParenKind {
        case substitution
        case arithmetic
        case group
        case plain
    }

    private enum Frame {
        case paren(ParenKind, from: Int?)
        case brace(group: Bool, from: Int?)
        case double
        case backtick(from: Int?)

        /// Command text, read on its own when its piece is read.
        var holdsCommands: Bool {
            switch self {
            case .paren(let kind, _): return kind != .plain
            case .brace(let group, _): return group
            case .double: return false
            case .backtick: return true
            }
        }
    }

    private struct PendingHeredoc {
        let delimiter: [Unicode.Scalar]
        let stripTabs: Bool
        let quoted: Bool
    }

    static func walk(_ text: String, split: Split) -> Result {
        var walker = Walker(Array(text.unicodeScalars), split: split)
        return walker.run()
    }

    /// Extra texts a lexical guard reads besides the raw command, when the
    /// shell splits it differently than a quote-naive reader would: the
    /// text with heredoc bodies removed (one text, so `cd` context holds),
    /// then each list command alone, so a body's apostrophe or a `$'\''`
    /// cannot hide the commands after it. Empty for a single plain command.
    static func guardReadings(_ raw: String) -> [String] {
        let pieces = walk(raw, split: .list).pieces.map(\.text)
        guard pieces.count > 1 || pieces.first.map({ $0 != raw.trimmingCharacters(in: .whitespacesAndNewlines) }) == true
        else { return [] }
        return [pieces.joined(separator: "\n")] + (pieces.count > 1 ? pieces : [])
    }

    private struct Walker {
        let s: [Unicode.Scalar]
        let split: Split
        var result = Result()
        var stack: [Frame] = []
        var commandFrames = 0
        var current: [Unicode.Scalar] = []
        var heredocs: [Heredoc] = []
        var substitutions: [String] = []
        var groups: [String] = []
        var pending: [PendingHeredoc] = []
        var index = 0

        init(_ s: [Unicode.Scalar], split: Split) {
            self.s = s
            self.split = split
        }

        mutating func run() -> Result {
            while index < s.count {
                switch stack.last {
                case .double?: stepDouble()
                case .backtick(let from)?: stepBacktick(from)
                default: stepNormal()
                }
            }
            if pending.isEmpty == false { readHeredocBodies(keep: false) }
            flush()
            if stack.isEmpty == false { result.ambiguous = true }
            return result
        }

        private var collecting: Bool { commandFrames == 0 }

        private func peek(_ offset: Int) -> Unicode.Scalar? {
            index + offset < s.count ? s[index + offset] : nil
        }

        private mutating func push(_ frame: Frame) {
            if frame.holdsCommands { commandFrames += 1 }
            stack.append(frame)
        }

        private mutating func pop() {
            if stack.removeLast().holdsCommands { commandFrames -= 1 }
        }

        private mutating func flush() {
            let piece = String(String.UnicodeScalarView(current)).trimmingCharacters(in: .whitespaces)
            if piece.isEmpty == false || heredocs.isEmpty == false || groups.isEmpty == false {
                result.pieces.append(
                    Piece(text: piece, heredocs: heredocs, substitutions: substitutions, groups: groups)
                )
            }
            current = []
            heredocs = []
            substitutions = []
            groups = []
        }

        private func atWordStart() -> Bool {
            guard let last = current.last else { return true }
            return ShellLexer.wordBreaks.contains(last)
        }

        /// After `;`, `&`, `|`, a newline, `{`, `}` or `)`, a word is in
        /// command position.
        private func atCommandPosition() -> Bool {
            guard let last = current.last(where: { $0 != " " && $0 != "\t" }) else { return true }
            return ShellLexer.commandStarters.contains(last)
        }

        private mutating func append(_ count: Int = 1) {
            for _ in 0..<count where index < s.count {
                current.append(s[index])
                index += 1
            }
        }

        private func continuation() -> Int? {
            guard s[index] == "\\", let next = peek(1) else { return nil }
            if next == "\n" { return 2 }
            if next == "\r", peek(2) == "\n" { return 3 }
            return nil
        }

        private func text(from start: Int) -> String {
            String(String.UnicodeScalarView(current[min(start, current.count)...]))
        }

        private mutating func stepDouble() {
            let c = s[index]
            if let skip = continuation() { index += skip; return }
            if c == "\\" { append(2); return }
            if c == "\"" { pop(); append(); return }
            if c == "`" {
                append()
                push(.backtick(from: collecting ? current.count : nil))
                return
            }
            if c == "$", peek(1) == "(" {
                let arithmetic = peek(2) == "("
                let from = collecting ? current.count + (arithmetic ? 3 : 2) : nil
                append(arithmetic ? 3 : 2)
                push(.paren(arithmetic ? .arithmetic : .substitution, from: from))
                return
            }
            append()
        }

        private mutating func stepBacktick(_ from: Int?) {
            let c = s[index]
            if c == "\\" { append(2); return }
            if c == "`" {
                pop()
                if let from { substitutions.append(text(from: from)) }
                append()
                return
            }
            append()
        }

        private mutating func stepNormal() {
            let c = s[index]
            let next = peek(1)
            if let skip = continuation() { index += skip; return }
            switch c {
            case "\\":
                append(2)
            case "'":
                quoteSingle()
            case "\"":
                push(.double)
                append()
            case "`":
                append()
                push(.backtick(from: collecting ? current.count : nil))
            case "#" where atWordStart():
                while index < s.count, s[index] != "\n" { append() }
            case "<" where next == "<" && peek(2) == "<":
                append(3)
            case "<" where next == "<" && inArithmetic() == false:
                heredocOperator()
            case "$" where next == "(", "<" where next == "(", ">" where next == "(":
                let arithmetic = c == "$" && peek(2) == "("
                let width = arithmetic ? 3 : 2
                let from = collecting ? current.count + width : nil
                append(width)
                push(.paren(arithmetic ? .arithmetic : .substitution, from: from))
            case "=" where next == "(" && atWordStart():
                let from = collecting ? current.count + 2 : nil
                append(2)
                push(.paren(.substitution, from: from))
            case "$" where next == "{":
                append(2)
                push(.brace(group: false, from: nil))
            case "(":
                openParen()
            case ")":
                closeParen()
            case "{" where atWordStart() && (next == nil || next == " " || next == "\t" || next == "\n"):
                append()
                push(.brace(group: true, from: collecting ? current.count : nil))
            case "}":
                closeBrace()
            case "\n":
                newline()
            default:
                if stack.isEmpty, let width = ShellLexer.separatorWidth(s, at: index, split: split, previous: current.last) {
                    flush()
                    index += width
                    return
                }
                append()
            }
        }

        private func inArithmetic() -> Bool {
            stack.contains { frame in
                if case .paren(.arithmetic, _) = frame { return true }
                return false
            }
        }

        /// `'…'`, or `$'…'`, where a backslash escapes the next character
        /// (`$'\''` is one quote).
        private mutating func quoteSingle() {
            let ansiC = current.last == "$"
            append()
            while index < s.count {
                let q = s[index]
                append()
                if ansiC, q == "\\" { append(); continue }
                if q == "'" { return }
            }
        }

        private mutating func openParen() {
            guard atWordStart() else {
                // `f()`, `x=(a b)`, a glob qualifier: part of the word.
                append()
                push(.paren(.plain, from: nil))
                return
            }
            if peek(1) == "(" {
                // `(( … ))`: an arithmetic command.
                let from = collecting ? current.count + 2 : nil
                append(2)
                push(.paren(.arithmetic, from: from))
                return
            }
            append()
            push(.paren(.group, from: collecting ? current.count : nil))
        }

        private mutating func closeParen() {
            guard case .paren(let kind, let from)? = stack.last else {
                if case .brace? = stack.last { result.ambiguous = true }
                // A case pattern's `)`.
                append()
                return
            }
            pop()
            switch kind {
            case .plain:
                append()
            case .arithmetic:
                if let from { substitutions.append(text(from: from)) }
                if peek(1) == ")" { append(2) } else { result.ambiguous = true; append() }
            case .substitution:
                if let from { substitutions.append(text(from: from)) }
                append()
            case .group:
                closeGroup(from)
            }
        }

        private mutating func closeBrace() {
            guard case .brace(let group, let from)? = stack.last else {
                append()
                return
            }
            if group {
                let standalone = atWordStart() && (peek(1).map { ShellLexer.wordEnds.contains($0) } ?? true)
                guard standalone else { append(); return }
                // bash closes a group only at command position; zsh at any
                // `}` word.
                if atCommandPosition() == false { result.ambiguous = true }
            }
            pop()
            if group { closeGroup(from) } else { append() }
        }

        /// Records a top-level group's body; `.none` cuts the group out of
        /// the piece text, leaving the words around it.
        private mutating func closeGroup(_ from: Int?) {
            guard let from else { append(); return }
            groups.append(text(from: from))
            if split == .none {
                current.removeSubrange((from - 1)...)
                current.append(" ")
                index += 1
            } else {
                append()
            }
        }

        private mutating func newline() {
            if pending.isEmpty == false {
                if stack.isEmpty {
                    index += 1
                    readHeredocBodies(keep: false)
                    if split == .list { flush() } else { current.append("\n") }
                } else {
                    append()
                    readHeredocBodies(keep: true)
                }
                return
            }
            if stack.isEmpty, split == .list {
                flush()
                index += 1
                return
            }
            append()
        }

        /// `<<WORD`/`<<-WORD`: the delimiter with its quotes removed
        /// (`'E'OF`, `\EOF`, `$'EOF'` all mean `EOF`).
        private mutating func heredocOperator() {
            append(2)
            var stripTabs = false
            if peek(0) == "-" { stripTabs = true; append() }
            while let c = peek(0), c == " " || c == "\t" { append() }
            var delimiter: [Unicode.Scalar] = []
            var quoted = false
            while let d = peek(0), ShellLexer.wordEnds.contains(d) == false {
                if d == "$", let q = peek(1), q == "'" || q == "\"" {
                    append()
                    continue
                }
                if d == "'" || d == "\"" {
                    quoted = true
                    append()
                    while let e = peek(0), e != d { delimiter.append(e); append() }
                    append()
                    continue
                }
                if d == "\\", let e = peek(1) {
                    quoted = true
                    delimiter.append(e)
                    append(2)
                    continue
                }
                delimiter.append(d)
                append()
            }
            pending.append(PendingHeredoc(delimiter: delimiter, stripTabs: stripTabs, quoted: quoted))
        }

        /// Reads each pending body from `index`, line by line, up to its
        /// delimiter line. `keep` leaves the body in the text, unread.
        private mutating func readHeredocBodies(keep: Bool) {
            for doc in pending {
                var lines: [String] = []
                while index < s.count {
                    var end = index
                    while end < s.count, s[end] != "\n" { end += 1 }
                    let line = s[index..<end]
                    if keep { current.append(contentsOf: s[index..<min(end + 1, s.count)]) }
                    index = min(end + 1, s.count)
                    let check = doc.stripTabs ? line.drop(while: { $0 == "\t" }) : line
                    if Array(check) == doc.delimiter { break }
                    if keep == false { lines.append(String(String.UnicodeScalarView(line))) }
                }
                guard keep == false else { continue }
                let body = lines.joined(separator: "\n")
                let plain = body.contains("$") == false && body.contains("`") == false && body.contains("\\") == false
                heredocs.append(Heredoc(body: body, literal: doc.quoted || plain))
            }
            pending = []
        }
    }

    private static func separatorWidth(_ s: [Unicode.Scalar], at index: Int, split: Split, previous: Unicode.Scalar?) -> Int? {
        let c = s[index]
        let next: Unicode.Scalar? = index + 1 < s.count ? s[index + 1] : nil
        switch split {
        case .none:
            return nil
        case .pipe:
            guard c == "|" else { return nil }
            if next == "|" || previous == "|" || previous == ">" { return nil }
            return next == "&" ? 2 : 1
        case .list:
            switch c {
            case ";":
                return 1
            case "&":
                if next == "&" { return 2 }
                // `&>`, `>&`, `<&`, `|&` are redirects or a pipe.
                if next == ">" || previous == ">" || previous == "<" || previous == "|" { return nil }
                return 1
            case "|":
                return next == "|" ? 2 : nil
            default:
                return nil
            }
        }
    }

    private static let wordBreaks: Set<Unicode.Scalar> = [" ", "\t", "\n", ";", "|", "&", "(", ")", "<", ">"]
    private static let wordEnds: Set<Unicode.Scalar> = [" ", "\t", "\n", ";", "|", "&", "(", ")", "<", ">"]
    private static let commandStarters: Set<Unicode.Scalar> = [";", "&", "|", "\n", "{", "}", ")"]
}
