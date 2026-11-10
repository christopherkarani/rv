/// POSIX shell quoting for paths baked into host hook commands, which hosts
/// run through `sh -c`. A HOME with a space must not split the command: the
/// shell would then exit non-zero and most hosts treat that as a
/// non-blocking error, so the guard would silently fail open.
enum ShellWord {
    /// `value` unchanged when every character is shell-safe (so ordinary
    /// installs keep their exact bytes), else single-quoted with `'` written
    /// as `'\''`.
    static func quote(_ value: String) -> String {
        if value.isEmpty == false, value.allSatisfy(isSafe) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Splits the first shell word off `text`: unquoted characters,
    /// single-quoted runs and backslash escapes up to the first unquoted
    /// space. Nil for an empty word or an unterminated quote.
    static func leadingWord(_ text: Substring) -> (word: String, rest: Substring)? {
        var word = ""
        var index = text.startIndex
        var inQuote = false
        var sawQuote = false
        while index < text.endIndex {
            let character = text[index]
            if inQuote {
                if character == "'" {
                    inQuote = false
                } else {
                    word.append(character)
                }
            } else if character == "'" {
                inQuote = true
                sawQuote = true
            } else if character == "\\" {
                let next = text.index(after: index)
                guard next < text.endIndex else { return nil }
                word.append(text[next])
                index = next
            } else if character == " " {
                break
            } else {
                word.append(character)
            }
            index = text.index(after: index)
        }
        guard inQuote == false, word.isEmpty == false || sawQuote else { return nil }
        return (word, text[index...])
    }

    private static func isSafe(_ character: Character) -> Bool {
        character.isASCII
            && (character.isLetter || character.isNumber || "_@%+=:,./-".contains(character))
    }
}
