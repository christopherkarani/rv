/// Shell comments on inert commands.
///
/// bash, sh and zsh scripts (`-c`) read an unquoted `#` that starts a word
/// as a comment to the end of the line, so `ls # rm -rf /` runs only `ls`.
/// rv does not model comments and matched the comment text: those commands
/// denied. Stripping comments in general is NOT sound, though: an
/// interactive zsh without INTERACTIVE_COMMENTS (zsh's default) or a bash
/// with `shopt -u interactive_comments` reads `#` as an ordinary word, so
/// `rm -rf # /` there deletes `/`, and hosts that type into a terminal run
/// exactly such a shell. A comment is therefore only stripped where both
/// readings run the same thing:
///
/// - The comment holds only plain word characters (letters, digits, space,
///   tab, `_ . / : @ , + - % #`). Read literally it can then only add plain
///   words: no separator, redirect, substitution, quote, glob, tilde,
///   `=`-expansion or history expansion.
/// - Those words would land as extra operands of a command that ignores or
///   only prints/lists its operands: the simple command holding the `#`
///   starts with exactly `true`, `false`, `:`, `echo`, `pwd` or `ls`.
/// - The scan is certain where bash's own comment boundaries are: the `#`
///   follows a space, tab, newline or the start; quotes (`'…'`, `"…"`,
///   `$'…'`) and backslash escapes are tracked; and any construct whose
///   quoting this scan does not model — command or process substitution,
///   backticks, `${…}`, `$[…]`, parentheses, `[[`, heredocs and
///   here-strings, a backslash-newline, a `#` right after `< > ; & | ( )`,
///   unbalanced quotes — leaves the whole text unchanged.
///
/// - Nothing in the text can make an inert head run something else: no
///   word (quotes and backslashes removed) is `alias`, `function`, `hash`,
///   `enable`, `eval`, `source`, `trap` or a zsh equivalent, no command
///   word is `.` or dynamic (`$X`), and there is no `$'…'` quoting. A
///   literal `#` hands the comment words to whatever `echo` or `ls` names
///   by then (`alias echo=rm` then `echo # -rf ~` runs `rm -rf '#' ~`),
///   and stripping would hide them from the alias resolver too.
///
/// If any comment in the text misses one of these, nothing is stripped and
/// the text is evaluated as written (comment text included), as before.
enum ShellComments {
    static let inertHeads: Set<Substring> = ["true", "false", ":", "echo", "pwd", "ls"]

    /// `text` without its comments, or nil when it has none or any comment
    /// cannot be stripped soundly (see the type comment).
    static func strippingInertComments(_ text: String) -> String? {
        let bytes = Array(text.utf8)
        guard bytes.contains(UInt8(ascii: "#")) else { return nil }
        var comments: [Range<Int>] = []
        var index = 0
        var commandStart = 0
        // Index just past the last unquoted backslash escape: a `#` there is
        // mid-word (`ls \ #x` passes ` #x` to ls), whatever was escaped.
        var escapedUpTo = -1
        let count = bytes.count

        func byte(_ at: Int) -> UInt8? { at < count ? bytes[at] : nil }

        while index < count {
            let current = bytes[index]
            switch current {
            case UInt8(ascii: "'"):
                guard let close = bytes[(index + 1)...].firstIndex(of: UInt8(ascii: "'")) else { return nil }
                index = close + 1
            case UInt8(ascii: "\""):
                index += 1
                var closed = false
                while index < count {
                    let inner = bytes[index]
                    if inner == UInt8(ascii: "\\") {
                        guard let next = byte(index + 1), next != UInt8(ascii: "\n") else { return nil }
                        index += 2
                        continue
                    }
                    if inner == UInt8(ascii: "`") { return nil }
                    if inner == UInt8(ascii: "$"), let next = byte(index + 1),
                       next == UInt8(ascii: "(") || next == UInt8(ascii: "{") || next == UInt8(ascii: "[")
                    {
                        return nil
                    }
                    if inner == UInt8(ascii: "\"") {
                        closed = true
                        index += 1
                        break
                    }
                    index += 1
                }
                guard closed else { return nil }
            case UInt8(ascii: "\\"):
                guard let next = byte(index + 1), next != UInt8(ascii: "\n") else { return nil }
                index += 2
                escapedUpTo = index
            case UInt8(ascii: "$"):
                guard let next = byte(index + 1) else {
                    index += 1
                    continue
                }
                if next == UInt8(ascii: "(") || next == UInt8(ascii: "{") || next == UInt8(ascii: "[") {
                    return nil
                }
                if next == UInt8(ascii: "'") {
                    // ANSI-C quote: backslash escapes the next byte.
                    index += 2
                    var closed = false
                    while index < count {
                        if bytes[index] == UInt8(ascii: "\\") {
                            index += 2
                            continue
                        }
                        if bytes[index] == UInt8(ascii: "'") {
                            closed = true
                            index += 1
                            break
                        }
                        index += 1
                    }
                    guard closed else { return nil }
                } else {
                    index += 1
                }
            case UInt8(ascii: "`"), UInt8(ascii: "("), UInt8(ascii: ")"):
                return nil
            case UInt8(ascii: "["):
                if byte(index + 1) == UInt8(ascii: "[") { return nil }
                index += 1
            case UInt8(ascii: "<"):
                if byte(index + 1) == UInt8(ascii: "<") { return nil }
                index += 1
            case UInt8(ascii: ";"), UInt8(ascii: "&"), UInt8(ascii: "|"), UInt8(ascii: "\n"):
                index += 1
                commandStart = index
            case UInt8(ascii: "#"):
                let previous = index == 0 ? nil : bytes[index - 1]
                guard let previous else {
                    // A command-position `#` is not a word of an inert command.
                    return nil
                }
                if index == escapedUpTo {
                    index += 1
                } else if previous == UInt8(ascii: " ") || previous == UInt8(ascii: "\t") {
                    guard let end = commentEnd(bytes, from: index),
                          isInertHead(bytes[commandStart..<index])
                    else {
                        return nil
                    }
                    comments.append(index..<end)
                    index = end
                } else if previous == UInt8(ascii: "\n") || isOperatorByte(previous) {
                    return nil
                } else {
                    // Mid-word (`a#b`, `$#`, `\#`): not a comment in any shell.
                    index += 1
                }
            default:
                index += 1
            }
        }
        guard comments.isEmpty == false, mayRedefineCommands(bytes) == false else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(count)
        var cursor = 0
        for range in comments {
            out.append(contentsOf: bytes[cursor..<range.lowerBound])
            cursor = range.upperBound
        }
        out.append(contentsOf: bytes[cursor..<count])
        return String(decoding: out, as: UTF8.self)
    }

