/// C1 pipeline facade (T4 seam): one entry over the typed stage chain.
 ///
 /// `ShellPipeline.parse` runs `tokenize() -> peel() -> unwrap() -> parse() ->
 /// classify()` and returns every stage output in a single `ParsedCommand`.
 /// `Normalize` and `CommandPeelCore` are thin adapters over it; their public
 /// signatures and the `MatchingView` bytes are unchanged.
 ///
 /// The public entry stays total because legacy behavior never throws. The
 /// genuinely fallible seams surface as `PipelineStageError` on the internal
 /// stages (`Result`) and are recorded on `ParsedCommand.error`.
import Foundation
import RVDomain

/// Typed failure for one `ShellPipeline` stage.
public enum PipelineStageError: Error, Sendable, Equatable {
    /// Parse stage: no command words, so no `Argv` segment exists.
    case emptyCommand
    /// Unwrap stage: the depth/bytes budget was exhausted; the associated
    /// layers are the wrappers peeled before the cutoff. Fail-closed.
    case unwrapLimited(layers: [WrapperKind])
}

/// One parsed shell command: every stage output in a single value.
public struct ParsedCommand: Sendable, Equatable {
    /// Stage 1 output: lexical tokens with quoting/ANSI-C provenance.
    public var tokens: [ShellPipeline.Token]
    /// Stage 2 output: trimmed input with non-executing heredoc bodies masked.
    public var peeled: String
    /// Stage 3 output: recursive extract; `nil` when budget-limited.
    public var unwrapped: UnwrappedCommand?
    /// Stage 4 output: one typed `Argv` per newline-delimited segment.
    /// Built from the raw stage-1 tokens, so non-executing heredoc body
    /// lines surface as segments; `matching` is the heredoc-masked view.
    public var segments: [Argv]
    /// Stage 5 output: role-aware grant key.
    public var matching: MatchingView
    /// First stage error encountered, if any. `parse` stays total; the
    /// remaining fields still carry their legacy-compatible values.
    public var error: PipelineStageError?

    /// Facade-produced values only: `ShellPipeline.parse` is the single
    /// producer. Public so tests and future producers can spell goldens
    /// without reflection.
    public init(
        tokens: [ShellPipeline.Token],
        peeled: String,
        unwrapped: UnwrappedCommand?,
        segments: [Argv],
        matching: MatchingView,
        error: PipelineStageError?
    ) {
        self.tokens = tokens
        self.peeled = peeled
        self.unwrapped = unwrapped
        self.segments = segments
        self.matching = matching
        self.error = error
    }
}

extension ParsedCommand {
    /// Innermost executing command; `nil` when unwrap hit its budget.
    public var executing: ExecutingCommand? {
        unwrapped?.executing
    }

    /// Wrappers peeled to reach `executing` (partial when limited).
    public var layers: [WrapperKind] {
        if let unwrapped {
            return unwrapped.layers
        }
        if case .unwrapLimited(let layers) = error {
            return layers
        }
        return []
    }
}

extension ShellPipeline {
    /// Single entry: tokenize -> peel -> unwrap -> parse -> classify.
    public static func parse(_ input: String) -> ParsedCommand {
        let tokens = tokenize(input)
        let peeled = peelStage(input)
        let unwrapped = unwrapStage(input)
        let segments = parseStage(tokens)
        let matching = classifyStage(peeled)
        // Unwrap failure implies a non-newline token, hence a segment, so
        // `.emptyCommand` can only fire when unwrap succeeded; the order is
        // defensive, never a real choice.
        let error: PipelineStageError? =
            if case .failure(let stageError) = unwrapped {
                stageError
            } else if case .failure(let stageError) = segments {
                stageError
            } else {
                nil
            }
        return ParsedCommand(
            tokens: tokens,
            peeled: peeled,
            unwrapped: try? unwrapped.get(),
            segments: (try? segments.get()) ?? [],
            matching: matching,
            error: error
        )
    }

    /// Single entry over `ShellCommand`, matching the sibling seams
    /// (`Normalize.matchingView(of:)`, `CommandPeelCore.peel`,
    /// `unwrapCommand`) so callers stop spelling `.rawValue`.
    public static func parse(_ command: ShellCommand) -> ParsedCommand {
        parse(command.rawValue)
    }

    /// Matching-only fast path: peel -> classify without unwrap/parse.
    ///
    /// Byte-identical to `parse(input).matching`: `classifyStage` reads
    /// only the peeled text, so matching-only callers skip the unwrap
    /// recursion and `Argv` segment build the pre-T4 `matchingView` never
    /// paid for.
    static func matchingView(of input: String) -> MatchingView {
        classifyStage(peelStage(input))
    }

