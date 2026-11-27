/// A command line with the bodies of data heredocs blanked, so text that
/// is only a message or a file's content is never read as commands: a
/// commit message (`git commit -m "$(cat <<'EOF' … EOF)"`), or what `cat`
/// or `tee` writes to a file. A body any other command reads stays (`sh
/// <<EOF`, `cat <<EOF | sh`, `bash -c "$(cat <<EOF …)"`), as does every
/// body when the line cannot be followed: an unbalanced `)`, a heredoc line
/// that ends inside quotes or with a continuation, or a body without its
/// delimiter.
struct DataHeredocs {
    let text: String
    /// A blanked body holding `rv-secrets:allow` that its command writes to
    /// a file (`cat >> src/a.ts <<'EOF'`).
    let writesMarker: Bool

    init(_ raw: String) {
        if raw.contains("<<"), let scanned = Self.scan(raw) {
            text = scanned.text
            writesMarker = scanned.writesMarker
        } else {
            text = raw
            writesMarker = false
        }
    }

    private enum Context: Equatable {
        case single, double, substitution, paren, backtick
        /// `$((…))` or `((…))`; `arithmeticParen` is a `(` inside one.
        case arithmetic, arithmeticParen
        /// `${…}` and `$[…]`: a `<<` inside is not a heredoc.
        case parameter, bracket
    }

    private struct Operator {
        let delimiter: String
        let stripsTabs: Bool
        var isData: Bool
        var writes: Bool
    }

    private static func scan(_ raw: String) -> (text: String, writesMarker: Bool)? {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = []
        var stack: [Context] = []
        // The text of the simple command being read at each command level:
        // the line itself, then each `$(`, `(` and backtick inside it.
        var commands = [""]
        var writesMarker = false
        var blanked = false
        var lineIndex = 0
        while lineIndex < lines.count {
            let line = Array(lines[lineIndex])
            output.append(lines[lineIndex])
            lineIndex += 1
            var operators: [Operator] = []
            // `>(sh)`, `<(…)`: a heredoc on this line may feed a program.
            var processSubstitution = false
            var index = 0
            func take(_ count: Int = 1) {
                commands[commands.count - 1] += String(line[index..<min(index + count, line.count)])
                index += count
            }
            while index < line.count {
                let character = line[index]
                let next: Character? = index + 1 < line.count ? line[index + 1] : nil
                let third: Character? = index + 2 < line.count ? line[index + 2] : nil
                switch stack.last {
                case .single:
                    if character == "'" { stack.removeLast() }
                    take()
                    continue
                case .double:
                    if character == "\\" {
                        take(2)
                    } else if character == "\"" {
                        stack.removeLast()
                        take()
                    } else if character == "$", next == "(" {
                        if third == "(" {
                            stack.append(.arithmetic)
                            index += 3
                        } else {
                            stack.append(.substitution)
                            commands.append("")
                            index += 2
                        }
                    } else if character == "$", next == "{" || next == "[" {
                        stack.append(next == "{" ? .parameter : .bracket)
                        index += 2
                    } else if character == "`" {
                        stack.append(.backtick)
                        commands.append("")
                        index += 1
                    } else {
                        take()
                    }
                    continue
                case .arithmetic, .arithmeticParen:
                    if character == "(" {
                        stack.append(.arithmeticParen)
                        index += 1
                    } else if character == ")", stack.last == .arithmeticParen {
                        stack.removeLast()
                        index += 1
                    } else if character == ")" {
                        // `))` closes; a lone `)` is not shell rv can follow.
                        guard next == ")" else { return nil }
                        stack.removeLast()
                        index += 2
                    } else {
                        index += 1
                    }
                    continue
                case .bracket:
                    if character == "[" {
                        stack.append(.bracket)
                    } else if character == "]" {
                        stack.removeLast()
                    }
                    index += 1
                    continue
                case .parameter:
                    if character == "\\" {
                        index += 2
                    } else if character == "'" {
                        stack.append(.single)
                        index += 1
                    } else if character == "\"" {
                        stack.append(.double)
                        index += 1
                    } else if character == "$", next == "{" || next == "[" {
                        stack.append(next == "{" ? .parameter : .bracket)
                        index += 2
                    } else if character == "$", next == "(" {
                        if third == "(" {
                            stack.append(.arithmetic)
                            index += 3
                        } else {
                            stack.append(.substitution)
                            commands.append("")
                            index += 2
                        }
                    } else if character == "`" {
                        stack.append(.backtick)
                        commands.append("")
                        index += 1
                    } else if character == "}" {
                        stack.removeLast()
                        index += 1
                    } else {
                        index += 1
                    }
                    continue
                case nil, .substitution, .paren, .backtick:
                    break
                }
                switch character {
                case "\\":
                    take(2)
                case "'":
                    stack.append(.single)
                    take()
                case "\"":
                    stack.append(.double)
                    take()
                case "$" where next == "(":
                    if third == "(" {
                        stack.append(.arithmetic)
                        index += 3
                    } else {
                        stack.append(.substitution)
                        commands.append("")
                        index += 2
                    }
                case "$" where next == "{" || next == "[":
                    stack.append(next == "{" ? .parameter : .bracket)
                    take(2)
                case "`":
                    if stack.last == .backtick {
                        stack.removeLast()
                        commands.removeLast()
                    } else {
                        stack.append(.backtick)
                        commands.append("")
                    }
                    index += 1
                case "(":
                    if next == "(" {
                        stack.append(.arithmetic)
                        index += 2
                    } else {
                        stack.append(.paren)
                        commands.append("")
                        index += 1
                    }
                case ")":
                    guard let last = stack.last, last == .substitution || last == .paren else { return nil }
                    stack.removeLast()
                    commands.removeLast()
                    index += 1
                case ";", "&", "|":
                    // `cat <<EOF | sh`: the body feeds another program.
                    if character == "|" {
                        for slot in operators.indices { operators[slot].isData = false }
                    }
                    commands[commands.count - 1] = ""
                    index += 1
                case "<" where next == "<":
                    if third == "<" {
                        take(3)
                        continue
                    }
                    index += 2
                    guard var found = readOperator(line, from: &index, command: commands, stack: stack) else {
                        return nil
                    }
                    if processSubstitution { found.isData = false }
                    operators.append(found)
                    commands[commands.count - 1] += " <<" + found.delimiter + " "
                case ">", "<":
                    if next == "(" {
                        processSubstitution = true
                        for slot in operators.indices { operators[slot].isData = false }
                    }
                    if character == ">" {
                        for slot in operators.indices { operators[slot].writes = true }
                    }
                    take()
                default:
                    take()
                }
            }
            guard operators.isEmpty == false else {
                if stack.last == nil || stack.last == .substitution || stack.last == .paren {
                    commands[commands.count - 1] = ""
                }
                continue
            }
            // The body starts at a newline the shell reads as one.
            guard line.last != "\\", stack.allSatisfy({ $0 == .double || $0 == .substitution || $0 == .paren }),
                  stack.last != .double
            else { return nil }
            for heredoc in operators {
                var closed = false
                while lineIndex < lines.count {
                    let body = lines[lineIndex]
                    lineIndex += 1
                    let check = heredoc.stripsTabs ? String(body.drop { $0 == "\t" }) : body
                    if check == heredoc.delimiter {
                        output.append(body)
                        closed = true
                        break
                    }
                    if heredoc.isData {
                        if heredoc.writes, SecretsScanGuard.plainText(body).contains(SecretsScanGuard.allowMarker) {
                            writesMarker = true
                        }
                        output.append("")
                        blanked = true
                    } else {
                        output.append(body)
                    }
                }
                guard closed else { return nil }
            }
            commands[commands.count - 1] = ""
        }
        return (blanked ? output.joined(separator: "\n") : raw, writesMarker)
    }

