/// C1 single recursive unwrap (T2 seam).
///
/// One recursive unwrap over `Argv` with one `UnwrapBudget` value type. This
/// seam consolidates the former `Unwrap*.swift` implementations (prefix
/// wrappers, SSH, executing sinks, shells, interpreters) behind a single
/// `ShellPipeline.unwrap` recursion and a single `peel` dispatch keyed on
/// `argv.program`. Tokens carry quoting/ANSI-C provenance parallel to the argv
/// words; handlers consume tokens while dispatch keys on Argv.
///
/// Behavior is identical to the pre-T2 pipeline: same peel outcomes, same
/// budget cutoffs, same fail-closed `.limited` cases. `Normalize`,
/// `unwrapCommand`, and `CommandPeel` keep their signatures and delegate here.
///
/// Handlers live in sibling files by concern: `Unwrap+PrefixWrappers.swift`
/// (sudo/env/command/timeout/nice/mise/ssh), `Unwrap+Interpreters.swift`
/// (`sh -c` shells and python/node/ruby programs), `Unwrap+Sinks.swift`
/// (executing pipe/heredoc sinks), and `Unwrap+TextScan.swift` (top-level
/// pipe and heredoc splitting).
import Foundation
import RVDomain

// MARK: - Budget

/// Single depth/bytes policy for recursive unwrap.
///
/// One value type replaces the scattered depth/bytes pairs. Defaults match
/// the pre-T2 `UnwrapLimits` caps.
public struct UnwrapBudget: Sendable, Equatable, Hashable {
    /// Maximum wrapper layers peeled before `.limited`. Must be `>= 0`.
    public var maxDepth: Int
    /// Maximum UTF-8 byte count of one peel layer's inner command. Must be `>= 0`.
    public var maxBytes: Int

    /// Creates a budget. Both caps must be non-negative.
    public init(maxDepth: Int = 8, maxBytes: Int = 4_096) {
        precondition(maxDepth >= 0, "maxDepth must be non-negative")
        precondition(maxBytes >= 0, "maxBytes must be non-negative")
        self.maxDepth = maxDepth
        self.maxBytes = maxBytes
    }

    public static let `default` = UnwrapBudget()
}

// MARK: - Public unwrap vocabulary (pre-T2 API, unchanged signatures)

/// Hard caps for recursive wrapper / interpreter extraction.
///
/// Single source of truth is `UnwrapBudget`; this enum preserves the pre-T2
/// public spelling used by analyzer defaults and the corpus gate.
public enum UnwrapLimits: Sendable {
    public static let maxDepth: Int = UnwrapBudget.default.maxDepth
    public static let maxBytes: Int = UnwrapBudget.default.maxBytes
}

/// Inner command plus the wrappers peeled to reach it.
public struct UnwrappedCommand: Sendable, Equatable {
    public var command: ShellCommand
    public var layers: [WrapperKind]
    public var workingDirectory: WorkingDirectory?

    public init(
        command: ShellCommand,
        layers: [WrapperKind] = [],
        workingDirectory: WorkingDirectory? = nil
    ) {
        self.command = command
        self.layers = layers
        self.workingDirectory = workingDirectory
    }

    public var executing: ExecutingCommand {
        ExecutingCommand(rawValue: command.rawValue)
    }
}

/// Result of bounded unwrap. `.limited` is fail-closed, never an allow hint.
public enum UnwrapOutcome: Sendable, Equatable {
    case complete(UnwrappedCommand)
    case limited(layers: [WrapperKind])
}

/// Pure recursive extract. Does not evaluate policy.
///
/// Thin adapter over the single `ShellPipeline.unwrap` recursion; the
/// signature is unchanged from pre-T2.
public func unwrapCommand(
    _ command: ShellCommand,
    workingDirectory: WorkingDirectory? = nil,
    maxDepth: Int = UnwrapLimits.maxDepth,
    maxBytes: Int = UnwrapLimits.maxBytes
) -> UnwrapOutcome {
    unwrapCommand(
        command,
        workingDirectory: workingDirectory,
        budget: UnwrapBudget(maxDepth: maxDepth, maxBytes: maxBytes)
    )
}

/// Budget spelling of `unwrapCommand(_:workingDirectory:maxDepth:maxBytes:)`.
public func unwrapCommand(
    _ command: ShellCommand,
    workingDirectory: WorkingDirectory? = nil,
    budget: UnwrapBudget
) -> UnwrapOutcome {
    ShellPipeline.unwrap(
        command.rawValue,
        workingDirectory: workingDirectory,
        budget: budget,
        depth: 0,
        layers: []
    )
}

// MARK: - Single recursive unwrap