    /// Stage 2: trim, then mask non-executing heredoc bodies. Total: without
    /// a heredoc the text passes through unchanged.
    static func peelStage(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ""
        }
        return maskNonExecutingHeredocBodies(trimmed)
    }

    /// Stage 3: recursive wrapper/interpreter extract. Fails typed when the
    /// depth/bytes budget is exhausted.
    static func unwrapStage(_ input: String) -> Result<UnwrappedCommand, PipelineStageError> {
        switch unwrapCommand(ShellCommand(rawValue: input)) {
        case .complete(let inner):
            return .success(inner)
        case .limited(let layers):
            return .failure(.unwrapLimited(layers: layers))
        }
    }

    /// Stage 4: one `Argv` per newline-delimited token segment. Fails typed
    /// when no command words exist. Built from raw (unpeeled) tokens, so
    /// non-executing heredoc body lines surface as segments.
    static func parseStage(_ tokens: [ShellPipeline.Token]) -> Result<[Argv], PipelineStageError> {
        var segments: [Argv] = []
        var current: [ShellPipeline.Token] = []
        for token in tokens {
            if token.isNewline {
                if let argv = Argv(tokens: current) {
                    segments.append(argv)
                }
                current = []
            } else {
                current.append(token)
            }
        }
        if let argv = Argv(tokens: current) {
            segments.append(argv)
        }
        guard segments.isEmpty == false else {
            return .failure(.emptyCommand)
        }
        return .success(segments)
    }

    /// Drops stream-leading `NAME=value` prefixes from raw text before masking.
    /// Post-masking text has lost the quoting boundary (`NAME="a b"` becomes
    /// separate words) and the lexer's `wasQuoted` is whole-token, so only a
    /// raw scan can tell `NAME="v"` (assignment) from `"N=v"` (command name).
    /// Stops at the first non-assignment, quoted-name, empty-name, or
    /// array-like value (`NAME=(`). Substitution-carrying values rewrite to
    /// `VALUE ; TAIL` (both execute; the segmenter evaluates both) instead of
    /// stopping: stopping hid the tail behind an inert prefix. Per-segment
    /// prefixes use this same function via `singleEffectiveSegment` and the
    /// `parse*Segments` loops (with a resplit, since the rewrite inserts
    /// a separator).
    static func stripLeadingAssignmentPrefixes(_ peeled: String) -> String {
        var rest = peeled[...]
        while let after = dropOneAssignmentPrefix(rest) {
            rest = after
        }
        return String(rest)
    }

    /// Strips leading `NAME=value` prefixes from EVERY top-level piece, not
    /// just the stream head. This must run here — on raw text where quoting
    /// boundaries survive — because the tokenizer decodes `FOO='a b'` to the
    /// unquoted lexeme `FOO=a b`, after which a text strip misreads the
    /// prefix as `FOO=a` and hides the real command from the typed parsers
    /// (`true && FOO='a b' git push` concealed a push). Gaps rejoin
    /// byte-for-byte, so pack patterns anchored on separators observe the
    /// same operators and blank runs as before.
    static func stripAssignmentPrefixesAllSegments(_ peeled: String) -> String {
        mapTopLevelPieces(peeled, transform: stripLeadingAssignmentPrefixes)
    }

    /// Drops one leading `NAME=value` / `NAME+=value` word plus trailing
    /// blanks, or rewrites it to `VALUE ; TAIL` when the value carries an
    /// executing substitution. Returns nil when `text` does not start with
    /// one. The tail recurses so `A=$(a) B=$(b) cmd` rewrites fully.
    static func dropOneAssignmentPrefix(_ text: Substring) -> Substring? {
        var index = text.startIndex
        guard index < text.endIndex, assignmentNameStart.contains(text[index]) else {
            return nil
        }
        repeat {
            text.formIndex(after: &index)
        } while index < text.endIndex && assignmentNameChars.contains(text[index])
        if index < text.endIndex, text[index] == "+" {
            text.formIndex(after: &index)
        }
        guard index < text.endIndex, text[index] == "=" else {
            return nil
        }
        text.formIndex(after: &index)
        guard let valueEnd = scanAssignmentValue(text, from: index) else {
            return nil
        }
        var rest = text[valueEnd...]
        while let first = rest.first, first == " " || first == "\t" {
            rest = rest.dropFirst()
        }
        let value = String(text[index..<valueEnd])
        if carriesSubstitution(value) {
            // The substitution executes AND the tail executes: rewrite to
            // `VALUE ; TAIL` so the segmenter evaluates both. Keeping the
            // prefix would hide the tail (`X=$(:) git push` concealed a
            // push); stripping it would hide the substitution. Quoting
            // re-derives downstream: single-quoted inners stay literal.
            return value + " ; " + stripLeadingAssignmentPrefixes(String(rest))
        }
        return rest
    }

    /// End index of an assignment value starting at `from`: quoted values run
    /// to their close quote, bare values to blank/operator/end. Balanced
    /// `$(...)`/backtick/`${...}` spans are part of the value (they also trip
    /// the substitution guard). Nil on unterminated quote or `(`-led value.
    static func scanAssignmentValue(_ text: Substring, from: Substring.Index) -> Substring.Index? {
        var index = from
        guard index < text.endIndex else {
            return index
        }
        if text[index] == "(" {
            return nil
        }
        if text[index] == "$",
            text.index(after: index) < text.endIndex,
            text[text.index(after: index)] == "'"
        {
            guard let after = scanSingleQuoted(text, from: text.index(after: text.index(after: index))) else {
                return nil
            }
            index = after
        } else if text[index] == "'" {
            guard let after = scanSingleQuoted(text, from: text.index(after: index)) else {
                return nil
            }
            index = after
        } else if text[index] == "\"" {
            guard let after = scanDoubleQuoted(text, from: text.index(after: index)) else {
                return nil
            }
            index = after
        }
        while index < text.endIndex {
            let char = text[index]
            if char == "\\" {
                text.formIndex(after: &index)
                if index < text.endIndex {
                    text.formIndex(after: &index)
                }
                continue
            }
            if char == "$", let after = scanDollarSpan(text, from: index) {
                index = after
                continue
            }
            if char == "`", let after = scanBacktick(text, from: index) {
                index = after
                continue
            }
            if char == " " || char == "\t" || char == "\n"
                || char == "&" || char == "|" || char == ";"
                || char == "(" || char == ")" || char == "<" || char == ">"
            {
                break
            }
            text.formIndex(after: &index)
        }
        return index
    }

    static func scanSingleQuoted(_ text: Substring, from: Substring.Index) -> Substring.Index? {
        var index = from
        while index < text.endIndex, text[index] != "'" {
            text.formIndex(after: &index)
        }
        guard index < text.endIndex else {
            return nil
        }
        return text.index(after: index)
    }

    static func scanDoubleQuoted(_ text: Substring, from: Substring.Index) -> Substring.Index? {
        var index = from
        while index < text.endIndex {
            if text[index] == "\\" {
                text.formIndex(after: &index)
                if index < text.endIndex {
                    text.formIndex(after: &index)
                }
                continue
            }
            if text[index] == "\"" {
                return text.index(after: index)
            }
            text.formIndex(after: &index)
        }
        return nil
    }

    /// End index past a `$(...)`, `$((...))`, or `${...}` span, or nil when
    /// `from` does not start one (a plain `$VAR` is the caller's bare scan).
    static func scanDollarSpan(_ text: Substring, from: Substring.Index) -> Substring.Index? {
        var index = text.index(after: from)
        guard index < text.endIndex else {
            return nil
        }
        let open = text[index]
        guard open == "(" || open == "{" else {
            return nil
        }
        let close: Character = open == "(" ? ")" : "}"
        var depth = 0
        while index < text.endIndex {
            if text[index] == open {
                depth += 1
            } else if text[index] == close {
                depth -= 1
                if depth == 0 {
                    return text.index(after: index)
                }
            }
            text.formIndex(after: &index)
        }
        return text.endIndex
    }

    static func scanBacktick(_ text: Substring, from: Substring.Index) -> Substring.Index? {
        var index = text.index(after: from)
        while index < text.endIndex, text[index] != "`" {
            text.formIndex(after: &index)
        }
        guard index < text.endIndex else {
            return text.endIndex
        }
        return text.index(after: index)
    }

    /// Stage 5: role-aware masking, then the outer-wrapper strip loop, then
    /// the argv0 path strip. Total.
    ///
    /// Mask-before-strip order is load-bearing: an ANSI-C argv0 such as
    /// `$'sudo'` only surfaces as a wrapper *after* masking, so the strip
    /// loop must run on the masked text, exactly as the legacy pipeline did.
    static func classifyStage(_ peeled: String) -> MatchingView {
        var current = applyRoleAwareQuotes(tokens: tokenize(stripAssignmentPrefixesAllSegments(peeled)))
        var iteration = 0
        while iteration < Normalize.maxWrapperIterations {
            iteration += 1
            if let stripped = stripSudo(current) {
                current = stripped
                continue
            }
            if let stripped = stripEnv(current) {
                current = stripped
                continue
            }
            if let stripped = stripCommandWrapper(current) {
                current = stripped
                continue
            }
            if let stripped = stripLeadingBackslash(current) {
                current = stripped
                continue
            }
            break
        }
        return MatchingView(stripAbsolutePathOnArgv0(current))
    }
}
