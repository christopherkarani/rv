/// `<interpreter> -I -S <adapter>`: how every Python hook command starts
/// its adapter. The interpreter is the absolute path setup probed, so the
/// host's PATH cannot swap it. `-I` ignores `PYTHON*` variables and keeps
/// the script directory and user site-packages off the import path; `-S`
/// skips `site`, so no `.pth` file runs code before the adapter. Adapters
/// import only the standard library. An empty stdout with exit 0 reads as
/// allow, so nothing the agent can plant may run first.
///
/// On macOS the command starts with `/usr/bin/env`: the Command Line
/// Tools' Python is not a hardened or platform binary, so `DYLD_*`
/// variables (a `~/.zshenv` export reaches the host's `zsh -c`) would load
/// a planted library into it. `/usr/bin/env` is SIP-protected, so dyld
/// strips `DYLD_*` when it starts, before it execs the interpreter.
enum AdapterCommand {
    static let isolationFlags = "-I -S"
    /// The interpreter rv's earlier hook commands ran from PATH.
    static let legacyInterpreter = "python3"
    /// The SIP-protected launcher macOS commands start with.
    static let envLauncher = "/usr/bin/env"

    #if os(macOS)
    static let launchesThroughEnv = true
    #else
    static let launchesThroughEnv = false
    #endif

    struct Parsed: Equatable {
        var interpreter: String
        var adapterPath: String
        /// The current form: isolation flags present.
        var isolated: Bool
        /// Started through `envLauncher`.
        var throughEnv: Bool = false
    }

    /// `env` reads any operand holding `=` as an assignment, quoted or
    /// not: an interpreter path with one would make it exec `-I`, which
    /// exits 127 and fails open. Setup never bakes such a path for the env
    /// form (`AdapterRuntime.resolveRunnable`).
    static func launchable(_ interpreter: String, throughEnv: Bool = launchesThroughEnv) -> Bool {
        throughEnv == false || interpreter.contains("=") == false
    }

    /// Callers pass an interpreter that is `launchable`.
    static func render(interpreter: String, adapterPath: String, throughEnv: Bool = launchesThroughEnv) -> String {
        let command = "\(ShellWord.quote(interpreter)) \(isolationFlags) \(ShellWord.quote(adapterPath))"
        return throughEnv ? "\(envLauncher) \(command)" : command
    }

    /// The form rv wrote before the interpreter was baked.
    static func renderLegacy(adapterPath: String) -> String {
        "\(legacyInterpreter) \(ShellWord.quote(adapterPath))"
    }

    /// The current form (any interpreter word, then the isolation flags),
    /// optionally after `/usr/bin/env `, or the earlier `python3 <adapter>`;
    /// nil for anything else. Callers check the words are absolute.
    static func parse(_ text: Substring) -> Parsed? {
        let launcher = envLauncher + " "
        if text.hasPrefix(launcher) {
            guard var parsed = parseIsolated(text.dropFirst(launcher.count)),
                  launchable(parsed.interpreter, throughEnv: true)
            else { return nil }
            parsed.throughEnv = true
            return parsed
        }
        if let parsed = parseIsolated(text) { return parsed }
        guard let interpreter = ShellWord.leadingWord(text),
              interpreter.word == legacyInterpreter, interpreter.rest.hasPrefix(" "),
              let adapter = ShellWord.leadingWord(interpreter.rest.dropFirst()),
              adapter.rest.isEmpty
        else { return nil }
        return Parsed(interpreter: legacyInterpreter, adapterPath: adapter.word, isolated: false)
    }

    private static func parseIsolated(_ text: Substring) -> Parsed? {
        guard let interpreter = ShellWord.leadingWord(text) else { return nil }
        let flags = " \(isolationFlags) "
        guard interpreter.rest.hasPrefix(flags),
              let adapter = ShellWord.leadingWord(interpreter.rest.dropFirst(flags.count)),
              adapter.rest.isEmpty
        else { return nil }
        return Parsed(interpreter: interpreter.word, adapterPath: adapter.word, isolated: true)
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

    /// The absolute interpreter a current command bakes, with or without
    /// the env launcher; nil for the earlier PATH form or anything unparsed.
    static func bakedInterpreter(in command: Substring) -> String? {
        guard let parsed = parse(command), parsed.isolated, parsed.interpreter.hasPrefix("/") else { return nil }
        return parsed.interpreter
    }
}
