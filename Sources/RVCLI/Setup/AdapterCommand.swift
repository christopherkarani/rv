/// `<interpreter> -I -S <adapter>`: how every Python hook command starts
/// its adapter. The interpreter is the absolute path setup probed, so the
/// host's PATH cannot swap it. `-I` ignores `PYTHON*` variables and keeps
/// the script directory and user site-packages off the import path; `-S`
/// skips `site`, so no `.pth` file runs code before the adapter. Adapters
/// import only the standard library. An empty stdout with exit 0 reads as
/// allow, so nothing the agent can plant may run first.
enum AdapterCommand {
    static let isolationFlags = "-I -S"
    /// The interpreter rv's earlier hook commands ran from PATH.
    static let legacyInterpreter = "python3"

    struct Parsed: Equatable {
        var interpreter: String
        var adapterPath: String
        /// The current form: isolation flags present.
        var isolated: Bool
    }

    static func render(interpreter: String, adapterPath: String) -> String {
        "\(ShellWord.quote(interpreter)) \(isolationFlags) \(ShellWord.quote(adapterPath))"
    }

    /// The form rv wrote before the interpreter was baked.
    static func renderLegacy(adapterPath: String) -> String {
        "\(legacyInterpreter) \(ShellWord.quote(adapterPath))"
    }

    /// The current form (any interpreter word, then the isolation flags) or
    /// the earlier `python3 <adapter>`; nil for anything else. Callers check
    /// the words are absolute.
    static func parse(_ text: Substring) -> Parsed? {
        guard let interpreter = ShellWord.leadingWord(text) else { return nil }
        let flags = " \(isolationFlags) "
        if interpreter.rest.hasPrefix(flags),
           let adapter = ShellWord.leadingWord(interpreter.rest.dropFirst(flags.count)),
           adapter.rest.isEmpty
        {
            return Parsed(interpreter: interpreter.word, adapterPath: adapter.word, isolated: true)
        }
        guard interpreter.word == legacyInterpreter, interpreter.rest.hasPrefix(" "),
              let adapter = ShellWord.leadingWord(interpreter.rest.dropFirst()),
              adapter.rest.isEmpty
        else { return nil }
        return Parsed(interpreter: legacyInterpreter, adapterPath: adapter.word, isolated: false)
    }

    /// The adapter path of a current or earlier command, absolute only.
    /// rv's oldest commands left a path with a space unquoted.
    static func adapterPath(in command: String) -> String? {
        if let parsed = parse(Substring(command)) {
            return parsed.adapterPath.hasPrefix("/") ? parsed.adapterPath : nil
        }
        let prefix = legacyInterpreter + " "
        guard command.hasPrefix(prefix) else { return nil }
        let path = String(command.dropFirst(prefix.count))
        return path.hasPrefix("/") ? path : nil
    }

    /// The absolute interpreter a current command bakes; nil for the
    /// earlier PATH form or anything unparsed.
    static func bakedInterpreter(in command: Substring) -> String? {
        guard let parsed = parse(command), parsed.isolated, parsed.interpreter.hasPrefix("/") else { return nil }
        return parsed.interpreter
    }
}
