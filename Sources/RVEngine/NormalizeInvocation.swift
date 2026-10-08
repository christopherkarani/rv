import Foundation
import RVDomain

/// Invocation-prefix binding (B1 follow-up to M-07).
///
/// `classifyStage` erases the invocation prefix when it builds the matching
/// view: leading `NAME=value` assignments, `sudo`/`env`/`command` wrappers
/// (with their flags), a leading backslash, and the argv0 path. Masked
/// segments never record those pieces either, so a grant for `git push`
/// used to spend for `sudo git push`, `env LD_PRELOAD=x git push`,
/// `/evil/git push`, and `VAR=x git push` — different privilege and
/// execution semantics under one approval.
///
/// `invocationPrefix` records exactly what the view erases, in pipeline
/// order, projected from the single matching derivation
/// (`deriveMatching`): one loop strips and records atomically, so the
/// prefix cannot drift from the view — anything the view drops is
/// recorded here.
///
/// The pieces are raw command text and may carry secrets (environment
/// values, wrapper flags). Like masked segments, they must only be
/// digested — never stored, transmitted, or displayed verbatim. Human
/// display uses `invocationDisplay`, which keeps wrapper basenames,
/// assignment names, and the argv0 spelling but no values or flags.
extension ShellPipeline {
    /// Raw erased-prefix pieces in pipeline order: assignment spans, wrapper
    /// heads, then the pathed argv0 word when one was stripped. Empty for a
    /// bare command. In-process only: digest, never store or transmit.
    static func invocationPrefix(of input: String) -> [String] {
        typedInvocationPrefix(of: input).map(\.raw)
    }

    /// Display-safe tag for the erased prefix (`"sudo"`, `"FOO=… sudo"`),
    /// or nil for a bare command. Names and basenames only; no values.
    static func invocationDisplay(of input: String) -> String? {
        let tags = typedInvocationPrefix(of: input).compactMap { piece -> String? in
            switch piece {
            case .assignment(let name, _):
                return name.isEmpty ? nil : "\(name)=…"
            case .wrapper(let head):
                let base = basename(firstWord(head).word)
                return base.isEmpty ? nil : base
            case .argv0(let word):
                let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : String(trimmed.prefix(64))
            }
        }
        guard tags.isEmpty == false else { return nil }
        return tags.joined(separator: " ")
    }

    /// Typed erased-prefix pieces. The `raw` payload of every case is the
    /// exact erased span (trimmed of boundary blanks only); digests bind it.
    enum InvocationPiece: Sendable, Equatable {
        case assignment(name: String, raw: String)
        case wrapper(head: String)
        case argv0(word: String)

        var raw: String {
            switch self {
            case .assignment(_, let raw), .wrapper(let raw), .argv0(let raw):
                return raw
            }
        }
    }

    /// Typed erased-prefix pieces, projected from the single derivation
    /// pass so the recorded prefix always describes the returned view.
    static func typedInvocationPrefix(of input: String) -> [InvocationPiece] {
        deriveMatching(input).prefix
    }
}

extension Normalize {
    /// Raw erased-prefix pieces for grant binding. See `ShellPipeline`.
    public static func invocationPrefix(of command: String) -> [String] {
        ShellPipeline.invocationPrefix(of: command)
    }

    /// Raw erased-prefix pieces for grant binding. See `ShellPipeline`.
    public static func invocationPrefix(of command: ShellCommand) -> [String] {
        invocationPrefix(of: command.rawValue)
    }

    /// Display-safe erased-prefix tag, or nil for a bare command.
    public static func invocationDisplay(of command: String) -> String? {
        ShellPipeline.invocationDisplay(of: command)
    }

    /// Display-safe erased-prefix tag, or nil for a bare command.
    public static func invocationDisplay(of command: ShellCommand) -> String? {
        invocationDisplay(of: command.rawValue)
    }
}
