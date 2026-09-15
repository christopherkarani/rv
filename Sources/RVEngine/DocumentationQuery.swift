/// `--help` / `--version` / `-h` / `-V` / `-?` after argv0, and nothing else.
/// Command-name walkers (`mkfs\s+`, `\bpvremove\b`) must not deny a docs query.
func isDocumentationQuery(_ view: String) -> Bool {
    let tokens = tokenizeCommand(view)
    guard let argv0 = tokens.first else { return false }
    let command = basename(argv0.decoded)
    guard command.isEmpty == false, command.hasPrefix("-") == false else { return false }

    var sawDoc = false
    for token in tokens.dropFirst() {
        let decoded = token.decoded
        if decoded == "&&" || decoded == "||" || decoded == ";" || decoded == "|" {
            return false
        }
        if documentationFlags.contains(decoded) {
            sawDoc = true
            continue
        }
        return false
    }
    return sawDoc
}

private let documentationFlags: Set<String> = [
    "--help", "-h", "--version", "-V", "-?",
]
