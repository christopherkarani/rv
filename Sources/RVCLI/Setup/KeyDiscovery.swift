import Foundation

/// A key value rv found. It never prints: `description`, `debugDescription`
/// and `dump` all show a fixed mask, so a value cannot reach output, a log
/// or a test failure message by interpolation. Only `bytes` reads it, and
/// only the store step does.
struct FoundKeyValue: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let bytes: Data

    init(_ text: String) {
        bytes = Data(text.utf8)
    }

    init(bytes: Data) {
        self.bytes = bytes
    }

    var description: String { "‹hidden›" }
    var debugDescription: String { "‹hidden›" }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Where rv saw a key. Names a place, never the value.
enum KeySighting: Sendable, Equatable, Hashable {
    /// `export NAME=…` in a shell startup file, by its display path (`~/.zshrc`).
    case shellFile(path: String, line: Int)
    /// The environment `rv setup` runs in, which agents started here inherit.
    case environment
    /// A tool's own login file (`gh`, `vercel`).
    case login(String)

    var label: String {
        switch self {
        case .shellFile(let path, let line): "\(path):\(line)"
        case .environment: "environment"
        case .login(let tool): "\(tool) login"
        }
    }
}

/// One shell startup file's text, by the path a person reads.
struct ShellStartupFile: Sendable, Equatable {
    var displayPath: String
    var contents: String
}

/// Everything the scan reads, already loaded: the scan itself touches no
/// disk and no process state.
struct KeyScanInput: Sendable {
    var shellFiles: [ShellStartupFile] = []
    var environment: [String: String] = [:]
    /// `hosts.yml` of the GitHub CLI, when it stores its token in the file.
    var ghHosts: String?
    /// The Vercel CLI's `auth.json`.
    var vercelAuth: Data?
}

/// A key name rv found, every place it was seen, and the value it would
/// keep. `value` is nil when every sighting builds the value at run time
/// (`export X=$(…)`) and the environment does not hold it.
struct FoundKey: Sendable, Equatable {
    var name: String
    var sightings: [KeySighting]
    var value: FoundKeyValue?
}

/// Finds the well-known keys agents can read today. Pure: a function of
/// the loaded files and the environment.
enum KeyScan {
    /// The names rv looks for: the ones it can keep with no flags, because
    /// it knows where each may be sent (`KnownSecretDefaults.names`).
    static func find(_ input: KeyScanInput, names: Set<String>) -> [FoundKey] {
        var order: [String] = []
        var sightings: [String: [KeySighting]] = [:]
        var fileValue: [String: FoundKeyValue] = [:]
        var loginValue: [String: FoundKeyValue] = [:]

        func see(_ name: String, _ sighting: KeySighting) {
            if sightings[name] == nil { order.append(name) }
            sightings[name, default: []].append(sighting)
        }

        for file in input.shellFiles {
            for export in exports(in: file.contents) where names.contains(export.name) {
                see(export.name, .shellFile(path: file.displayPath, line: export.line))
                // A later literal line wins, as it does when the shell runs the file.
                if let literal = export.literal { fileValue[export.name] = FoundKeyValue(literal) }
            }
        }
        for name in names.sorted() {
            guard let value = input.environment[name], isRealValue(value) else { continue }
            see(name, .environment)
        }
        if names.contains(githubName), let token = input.ghHosts.flatMap(ghToken) {
            see(githubName, .login("gh"))
            loginValue[githubName] = FoundKeyValue(token)
        }
        if names.contains(vercelName), let token = input.vercelAuth.flatMap(LoginRun.vercelAuthToken),
            isRealValue(String(decoding: token, as: UTF8.self))
        {
            see(vercelName, .login("vercel"))
            loginValue[vercelName] = FoundKeyValue(bytes: token)
        }

        return order.map { name in
            // What agents get right now comes first: the environment, then
            // the shell files that will set it in the next shell, then a login.
            let environment = input.environment[name].flatMap { isRealValue($0) ? FoundKeyValue($0) : nil }
            return FoundKey(
                name: name, sightings: sightings[name] ?? [],
                value: environment ?? fileValue[name] ?? loginValue[name])
        }
    }

