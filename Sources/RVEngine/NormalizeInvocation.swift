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
/// order, by mirroring `classifyStage` strip-for-strip on the same peeled
/// text (assignments per top-level piece, then the wrapper loop on the
/// masked text, then the argv0 path split). It shares every primitive with
/// the strips (`parseAssignmentPrefix`, the `strip*` family), so the two
/// cannot drift: anything the view drops is recorded here.
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

    static func typedInvocationPrefix(of input: String) -> [InvocationPiece] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }
        // Same input `classifyStage` strips: heredoc bodies are already
        // masked (space-filled) and never affect first-word stripping.
        let peeled = peelStage(input)
        var pieces: [InvocationPiece] = []
        let stripped = mapTopLevelPieces(peeled) { piece in
            recordAssignmentPrefixes(in: piece, into: &pieces)
            return stripLeadingAssignmentPrefixes(piece)
        }
        // Same masked text the wrapper loop strips: an ANSI-C argv0 such as
        // `$'sudo'` only surfaces as a wrapper after masking.
        var current = applyRoleAwareQuotes(tokens: tokenize(stripped))
        var iteration = 0
        while iteration < Normalize.maxWrapperIterations {
            iteration += 1
            if let next = stripRecording(current, with: stripSudo) {
                pieces.append(.wrapper(head: next.head))
                current = next.rest
                continue
            }
            if let next = stripRecording(current, with: stripEnv) {
                pieces.append(.wrapper(head: next.head))
                current = next.rest
                continue
            }
            if let next = stripRecording(current, with: stripCommandWrapper) {
                pieces.append(.wrapper(head: next.head))
                current = next.rest
                continue
            }
            if let next = stripRecording(current, with: stripLeadingBackslash) {
                pieces.append(.wrapper(head: next.head))
                current = next.rest
                continue
            }
            break
        }
        let (word, _) = firstWord(current)
        if looksLikeAbsoluteExecutable(word) {
            pieces.append(.argv0(word: word))
        }
        return pieces
    }

    /// Records every leading assignment span `stripLeadingAssignmentPrefixes`
    /// erases or rewrites, using the same `parseAssignmentPrefix` detector,
    /// in order. Substitution values stay in the view (`VALUE ; TAIL`) but
    /// the `NAME=` carrier is erased, so the whole raw span binds.
    private static func recordAssignmentPrefixes(
        in piece: String,
        into pieces: inout [InvocationPiece]
    ) {
        var rest = piece[...]
        while let parsed = parseAssignmentPrefix(rest) {
            let raw = String(rest[..<parsed.rest.startIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty == false {
                pieces.append(.assignment(name: assignmentDisplayName(raw), raw: raw))
            }
            rest = parsed.rest
        }
    }

    /// The assignment target name without value or subscript: `FOO` for
    /// `FOO=bar`, `A` for `A[0]=x` and `A+=y`. Display only; the digest
    /// binds the raw span.
    private static func assignmentDisplayName(_ raw: String) -> String {
        var name = raw[...]
        if let eq = name.firstIndex(of: "=") {
            name = name[..<eq]
        }
        if let bracket = name.firstIndex(of: "[") {
            name = name[..<bracket]
        }
        if name.hasSuffix("+") {
            name = name.dropLast()
        }
        return String(name)
    }

    /// Runs one wrapper strip and splits the input into erased head plus
    /// remainder. Every strip returns a true suffix of its input (boundary
    /// blanks stay in the head), so a non-suffix result means no strip.
    private static func stripRecording(
        _ text: String,
        with strip: (String) -> String?
    ) -> (head: String, rest: String)? {
        guard let rest = strip(text),
            rest != text,
            text.hasSuffix(rest)
        else {
            return nil
        }
        let head = String(text.dropLast(rest.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.isEmpty == false else {
            return nil
        }
        return (head, rest)
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
