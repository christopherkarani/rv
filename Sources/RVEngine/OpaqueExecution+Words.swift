extension ShellLexer {
    /// The words of one simple command, as the shell splits them: quotes
    /// removed (`$'…'` keeps its `$` marker, so it reads as expanded),
    /// backslash escapes resolved, `$(…)`, backticks and `<(…)`/`>(…)`/
    /// `=(…)` kept whole, comments dropped, and each redirect operator
    /// (`<`, `<<`, `<<-`, `<<<`, `<&`, `<>`, `>`, `>>`, `>&`, `>|`, `&>`,
    /// `&>>`, with its fd digits or `{name}`) its own word, so its target
    /// is the next.
    static func words(_ text: String) -> [CommandToken] {
        var reader = WordReader(Array(text.unicodeScalars))
        return reader.run()
    }

    /// An operator word `words` split out.
    static func isRedirectOperator(_ token: CommandToken) -> Bool {
        guard token.wasQuoted == false else { return false }
        return redirectOperators.contains(String(OpaqueExecution.redirectOperator(token.decoded)))
    }

    private static let redirectOperators: Set<String> = [
        "<", "<<", "<<-", "<<<", "<&", "<>", ">", ">>", ">&", ">|", "&>", "&>>",
    ]

    private static let operatorSpellings = ["<<<", "<<-", "<<", "<&", "<>", "<", ">>", ">&", ">|", ">"]

    private struct WordReader {
        let s: [Unicode.Scalar]
        var tokens: [CommandToken] = []
        var word = String.UnicodeScalarView()
        var inWord = false
        var quoted = false
        var ansiC = false
        var index = 0

        init(_ s: [Unicode.Scalar]) { self.s = s }

        mutating func run() -> [CommandToken] {
            while index < s.count {
                let c = s[index]
                let next: Unicode.Scalar? = index + 1 < s.count ? s[index + 1] : nil
                switch c {
                case " ", "\t", "\n":
                    end()
                    index += 1
                case "#" where inWord == false:
                    while index < s.count, s[index] != "\n" { index += 1 }
                case "\\":
                    if let next { word.append(next) }
                    inWord = true
                    quoted = true
                    index += 2
                case "'":
                    single()
                case "\"":
                    double()
                case "`":
                    raw(through: backtickEnd(from: index))
                case "$" where next == "(":
                    raw(through: parenEnd(from: index + 1))
                case "=" where next == "(" && inWord == false:
                    raw(through: parenEnd(from: index + 1))
                case "<" where next == "(" && inWord == false, ">" where next == "(" && inWord == false:
                    raw(through: parenEnd(from: index + 1))
                case "<", ">":
                    redirect()
                case "&" where next == ">":
                    end()
                    let op = index + 2 < s.count && s[index + 2] == ">" ? "&>>" : "&>"
                    emit(op)
                    index += op.unicodeScalars.count
                default:
                    word.append(c)
                    inWord = true
                    index += 1
                }
            }
            end()
            return tokens
        }

        private mutating func end() {
            if inWord { tokens.append(CommandToken(decoded: String(word), wasQuoted: quoted, wasAnsiC: ansiC)) }
            word = String.UnicodeScalarView()
            inWord = false
            quoted = false
            ansiC = false
        }

        private mutating func emit(_ op: String) {
            tokens.append(CommandToken(decoded: op, wasQuoted: false))
        }

        /// A redirect operator; digits or a `{name}` just read (`2>`,
        /// `{fd}<`) are its fd.
        private mutating func redirect() {
            var fd = ""
            let text = String(word)
            if inWord, quoted == false,
               text.allSatisfy({ $0.isASCII && $0.isNumber })
                   || text.hasPrefix("{") && text.hasSuffix("}") && OpaqueExecution.isFDName(text.dropFirst().dropLast())
            {
                fd = String(word)
                word = String.UnicodeScalarView()
                inWord = false
            }
            end()
            let rest = String(String.UnicodeScalarView(s[index..<min(index + 3, s.count)]))
            let op = ShellLexer.operatorSpellings.first { rest.hasPrefix($0) } ?? String(s[index])
            emit(fd + op)
            index += op.unicodeScalars.count
        }

        private mutating func single() {
            let isAnsiC = inWord && word.last == "$"
            inWord = true
            quoted = true
            if isAnsiC { ansiC = true }
            index += 1
            while index < s.count, s[index] != "'" {
                if isAnsiC, s[index] == "\\", index + 1 < s.count {
                    word.append(s[index])
                    word.append(s[index + 1])
                    index += 2
                    continue
                }
                word.append(s[index])
                index += 1
            }
            index += 1
        }

        private mutating func double() {
            inWord = true
            quoted = true
            index += 1
            while index < s.count, s[index] != "\"" {
                let c = s[index]
                if c == "\\", index + 1 < s.count {
                    let escaped = s[index + 1]
                    if escaped != "$", escaped != "`", escaped != "\"", escaped != "\\", escaped != "\n" { word.append(c) }
                    if escaped != "\n" { word.append(escaped) }
                    index += 2
                    continue
                }
                if c == "$", index + 1 < s.count, s[index + 1] == "(" {
                    appendRaw(through: parenEnd(from: index + 1))
                    continue
                }
                if c == "`" {
                    appendRaw(through: backtickEnd(from: index))
                    continue
                }
                word.append(c)
                index += 1
            }
            index += 1
        }

        private mutating func raw(through end: Int) {
            inWord = true
            appendRaw(through: end)
        }

        private mutating func appendRaw(through end: Int) {
            word.append(contentsOf: s[index..<min(max(end, index + 1), s.count)])
            index = max(end, index + 1)
        }

        private func backtickEnd(from start: Int) -> Int {
            var i = start + 1
            while i < s.count, s[i] != "`" { i += s[i] == "\\" ? 2 : 1 }
            return min(i + 1, s.count)
        }

        /// The index after the `)` matching the `(` at `open`, skipping
        /// quotes and escapes.
        private func parenEnd(from open: Int) -> Int {
            var depth = 0
            var i = open
            while i < s.count {
                switch s[i] {
                case "\\":
                    i += 1
                case "'":
                    let ansiC = i > 0 && s[i - 1] == "$"
                    i += 1
                    while i < s.count, s[i] != "'" { i += ansiC && s[i] == "\\" ? 2 : 1 }
                case "\"":
                    i += 1
                    while i < s.count, s[i] != "\"" { i += s[i] == "\\" ? 2 : 1 }
                case "(":
                    depth += 1
                case ")":
                    depth -= 1
                    if depth == 0 { return i + 1 }
                default:
                    break
                }
                i += 1
            }
            return s.count
        }
    }
}
