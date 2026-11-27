
/// `git config` arguments, options parsed the way git's parse-options does:
/// a long option by its unique prefix, `--opt=value` or `--opt value`, short
/// clusters with an attached or next-word value. An option rv does not know
/// sets `unknownOption`; the caller then fails closed.
struct GitConfigCall {
    enum Mode: Equatable {
        case read, set, unset, removeSection, renameSection, edit
    }

    let words: [String]
    private(set) var mode: Mode = .set
    /// Key, value and other operands, verb removed.
    private(set) var operands: [String] = []
    /// `--file`/`-f`.
    private(set) var file: String?
    private(set) var unknownOption = false
    /// `--global` or `--system`: every repository of the user or machine.
    private(set) var widensScope = false
    /// A read only because fewer than two operands are written (`git config
    /// KEY`): a dynamic operand may expand to a key and a value.
    private(set) var implicitRead = false

    private static let longFlags: [String] = [
        "--global", "--system", "--local", "--worktree", "--bool", "--int", "--bool-or-int", "--path",
        "--expiry-date", "--no-type", "--null", "--name-only", "--no-name-only", "--show-origin",
        "--no-show-origin", "--show-scope", "--no-show-scope", "--includes", "--no-includes", "--fixed-value",
        "--all", "--regexp", "--replace-all", "--add", "--append", "--no-value", "--get", "--get-all",
        "--get-regexp", "--get-urlmatch", "--get-color", "--get-colorbool", "--unset", "--unset-all",
        "--rename-section", "--remove-section", "--list", "--edit",
    ]
    private static let longValues: [String] = [
        "--file", "--blob", "--type", "--default", "--comment", "--value", "--url",
    ]
    private static let readFlags: Set<String> = [
        "--get", "--get-all", "--get-regexp", "--get-urlmatch", "--get-color", "--get-colorbool", "--list",
    ]
    private static let verbs: [String: Mode] = [
        "get": .read, "list": .read, "set": .set, "unset": .unset, "edit": .edit,
        "rename-section": .renameSection, "remove-section": .removeSection,
    ]

    init(_ args: [String]) {
        words = args
        var flags: Set<String> = []
        var positionals: [String] = []
        var index = 0
        var optionsEnded = false
        while index < args.count {
            let arg = args[index]
            index += 1
            if optionsEnded || arg == "-" || arg.hasPrefix("-") == false {
                positionals.append(arg)
                continue
            }
            if arg == "--" {
                optionsEnded = true
                continue
            }
            if arg.hasPrefix("--") {
                let name = String(arg.prefix { $0 != "=" })
                guard let option = Self.resolve(name) else {
                    unknownOption = true
                    continue
                }
                if Self.longValues.contains(option) {
                    var value: String?
                    if let eq = arg.firstIndex(of: "=") {
                        value = String(arg[arg.index(after: eq)...])
                    } else if index < args.count {
                        value = args[index]
                        index += 1
                    }
                    if option == "--file" { file = value }
                    if option == "--blob" { flags.insert("--blob") }
                } else {
                    flags.insert(option)
                }
                continue
            }
            // A short cluster: `-l`, `-e`, `-z`, `-f FILE`, `-tbool`.
            for (offset, letter) in arg.dropFirst().enumerated() {
                switch letter {
                case "l": flags.insert("--list")
                case "e": flags.insert("--edit")
                case "z": flags.insert("--null")
                case "f", "t":
                    let rest = String(arg.dropFirst(offset + 2))
                    var value: String? = rest.isEmpty ? nil : rest
                    if value == nil, index < args.count {
                        value = args[index]
                        index += 1
                    }
                    if letter == "f" { file = value }
                default:
                    unknownOption = true
                }
                if letter == "f" || letter == "t" { break }
            }
        }
        if let verb = positionals.first.map(foldedWord), let mode = Self.verbs[verb] {
            self.mode = mode
            positionals.removeFirst()
        } else if flags.contains("--edit") {
            mode = .edit
        } else if flags.isDisjoint(with: Self.readFlags) == false || flags.contains("--blob") {
            mode = .read
        } else if flags.contains("--unset") || flags.contains("--unset-all") {
            mode = .unset
        } else if flags.contains("--remove-section") {
            mode = .removeSection
        } else if flags.contains("--rename-section") {
            mode = .renameSection
        } else if positionals.count < 2 {
            // `git config KEY`: a read.
            mode = .read
            implicitRead = true
        }
        widensScope = flags.contains("--global") || flags.contains("--system")
        operands = positionals
    }

    /// The long option `name` names: exact, or its only prefix match.
    private static func resolve(_ name: String) -> String? {
        let all = longFlags + longValues
        if all.contains(name) { return name }
        let matches = all.filter { $0.hasPrefix(name) }
        return matches.count == 1 ? matches[0] : nil
    }
}