    /// The heredoc after a `<<` at `index`: its delimiter, and whether its
    /// body is data. Data is a body `cat` or `tee` reads at the top level,
    /// or a `cat` in a `$(…)` that is a `git commit`/`tag`/`notes`
    /// message's value (`-m "$(cat <<'EOF'`).
    private static func readOperator(
        _ line: [Character], from index: inout Int, command: [String], stack: [Context]
    ) -> Operator? {
        var stripsTabs = false
        if index < line.count, line[index] == "-" {
            stripsTabs = true
            index += 1
        }
        while index < line.count, line[index] == " " || line[index] == "\t" { index += 1 }
        var delimiter = ""
        while index < line.count {
            let character = line[index]
            if character == "'" || character == "\"" {
                guard let close = line[(index + 1)...].firstIndex(of: character) else { return nil }
                delimiter += String(line[(index + 1)..<close])
                index = close + 1
                continue
            }
            if character == "\\" {
                if index + 1 < line.count { delimiter.append(line[index + 1]) }
                index += 2
                continue
            }
            if " \t;&|()<>".contains(character) { break }
            delimiter.append(character)
            index += 1
        }
        guard delimiter.isEmpty == false else { return nil }
        let current = command[command.count - 1]
        let head = commandHead(current)
        let isData: Bool
        if current.contains("#") {
            // A comment may hide where the command starts.
            isData = false
        } else if stack.isEmpty {
            isData = head == "cat" || head == "tee"
        } else if command.count == 2, stack == [.substitution] || stack == [.double, .substitution] {
            isData = head == "cat" && isMessageValue(command[0])
        } else {
            isData = false
        }
        return Operator(delimiter: delimiter, stripsTabs: stripsTabs, isData: isData, writes: head == "tee" || current.contains(">"))
    }

    private static func commandHead(_ text: String) -> String? {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
            .first { isAssignmentWord($0) == false }
            .map(commandName)
    }

    /// `git commit -m "`, `git tag -a v1 --message=`, `gh pr create --body
    /// "`: the text before a `$(` that is a message option's value.
    private static func isMessageValue(_ outer: String) -> Bool {
        let words = outer.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { $0.filter { $0 != "\"" && $0 != "'" } }
            .filter { $0.isEmpty == false }
        guard let head = words.first(where: { isAssignmentWord($0) == false }), let option = words.last else {
            return false
        }
        if commandName(head) == "gh" {
            return words.contains(where: { ["pr", "issue", "release"].contains($0) })
                && ["--body", "--body=", "-b", "--title", "--title=", "-t", "--notes", "--notes=", "-n"].contains(option)
        }
        guard commandName(head) == "git", words.contains(where: { ["commit", "tag", "notes"].contains($0) }) else {
            return false
        }
        if ["--message", "--message=", "-m"].contains(option) { return true }
        return option.hasPrefix("-") && option.hasPrefix("--") == false && option.hasSuffix("m")
            && option.dropFirst().allSatisfy(\.isLetter)
    }
}
