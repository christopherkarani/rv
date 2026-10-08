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

    /// Matching-only fast path: one derivation pass without unwrap/parse.
    ///
    /// Byte-identical to `parse(input).matching`: the derivation reads
    /// only the peeled text, so matching-only callers skip the unwrap
    /// recursion and `Argv` segment build the pre-T4 `matchingView` never
    /// paid for.
    static func matchingView(of input: String) -> MatchingView {
        deriveMatching(input).view
    }

    /// Exact lexemes masking replaced while producing `matchingView(of:)`,
    /// in pipeline order (heredoc body first, then token order). M-07:
    /// mint and spend both digest these so a grant for one hidden payload
    /// cannot authorize another. Projected from the single derivation
    /// pass, so the segments always describe the returned view: wrapper
    /// strips and the argv0 path strip normalize but never mask, so they
    /// contribute no segments. In-process only: segments may carry
    /// secrets and must never be stored or transmitted, only digested.
    static func maskedSegments(of input: String) -> [String] {
        deriveMatching(input).masked
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

    /// Drops stream-leading `NAME=value` prefixes (plus `NAME[sub]=`,
    /// `NAME+=(...)`, and array compounds) from raw text before masking.
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
        guard let parsed = parseAssignmentPrefix(text) else {
            return nil
        }
        if carriesSubstitution(parsed.value) {
            // The substitution executes AND the tail executes: rewrite to
            // `VALUE ; TAIL` so the segmenter evaluates both. Keeping the
            // prefix would hide the tail (`X=$(:) git push` concealed a
            // push); stripping it would hide the substitution. Quoting
            // re-derives downstream: single-quoted inners stay literal.
            return parsed.value + " ; " + stripLeadingAssignmentPrefixes(String(parsed.rest))
        }
        return parsed.rest
    }

    /// One parsed leading assignment prefix: the raw value plus the text
    /// after the prefix and its trailing blanks. Array/subscript forms count:
    /// `A=(1) git push` and `A[0]=x git push` both execute the tail, so both
    /// must strip (M-01); leaving them glued hid the verb from dispatch.
    /// Shared by the string rewriter (`dropOneAssignmentPrefix`) and the
    /// provenance split (`splitAssignmentPrefixValues`) so both agree on
    /// what a prefix is.
    static func parseAssignmentPrefix(_ text: Substring) -> (value: String, rest: Substring)? {
        var index = text.startIndex
        guard index < text.endIndex, assignmentNameStart.contains(text[index]) else {
            return nil
        }
        repeat {
            text.formIndex(after: &index)
        } while index < text.endIndex && assignmentNameChars.contains(text[index])
        if index < text.endIndex, text[index] == "[" {
            guard let after = scanBalanced(text, from: index, open: "[", close: "]") else {
                return nil
            }
            index = after
        }
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
        return (String(text[index..<valueEnd]), rest)
    }

    /// Splits leading assignment prefixes into their substitution-carrying
    /// values plus the executing tail. `A=$(a) B=1 cmd` yields values
    /// [`$(a)`] and tail `cmd`: rejoining as `values ; tail` equals
    /// `stripLeadingAssignmentPrefixes`, but the analyze layer needs the
    /// provenance — a VALUE is not a command, so its own segment must not
    /// fail closed as a dynamic verb (M-24); only its inners evaluate.
    static func splitAssignmentPrefixValues(_ piece: String) -> (values: [String], tail: String) {
        var values: [String] = []
        var rest = piece[...]
        while let parsed = parseAssignmentPrefix(rest) {
            if carriesSubstitution(parsed.value) {
                values.append(parsed.value)
            }
            rest = parsed.rest
        }
        return (values, String(rest))
    }

    /// Substitution-carrying assignment values across every top-level piece
    /// of peeled text, in order. The analyze layer threads these alongside
    /// the matched view as an exemption budget: matching rewrites values to
    /// `VALUE ; TAIL`, so a bare `$(...)` segment is textually identical
    /// whether it was a VALUE or a typed standalone — only the budget tells
    /// them apart. Projected from the single derivation pass, so the
    /// budget always describes the returned view.
    static func collectTopLevelAssignmentValues(_ peeled: String) -> [String] {
        deriveMatching(peeled: peeled).assignmentValues
    }

    /// End index of an assignment value starting at `from`: quoted values run
    /// to their close quote, bare values to blank/operator/end. Balanced
    /// `$(...)`/backtick/`${...}` spans are part of the value (they also trip
    /// the substitution guard). `(`-led array compounds scan balanced, so
    /// `A=(1 2) cmd` strips (M-01). Nil on unterminated quote/compound.
    static func scanAssignmentValue(_ text: Substring, from: Substring.Index) -> Substring.Index? {
        var index = from
        guard index < text.endIndex else {
            return index
        }
        if text[index] == "(" {
            guard let after = scanBalanced(text, from: index, open: "(", close: ")") else {
                return nil
            }
            index = after
        } else if text[index] == "$",
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

    /// End index past a balanced `open...close` span starting at `from`
    /// (array compounds, assignment subscripts), or nil when `from` does not
    /// start one or it never closes. Quote- and backslash-aware; spans nest.
    /// An unterminated span is a shell syntax error (nothing executes), so
    /// nil — declining the strip — is the sound answer there.
    static func scanBalanced(
        _ text: Substring,
        from: Substring.Index,
        open: Character,
        close: Character
    ) -> Substring.Index? {
        var index = from
        guard index < text.endIndex, text[index] == open else {
            return nil
        }
        var depth = 0
        var quote: Character?
        while index < text.endIndex {
            let char = text[index]
            if let current = quote {
                if char == current {
                    quote = nil
                } else if current == "\"", char == "\\" {
                    text.formIndex(after: &index)
                    if index < text.endIndex {
                        text.formIndex(after: &index)
                    }
                    continue
                }
            } else if char == "'" || char == "\"" {
                quote = char
            } else if char == "\\" {
                text.formIndex(after: &index)
                if index < text.endIndex {
                    text.formIndex(after: &index)
                }
                continue
            } else if char == open {
                depth += 1
            } else if char == close {
                depth -= 1
                if depth == 0 {
                    return text.index(after: index)
                }
            }
            text.formIndex(after: &index)
        }
        return nil
    }

    /// Stage 5: the classified view, projected from the single derivation
    /// pass. Total.
    static func classifyStage(_ peeled: String) -> MatchingView {
        deriveMatching(peeled: peeled).view
    }

    /// One matching-derivation pass: classified view plus side-channels in
    /// a single result. This is the only place that defines the derivation
    /// order (trim, heredoc mask, per-piece assignment strip, role-aware
    /// mask, wrapper loop, argv0 strip) and the strip set (`sudo`, `env`,
    /// `command`, backslash). Depth: callers project one field without
    /// re-spelling the sequence; locality: strip-order bugs land here, once.
    struct MatchingDerivation: Sendable, Equatable {
        /// Stage-5 classified view: the role-aware grant key.
        let view: MatchingView
        /// Exact lexemes masking replaced, pipeline order (heredoc body
        /// first, then token order). In-process only: digest, never store.
        let masked: [String]
        /// Typed erased-prefix pieces in pipeline order. In-process only:
        /// digest, never store or transmit.
        let prefix: [InvocationPiece]
        /// Substitution-carrying assignment values: the analyze layer's
        /// exemption budget.
        let assignmentValues: [String]
    }

    /// Derives the matching bundle for raw input in one pass.
    static func deriveMatching(_ input: String) -> MatchingDerivation {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return MatchingDerivation(view: MatchingView(""), masked: [], prefix: [], assignmentValues: [])
        }
        let (peeled, heredoc) = maskNonExecutingHeredocBodiesDetailed(trimmed)
        return deriveMatching(peeled: peeled, heredocMasked: heredoc)
    }

    /// Derives the matching bundle for already-peeled text (trimmed,
    /// heredoc-masked). `heredocMasked` carries the masked body lexemes when
    /// the caller peeled with the detailed mask; the view never needs them.
    ///
    /// Mask-before-strip order is load-bearing: an ANSI-C argv0 such as
    /// `$'sudo'` only surfaces as a wrapper *after* masking, so the strip
    /// loop runs on the masked text, exactly as the legacy pipeline did.
    static func deriveMatching(peeled: String, heredocMasked: [String] = []) -> MatchingDerivation {
        var prefix: [InvocationPiece] = []
        var assignmentValues: [String] = []
        let stripped = mapTopLevelPieces(peeled) { piece in
            let part = stripAssignmentPiece(piece)
            prefix.append(contentsOf: part.assignments.map {
                InvocationPiece.assignment(name: $0.name, raw: $0.raw)
            })
            assignmentValues.append(contentsOf: part.values)
            return part.stripped
        }
        let (maskedView, quoteMasked) = applyRoleAwareQuotesDetailed(tokens: tokenize(stripped))
        var current = maskedView
        var iteration = 0
        while iteration < Normalize.maxWrapperIterations {
            iteration += 1
            if let next = stripPrefixStep(current, with: stripSudo) {
                if let head = next.head {
                    prefix.append(.wrapper(head: head))
                }
                current = next.rest
                continue
            }
            if let next = stripPrefixStep(current, with: stripEnv) {
                if let head = next.head {
                    prefix.append(.wrapper(head: head))
                }
                current = next.rest
                continue
            }
            if let next = stripPrefixStep(current, with: stripCommandWrapper) {
                if let head = next.head {
                    prefix.append(.wrapper(head: head))
                }
                current = next.rest
                continue
            }
            if let next = stripPrefixStep(current, with: stripLeadingBackslash) {
                if let head = next.head {
                    prefix.append(.wrapper(head: head))
                }
                current = next.rest
                continue
            }
            break
        }
        let (word, _) = firstWord(current)
        if looksLikeAbsoluteExecutable(word) {
            prefix.append(.argv0(word: word))
        }
        return MatchingDerivation(
            view: MatchingView(stripAbsolutePathOnArgv0(current)),
            masked: heredocMasked + quoteMasked,
            prefix: prefix,
            assignmentValues: assignmentValues
        )
    }

    /// Strips leading `NAME=value` prefixes from one top-level piece and
    /// records what the strip observed: the raw erased spans (erased-prefix
    /// binding) plus the substitution-carrying values (analyze exemption
    /// budget). The stripped text comes from the canonical
    /// `stripLeadingAssignmentPrefixes` — its fixpoint re-scan of rewritten
    /// values is observable in the view — while the recorder observes each
    /// original leading prefix once via the shared `parseAssignmentPrefix`
    /// primitive, exactly as the legacy split/record loops did.
    private static func stripAssignmentPiece(_ piece: String) -> (
        stripped: String,
        assignments: [(name: String, raw: String)],
        values: [String]
    ) {
        var assignments: [(name: String, raw: String)] = []
        var values: [String] = []
        var rest = piece[...]
        while let parsed = parseAssignmentPrefix(rest) {
            let raw = String(rest[..<parsed.rest.startIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty == false {
                assignments.append((assignmentDisplayName(raw), raw))
            }
            if carriesSubstitution(parsed.value) {
                values.append(parsed.value)
            }
            rest = parsed.rest
        }
        return (stripLeadingAssignmentPrefixes(piece), assignments, values)
    }

    /// Runs one wrapper strip: the view advances whenever the strip fires,
    /// and the erased head is recorded alongside it, atomically. One loop
    /// strips and records, so the prefix cannot drift from the view.
    private static func stripPrefixStep(
        _ text: String,
        with strip: (String) -> String?
    ) -> (head: String?, rest: String)? {
        guard let rest = strip(text) else {
            return nil
        }
        return (erasedHead(of: text, keeping: rest), rest)
    }

    /// The span a wrapper strip erased: the input minus the kept remainder,
    /// trimmed of boundary blanks. The split runs on boundary-trimmed text
    /// because masking pads a trailing masked lexeme with spaces, which
    /// would otherwise unalign the suffix split exactly when the tail is
    /// masked (and the strip would go unrecorded while the view strips it).
    /// Nil when the split does not align or the head is empty; the view
    /// still advances, exactly as the legacy strip loop did.
    private static func erasedHead(of text: String, keeping rest: String) -> String? {
        let core = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard core.hasSuffix(rest) else {
            return nil
        }
        let head = String(core.dropLast(rest.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.isEmpty == false else {
            return nil
        }
        return head
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
}
