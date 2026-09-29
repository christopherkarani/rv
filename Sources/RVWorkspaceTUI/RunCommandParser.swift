import Foundation

public struct ParsedRuntimeCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public enum RunCommandParseError: Error, Equatable, Sendable {
    case empty
    case trailingEscape
    case unterminatedQuote
    case unsupportedShellSyntax(Character)
    case executableUnavailable

    /// Human-readable overlay text. The raw case name must never reach the
    /// screen: a mistyped path should read as a failure, not a token.
    public var message: String {
        switch self {
        case .empty: "Enter a command to run"
        case .trailingEscape: "Command ends with an unfinished escape"
        case .unterminatedQuote: "Unterminated quote"
        case .unsupportedShellSyntax(let character):
            "Shell syntax '\(character)' is not supported here; quote it or run an explicit shell"
        case .executableUnavailable: "Executable not found or not executable"
        }
    }
}

/// Tokenizes a command line without invoking a shell or expanding variables.
/// Shell operators outside quotes must be escaped or run through an explicit
/// shell executable, so a command that looks like a pipeline cannot silently
/// become unrelated literal arguments.
public enum RunCommandParser {
    private enum Quote {
        case none
        case single
        case double
    }

    public static func parse(_ line: String) -> Result<ParsedRuntimeCommand, RunCommandParseError> {
        var words: [String] = []
        var word = ""
        var started = false
        var escaping = false
        var quote = Quote.none

        for character in line {
            if escaping {
                word.append(character)
                started = true
                escaping = false
                continue
            }
            switch quote {
            case .none:
                if character == "\\" {
                    escaping = true
                    started = true
                } else if character == "'" {
                    quote = .single
                    started = true
                } else if character == "\"" {
                    quote = .double
                    started = true
                } else if character.isWhitespace {
                    if started {
                        words.append(word)
                        word = ""
                        started = false
                    }
                } else if "|;&<>`".contains(character) {
                    return .failure(.unsupportedShellSyntax(character))
                } else {
                    word.append(character)
                    started = true
                }
            case .single:
                if character == "'" {
                    quote = .none
                } else {
                    word.append(character)
                }
            case .double:
                if character == "\\" {
                    escaping = true
                } else if character == "\"" {
                    quote = .none
                } else {
                    word.append(character)
                }
            }
        }
        if escaping { return .failure(.trailingEscape) }
        if quote != .none { return .failure(.unterminatedQuote) }
        if started { words.append(word) }
        guard let executable = words.first, executable.isEmpty == false else { return .failure(.empty) }
        return .success(ParsedRuntimeCommand(executable: executable, arguments: Array(words.dropFirst())))
    }

    /// Checks executable availability without launching it. The host must
    /// revalidate the resolved absolute path before accepting a launch.
    public static func resolve(
        _ command: ParsedRuntimeCommand,
        path: String,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Result<ParsedRuntimeCommand, RunCommandParseError> {
        let name = command.executable
        guard name.isEmpty == false, name.contains("\0") == false else { return .failure(.executableUnavailable) }
        if name.hasPrefix("/") {
            guard isExecutable(name) else { return .failure(.executableUnavailable) }
            return .success(command)
        }
        guard name.contains("/") == false else { return .failure(.executableUnavailable) }
        for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
            guard directory.hasPrefix("/"), directory.contains("\0") == false else { continue }
            let candidate = String(directory) + "/" + name
            if isExecutable(candidate) {
                return .success(ParsedRuntimeCommand(executable: candidate, arguments: command.arguments))
            }
        }
        return .failure(.executableUnavailable)
    }
}
