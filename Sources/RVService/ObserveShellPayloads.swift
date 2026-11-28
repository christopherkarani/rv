/// The program text a command hands a shell (`sh`/`bash`/`zsh`/`dash`/`ksh`
/// `-c`) or `eval`, read with POSIX quoting: single quotes, double quotes
/// with their four escapes, a backslash outside quotes, and `$'…'`. So
/// `sh -c 'sh -c '\''rm -rf /usr'\'''` (the `shlex.quote` form) yields
/// `sh -c 'rm -rf /usr'`, then `rm -rf /usr`.
///
/// The launcher parser (`launchedCommands`) is not escape-aware, so
/// `ObserveFloor` reads each payload found here for a catastrophe as well.
/// It only ever adds texts to read: a shell name anywhere in a command
/// (after `sudo`, `timeout 5`, `xargs`) opens its `-c` operand.
enum ObserveShellPayloads {
    /// Nested payloads deeper than this are not opened. A 64 KiB command
    /// (the engine's cap) cannot quote this deep: each level of
    /// `'\''` quoting multiplies its quotes by four.
    static let maxDepth = 16

    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh"]

    /// Every payload in `text`, outermost first, each followed by its own.
    static func payloads(_ text: String) -> [String] {
        payloads(text, depth: 0)
    }

    private static func payloads(_ text: String, depth: Int) -> [String] {
        guard depth < maxDepth else { return [] }
        return simpleCommands(text).compactMap(payload).flatMap { [$0] + payloads($0, depth: depth + 1) }
    }

    /// The `-c` operand of the first shell named in `words`, or what an
    /// `eval` runs.
    private static func payload(_ words: [String]) -> String? {
        for (index, word) in words.enumerated() {
            let name = word.split(separator: "/").last.map(String.init) ?? word
            if name == "eval" {
                let rest = words.dropFirst(index + 1)
                return rest.isEmpty ? nil : rest.joined(separator: " ")
            }
            guard shells.contains(name) else { continue }
            var next = index + 1
            var runsText = false
            while next < words.count, let first = words[next].first, first == "-" || first == "+" {
                let option = words[next]
                next += 1
                if option == "--" { break }
                if option.hasPrefix("--") { continue }
                if option.dropFirst().contains("c") && first == "-" { runsText = true }
                if option.dropFirst().contains(where: { $0 == "o" || $0 == "O" }) { next += 1 }
            }
            return runsText && next < words.count ? words[next] : nil
        }
        return nil
    }

    /// The simple commands of `text` as decoded words, split at unquoted
    /// `;`, `&`, `|`, newlines and parentheses. Redirect operators split
    /// words; `$(…)` and backticks stay as written inside their word.
    static func simpleCommands(_ text: String) -> [[String]] {
        let chars = Array(text)
        var commands: [[String]] = []
        var words: [String] = []
        var word = ""
        var inWord = false
        var index = 0
        func endWord() {
            if inWord { words.append(word) }
            word = ""
            inWord = false
        }
        func add<S: StringProtocol>(_ piece: S) {
            word.append(contentsOf: piece)
            inWord = true
        }
        func endCommand() {
            endWord()
            if words.isEmpty == false { commands.append(words) }
            words = []
        }
        func scanParenthesized(from start: Int) -> Int {
            var depth = 0
            var cursor = start
            while cursor < chars.count {
                if chars[cursor] == "(" { depth += 1 } else if chars[cursor] == ")" {
                    depth -= 1
                    if depth == 0 { return cursor + 1 }
                }
                cursor += 1
            }
            return cursor
        }
        while index < chars.count {
            let char = chars[index]
            switch char {
            case " ", "\t":
                endWord()
                index += 1
            case "\n", "\r", "\r\n", ";", "&", "|", "(", ")":
                endCommand()
                index += 1
            case "<", ">":
                endWord()
                index += 1
            case "#" where inWord == false:
                while index < chars.count, chars[index] != "\n" { index += 1 }
            case "\\":
                if index + 1 < chars.count {
                    if chars[index + 1] != "\n" { add(String(chars[index + 1])) }
                    index += 2
                } else {
                    add("\\")
                    index += 1
                }
            case "'":
                var cursor = index + 1
                var literal = ""
                while cursor < chars.count, chars[cursor] != "'" {
                    literal.append(chars[cursor])
                    cursor += 1
                }
                add(literal)
                index = cursor + 1
            case "\"":
                var cursor = index + 1
                var literal = ""
                while cursor < chars.count, chars[cursor] != "\"" {
                    if chars[cursor] == "\\", cursor + 1 < chars.count, "$`\"\\\n".contains(chars[cursor + 1]) {
                        if chars[cursor + 1] != "\n" { literal.append(chars[cursor + 1]) }
                        cursor += 2
                        continue
                    }
                    literal.append(chars[cursor])
                    cursor += 1
                }
                add(literal)
                index = cursor + 1
            case "$" where index + 1 < chars.count && chars[index + 1] == "'":
                var cursor = index + 2
                var literal = ""
                while cursor < chars.count, chars[cursor] != "'" {
                    if chars[cursor] == "\\", cursor + 1 < chars.count {
                        let escaped = chars[cursor + 1]
                        literal.append(escaped == "n" ? "\n" : escaped == "t" ? "\t" : escaped)
                        cursor += 2
                        continue
                    }
                    literal.append(chars[cursor])
                    cursor += 1
                }
                add(literal)
                index = cursor + 1
            case "$" where index + 1 < chars.count && chars[index + 1] == "(":
                let end = scanParenthesized(from: index + 1)
                add(String(chars[index..<min(end, chars.count)]))
                index = end
            case "`":
                var cursor = index + 1
                while cursor < chars.count, chars[cursor] != "`" { cursor += 1 }
                let end = min(cursor + 1, chars.count)
                add(String(chars[index..<end]))
                index = end
            default:
                add(String(char))
                index += 1
            }
        }
        endCommand()
        return commands
    }
}
