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
    public var tokens: [Token]
    /// Stage 2 output: trimmed input with non-executing heredoc bodies masked.
    public var peeled: String
    /// Stage 3 output: recursive extract; `nil` when budget-limited.
    public var unwrapped: UnwrappedCommand?
    /// Stage 4 output: one typed `Argv` per newline-delimited segment.
    public var segments: [Argv]
    /// Stage 5 output: role-aware grant key.
    public var matching: MatchingView
    /// First stage error encountered, if any. `parse` stays total; the
    /// remaining fields still carry their legacy-compatible values.
    public var error: PipelineStageError?
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
    /// when no command words exist.
    static func parseStage(_ tokens: [Token]) -> Result<[Argv], PipelineStageError> {
        let segments = tokens.split { $0.isNewline }.compactMap { Argv(tokens: Array($0)) }
        guard segments.isEmpty == false else {
            return .failure(.emptyCommand)
        }
        return .success(segments)
    }

    /// Stage 5: role-aware masking, then the outer-wrapper strip loop, then
    /// the argv0 path strip. Total.
    ///
    /// Mask-before-strip order is load-bearing: an ANSI-C argv0 such as
    /// `$'sudo'` only surfaces as a wrapper *after* masking, so the strip
    /// loop must run on the masked text, exactly as the legacy pipeline did.
    static func classifyStage(_ peeled: String) -> MatchingView {
        var current = applyRoleAwareQuotes(tokens: tokenize(peeled))
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