    /// Words that define or replace what a command name runs, or run
    /// text this scan does not see, in bash or zsh.
    static let redefiningWords: Set<String> = [
        "alias", "function", "functions", "hash", "enable", "eval", "source", "trap", "autoload", "zmodload",
    ]

    /// Reserved words after which the next word is still a command word.
    private static let leadingReservedWords: Set<String> = [
        "if", "then", "else", "elif", "do", "while", "until", "!", "{", "}", "time", "fi", "done",
    ]

    /// True when the text might make an inert head run another program:
    /// any word that, with quotes and backslashes removed, is one of
    /// `redefiningWords`; a command word that is `.` or holds `$`; or any
    /// `$'…'` (its escapes can spell any word). Over-approximate on purpose.
    private static func mayRedefineCommands(_ bytes: [UInt8]) -> Bool {
        var atCommandWord = true
        var word: [UInt8] = []
        var raw: [UInt8] = []
        func finishWord() -> Bool {
            defer {
                word.removeAll(keepingCapacity: true)
                raw.removeAll(keepingCapacity: true)
            }
            guard raw.isEmpty == false else { return false }
            let text = String(decoding: word, as: UTF8.self)
            if redefiningWords.contains(text) { return true }
            guard atCommandWord else { return false }
            if text == "." || raw.contains(UInt8(ascii: "$")) { return true }
            if leadingReservedWords.contains(text) { return false }
            // A prefix assignment (`X=1 cmd`) leaves the next word in command position.
            if let equals = raw.firstIndex(of: UInt8(ascii: "=")), equals > 0 { return false }
            atCommandWord = false
            return false
        }
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "$"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "'") {
                return true
            }
            switch byte {
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "<"), UInt8(ascii: ">"):
                if finishWord() { return true }
            case UInt8(ascii: "\n"), UInt8(ascii: ";"), UInt8(ascii: "&"), UInt8(ascii: "|"),
                 UInt8(ascii: "("), UInt8(ascii: ")"):
                if finishWord() { return true }
                atCommandWord = true
            case UInt8(ascii: "'"), UInt8(ascii: "\""), UInt8(ascii: "\\"):
                raw.append(byte)
            default:
                raw.append(byte)
                word.append(byte)
            }
            index += 1
        }
        return finishWord()
    }

    private static func isOperatorByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "<"), UInt8(ascii: ">"), UInt8(ascii: ";"), UInt8(ascii: "&"),
             UInt8(ascii: "|"), UInt8(ascii: "("), UInt8(ascii: ")"):
            return true
        default:
            return false
        }
    }

    /// End of the comment starting at `start` (the newline or the end), or
    /// nil when the comment holds anything but plain word characters.
    private static func commentEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        var index = start + 1
        while index < bytes.count, bytes[index] != UInt8(ascii: "\n") {
            guard isPlainCommentByte(bytes[index]) else { return nil }
            index += 1
        }
        return index
    }

    private static func isPlainCommentByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"):
            return true
        case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "_"), UInt8(ascii: "."),
             UInt8(ascii: "/"), UInt8(ascii: ":"), UInt8(ascii: "@"), UInt8(ascii: ","),
             UInt8(ascii: "+"), UInt8(ascii: "-"), UInt8(ascii: "%"), UInt8(ascii: "#"):
            return true
        default:
            return false
        }
    }

    /// The simple command before the `#` starts with an inert head: its
    /// first word is exactly one of `inertHeads`, unquoted and unescaped.
    private static func isInertHead(_ command: ArraySlice<UInt8>) -> Bool {
        var start = command.startIndex
        while start < command.endIndex, command[start] == UInt8(ascii: " ") || command[start] == UInt8(ascii: "\t") {
            start += 1
        }
        var end = start
        while end < command.endIndex, command[end] != UInt8(ascii: " "), command[end] != UInt8(ascii: "\t") {
            end += 1
        }
        guard end > start else { return false }
        let word = Substring(decoding: command[start..<end], as: UTF8.self)
        return inertHeads.contains(word)
    }
}