    static let githubName = "GITHUB_TOKEN"
    static let vercelName = "VERCEL_TOKEN"

    /// A value worth keeping: long enough to be a key, one word, and not an
    /// rv stand-in (inside an rv-run shell the variable holds `…rvph_…`).
    static func isRealValue(_ value: String) -> Bool {
        value.count >= 8 && value.count <= 16_384 && value.contains("rvph_") == false
            && value.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value != 0x7F }
    }

    /// One `export NAME=…` line. `literal` is the value when the line spells
    /// it out; nil when the shell builds it (`$VAR`, `$(…)`, backticks).
    struct Export: Sendable, Equatable {
        var name: String
        var line: Int
        var literal: String?
    }

    /// The `export NAME=VALUE` lines of a POSIX shell file, 1-based. Only
    /// the plain forms: `export NAME=value`, `"value"`, `'value'`, with an
    /// optional trailing `;` or `# comment`. Anything else is skipped, not guessed.
    static func exports(in contents: String) -> [Export] {
        var found: [Export] = []
        for (index, raw) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var line = Substring(raw).drop { $0 == " " || $0 == "\t" }
            guard line.hasPrefix("export"), let next = line.dropFirst(6).first, next == " " || next == "\t" else {
                continue
            }
            line = line.dropFirst(6).drop { $0 == " " || $0 == "\t" }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<equals])
            guard isVariableName(name) else { continue }
            guard let value = assignedValue(line[line.index(after: equals)...]) else { continue }
            found.append(Export(name: name, line: index + 1, literal: value.literal))
        }
        return found
    }

    private struct AssignedValue {
        var literal: String?
    }

    /// The value after `=`, or nil when the line is not one plain assignment.
    private static func assignedValue(_ text: Substring) -> AssignedValue? {
        guard let first = text.first else { return nil }
        // `$(op read …)`, `$VAR`, a backtick: the shell builds it. Still an
        // export of the name, but there is no value on disk to read.
        if first == "$" || first == "`" { return AssignedValue(literal: nil) }
        let body: Substring
        let rest: Substring
        var literal = true
        switch first {
        case "'":
            guard let close = text.dropFirst().firstIndex(of: "'") else { return nil }
            body = text[text.index(after: text.startIndex)..<close]
            rest = text[text.index(after: close)...]
        case "\"":
            guard let close = text.dropFirst().firstIndex(of: "\"") else { return nil }
            body = text[text.index(after: text.startIndex)..<close]
            rest = text[text.index(after: close)...]
            literal = body.contains { $0 == "$" || $0 == "`" || $0 == "\\" } == false
        default:
            let end = text.firstIndex { $0 == " " || $0 == "\t" || $0 == ";" || $0 == "#" } ?? text.endIndex
            body = text[..<end]
            rest = text[end...]
            literal = body.contains { $0 == "$" || $0 == "`" || $0 == "\\" || $0 == "\"" || $0 == "'" } == false
        }
        let tail = rest.drop { $0 == " " || $0 == "\t" }
        guard tail.isEmpty || tail.hasPrefix("#") || tail.hasPrefix(";") else { return nil }
        guard literal, isRealValue(String(body)) else { return AssignedValue(literal: nil) }
        return AssignedValue(literal: String(body))
    }

    private static func isVariableName(_ name: String) -> Bool {
        guard let first = name.utf8.first, first == UInt8(ascii: "_") || (65...90).contains(first) || (97...122).contains(first)
        else { return false }
        return name.utf8.allSatisfy { $0 == UInt8(ascii: "_") || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
    }

    /// The `oauth_token` under `github.com:` in the GitHub CLI's
    /// `hosts.yml`. A gh that keeps its token in the system keyring writes
    /// none, and then nothing is found.
    static func ghToken(_ hosts: String) -> String? {
        var inGitHub = false
        for raw in hosts.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.first.map({ $0 != " " && $0 != "\t" }) == true {
                inGitHub = line.trimmingCharacters(in: .whitespaces) == "github.com:"
                continue
            }
            guard inGitHub else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("oauth_token:") else { continue }
            var value = trimmed.dropFirst("oauth_token:".count).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            return isRealValue(value) ? value : nil
        }
        return nil
    }
}
