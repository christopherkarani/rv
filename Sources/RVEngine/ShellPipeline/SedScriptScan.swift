import Foundation

/// What a sed script does beyond filtering: files it writes (`w`/`W`
/// commands, `s///w` flag) and whether it executes a command (GNU `e`
/// command or `s///e` flag).
struct SedScriptEffects: Equatable {
    var writeTargets: [String] = []
    var executes = false
}

/// Scans one sed script (one `-e` fragment or the script operand). `w` and
/// `e` only count at command position: inside a regex, a replacement, a
/// `y` table, an `a`/`i`/`c` text, a label, or a comment they are data.
/// An unparseable tail stops the scan; sed itself rejects such scripts.
func sedScriptEffects(_ script: String) -> SedScriptEffects {
    var scanner = SedScanner(chars: Array(script))
    scanner.run()
    return scanner.effects
}

/// The script texts of a sed invocation (`args` excludes the program name):
/// every `-e`/`--expression` value, else the first operand. A `-f` script
/// file is unreadable here and contributes nothing.
func sedScriptTexts(_ args: [String]) -> [String] {
    var scripts: [String] = []
    var operands: [String] = []
    var scriptFromFile = false
    var index = 0
    while index < args.count {
        let word = args[index]
        index += 1
        if word == "--" {
            operands += args[index...]
            break
        }
        if word.hasPrefix("--") {
            let (name, attached) = splitLongOption(word)
            if "expression".hasPrefix(name), name.count >= 2 {
                if let attached { scripts.append(attached) } else if index < args.count {
                    scripts.append(args[index])
                    index += 1
                }
            } else if "file".hasPrefix(name), name.count >= 2 {
                scriptFromFile = true
                if attached == nil { index += 1 }
            } else if "line-length".hasPrefix(name), name.count >= 2, attached == nil {
                index += 1
            }
            continue
        }
        guard word.hasPrefix("-"), word.count > 1 else {
            operands.append(word)
            continue
        }
        index += consumeSedCluster(word, next: index < args.count ? args[index] : nil, scripts: &scripts,
                                   scriptFromFile: &scriptFromFile)
    }
    if scripts.isEmpty, scriptFromFile == false, let first = operands.first(where: { $0.isEmpty == false }) {
        scripts.append(first)
    }
    return scripts
}

private func splitLongOption(_ word: String) -> (name: String, attached: String?) {
    let body = word.dropFirst(2)
    guard let equals = body.firstIndex(of: "=") else { return (String(body), nil) }
    return (String(body[..<equals]), String(body[body.index(after: equals)...]))
}

/// Walks a short-flag cluster (`-n`, `-ne`, `-i.bak`); returns how many
/// following words it consumed.
private func consumeSedCluster(
    _ word: String,
    next: String?,
    scripts: inout [String],
    scriptFromFile: inout Bool
) -> Int {
    let letters = Array(word.dropFirst())
    for (offset, letter) in letters.enumerated() {
        let attached = String(letters[(offset + 1)...])
        switch letter {
        case "i":
            return 0
        case "e":
            if attached.isEmpty == false { scripts.append(attached); return 0 }
            guard let next else { return 0 }
            scripts.append(next)
            return 1
        case "f":
            scriptFromFile = true
            return attached.isEmpty ? 1 : 0
        case "l":
            return attached.isEmpty ? 1 : 0
        default:
            continue
        }
    }
    return 0
}

private struct SedScanner {
    let chars: [Character]
    var index = 0
    var effects = SedScriptEffects()

    init(chars: [Character]) {
        self.chars = chars
    }

    private var peek: Character? { index < chars.count ? chars[index] : nil }

    mutating func run() {
        while true {
            skip { $0.isWhitespace || $0 == ";" }
            guard peek != nil else { return }
            skipAddresses()
            guard let command = peek else { return }
            index += 1
            guard scanCommand(command) else { return }
        }
    }