extension ShellPipeline {
    /// Pure recursive extract over `Argv`. Does not evaluate policy.
    static func unwrap(
        _ text: String,
        workingDirectory: WorkingDirectory?,
        budget: UnwrapBudget,
        depth: Int,
        layers: [WrapperKind],
        splitChains: Bool = true
    ) -> UnwrapOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .complete(
                UnwrappedCommand(
                    command: ShellCommand(rawValue: trimmed),
                    layers: layers,
                    workingDirectory: workingDirectory
                )
            )
        }
        if trimmed.hasPrefix("\\") {
            if let stripped = stripLeadingBackslash(trimmed), stripped != trimmed {
                return unwrap(
                    stripped,
                    workingDirectory: workingDirectory,
                    budget: budget,
                    depth: depth,
                    layers: layers
                )
            }
        }

        // Text-level sink check first: on pipes/heredocs this skips a
        // full-text tokenize that the sink path would discard.
        if let sink = peelExecutingSink(trimmed, workingDirectory: workingDirectory) {
            return applyPeel(
                sink,
                fallback: trimmed,
                workingDirectory: workingDirectory,
                budget: budget,
                depth: depth,
                layers: layers
            )
        }
        if splitChains,
            let chained = unwrapChain(
                trimmed,
                workingDirectory: workingDirectory,
                budget: budget,
                depth: depth,
                layers: layers
            )
        {
            return chained
        }
        let tokens = ShellPipeline.tokenize(trimmed)
        let argv = Argv(tokens: tokens)
        return applyPeel(
            peelAfterSink(tokens: tokens, argv: argv, workingDirectory: workingDirectory),
            fallback: trimmed,
            workingDirectory: workingDirectory,
            budget: budget,
            depth: depth,
            layers: layers
        )
    }

    /// Applies one peel step: completes, limits, or recurses on `.next`.
    private static func applyPeel(
        _ peel: Peel,
        fallback: String,
        workingDirectory: WorkingDirectory?,
        budget: UnwrapBudget,
        depth: Int,
        layers: [WrapperKind]
    ) -> UnwrapOutcome {
        switch peel {
        case .notWrapper:
            return .complete(
                UnwrappedCommand(
                    command: ShellCommand(rawValue: fallback),
                    layers: layers,
                    workingDirectory: workingDirectory
                )
            )
        case .limited(let kind):
            return .limited(layers: layers + [kind])
        case .next(let inner, let kind, let nextCwd):
            if inner.utf8.count > budget.maxBytes {
                return .limited(layers: layers + [kind])
            }
            if depth + 1 > budget.maxDepth {
                return .limited(layers: layers + [kind])
            }
            return unwrap(
                inner,
                workingDirectory: nextCwd,
                budget: budget,
                depth: depth + 1,
                layers: layers + [kind]
            )
        }
    }

    /// Single wrapper dispatch keyed on `argv.program`.
    ///
    /// The executing-sink check runs first on raw text (pipes/heredocs are
    /// text-level structure); every other wrapper dispatches on the argv head
    /// with per-token quoting provenance from `tokens`.
    static func peel(
        text: String,
        tokens: [ShellPipeline.Token],
        argv: Argv?,
        workingDirectory: WorkingDirectory?
    ) -> Peel {
        if let sink = peelExecutingSink(text, workingDirectory: workingDirectory) {
            return sink
        }
        return peelAfterSink(tokens: tokens, argv: argv, workingDirectory: workingDirectory)
    }

    /// Wrapper dispatch keyed on `argv.program`, after the sink check.
    ///
    /// `Argv` already filters structural newlines, so a `nil` argv is the
    /// only no-dispatch case; `unwrap` trims before tokenizing, so a leading
    /// newline never reaches dispatch through the recursion.
    static func peelAfterSink(
        tokens: [ShellPipeline.Token],
        argv: Argv?,
        workingDirectory: WorkingDirectory?
    ) -> Peel {
        guard let argv else {
            return .notWrapper
        }
        let head = unescapeBackslashPairs(basename(argv.program)).lowercased()
        if head == "timeout" {
            return peelTimeout(tokens, workingDirectory: workingDirectory)
        }
        if head == "nice" {
            return peelNice(tokens, workingDirectory: workingDirectory)
        }
        if head == "mise" {
            return peelMise(tokens, workingDirectory: workingDirectory)
        }
        if head == "ssh" {
            return peelSSH(tokens, workingDirectory: workingDirectory)
        }
        if head == "sudo" {
            return peelSudo(tokens, workingDirectory: workingDirectory)
        }
        if head == "env" {
            return peelEnv(tokens, workingDirectory: workingDirectory)
        }
        if head == "command" {
            return peelCommandWrapper(tokens, workingDirectory: workingDirectory)
        }
        if let kind = shellKind(head) {
            return peelShell(tokens, kind: kind, workingDirectory: workingDirectory)
        }
        if isPythonExecutable(head) {
            return peelInterpreter(
                tokens,
                kind: .python,
                flags: pythonEvalFlags,
                extract: extractPython,
                workingDirectory: workingDirectory
            )
        }
        if isNodeExecutable(head) {
            return peelInterpreter(
                tokens,
                kind: .node,
                flags: nodeEvalFlags,
                extract: extractNode,
                workingDirectory: workingDirectory
            )
        }
        if isRubyExecutable(head) {
            return peelInterpreter(
                tokens,
                kind: .ruby,
                flags: rubyEvalFlags,
                extract: extractRuby,
                workingDirectory: workingDirectory
            )
        }
        if let peel = peelUtility(head, tokens: tokens, workingDirectory: workingDirectory) {
            return peel
        }
        return .notWrapper
    }
}

// MARK: - Peel result

enum Peel: Sendable, Equatable {
    case notWrapper
    case limited(WrapperKind)
    case next(String, WrapperKind, WorkingDirectory?)
}

// MARK: - Interpreter eval flags (read by `peelAfterSink`)

private let pythonEvalFlags: Set<String> = ["-c"]
private let nodeEvalFlags: Set<String> = ["-e", "--eval", "-p", "--print"]
private let rubyEvalFlags: Set<String> = ["-e"]

// MARK: - Shared peel helpers

func attachedOptionValue(_ token: String, long: String) -> String? {
    let prefix = long + "="
    guard token.hasPrefix(prefix) else { return nil }
    let value = String(token.dropFirst(prefix.count))
    return value.isEmpty ? nil : value
}

func renderCommand(_ tokens: [ShellPipeline.Token]) -> String {
    tokens.map(renderToken).joined(separator: " ")
}

private func renderToken(_ token: ShellPipeline.Token) -> String {
    if token.wasQuoted || token.lexeme.contains(where: { $0.isWhitespace }) {
        return "'" + token.lexeme.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    return token.lexeme
}