    /// Consumes one command's arguments; false stops the scan.
    private mutating func scanCommand(_ command: Character) -> Bool {
        switch command {
        case "{", "}", "=", "d", "D", "g", "G", "h", "H", "n", "N", "p", "P", "x", "z", "F":
            return true
        case "#", "r", "R", "v":
            skipToEndOfLine()
            return true
        case "s":
            return scanSubstitute()
        case "y":
            return skipDelimited() && skipDelimited(delimiter: chars[index - 1])
        case "w", "W":
            addWriteTarget(readToEndOfLine())
            return true
        case "e":
            effects.executes = true
            skipToEndOfLine()
            return true
        case "a", "i", "c":
            skipAppendText()
            return true
        case ":", "b", "t", "T":
            skip { $0.isWhitespace && $0 != "\n" }
            skip { $0.isWhitespace == false && $0 != ";" && $0 != "}" }
            return true
        case "q", "Q", "l", "L":
            skip { $0.isWhitespace && $0 != "\n" }
            skip { $0.isNumber }
            return true
        default:
            return false
        }
    }

    private mutating func scanSubstitute() -> Bool {
        guard let delimiter = peek, delimiter != "\n", delimiter != "\\" else { return false }
        index += 1
        guard skipDelimited(delimiter: delimiter), skipDelimited(delimiter: delimiter) else { return false }
        while let flag = peek {
            switch flag {
            case "e":
                effects.executes = true
                index += 1
            case "w":
                index += 1
                addWriteTarget(readToEndOfLine())
                return true
            case "g", "p", "i", "I", "m", "M", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
                index += 1
            default:
                return true
            }
        }
        return true
    }

    private mutating func addWriteTarget(_ raw: String) {
        let target = raw.trimmingCharacters(in: .whitespaces)
        guard target.isEmpty == false, target != "/dev/stdout", target != "/dev/stderr" else { return }
        effects.writeTargets.append(target)
    }

    private mutating func skip(while predicate: (Character) -> Bool) {
        while let char = peek, predicate(char) { index += 1 }
    }

    private mutating func skipToEndOfLine() {
        _ = readToEndOfLine()
    }

    private mutating func readToEndOfLine() -> String {
        let start = index
        while let char = peek, char != "\n" { index += 1 }
        let text = String(chars[start..<index])
        if peek == "\n" { index += 1 }
        return text
    }

    /// `a`/`i`/`c` text runs to the first newline not escaped by `\`.
    private mutating func skipAppendText() {
        while let char = peek {
            index += char == "\\" ? 2 : 1
            if char == "\n" { return }
        }
    }

    /// Skips through the next unescaped `delimiter`; false when unterminated.
    private mutating func skipDelimited(delimiter: Character? = nil) -> Bool {
        let close = delimiter ?? peek
        if delimiter == nil { index += 1 }
        guard let close else { return false }
        while let char = peek {
            if char == "\\" {
                index += 2
                continue
            }
            index += 1
            if char == close { return true }
        }
        return false
    }

    private mutating func skipAddresses() {
        skip { $0.isWhitespace && $0 != "\n" }
        while skipOneAddress() {
            skip { $0.isWhitespace && $0 != "\n" }
            guard peek == "," else { break }
            index += 1
            skip { $0.isWhitespace && $0 != "\n" }
            _ = skipOneAddress()
        }
        while peek == "!" {
            index += 1
            skip { $0.isWhitespace && $0 != "\n" }
        }
    }

    private mutating func skipOneAddress() -> Bool {
        guard let char = peek else { return false }
        if char.isNumber || char == "+" || char == "~" {
            index += 1
            skip { $0.isNumber }
            if peek == "~" {
                index += 1
                skip { $0.isNumber }
            }
            return true
        }
        if char == "$" {
            index += 1
            return true
        }
        if char == "/" || char == "\\" {
            index += 1
            var delimiter: Character = "/"
            if char == "\\" {
                guard let custom = peek else { return false }
                delimiter = custom
                index += 1
            }
            guard skipDelimited(delimiter: delimiter) else {
                index = chars.count
                return false
            }
            skip { $0 == "I" || $0 == "M" }
            return true
        }
        return false
    }
}
