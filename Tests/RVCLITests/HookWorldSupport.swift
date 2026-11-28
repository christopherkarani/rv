import RVDomain
import RVHooks

/// Test-local HookEvaluateWorld. Omitted file port returns indeterminate
/// so the file deny is the core-packs indeterminate stop.
func hookWorld(
    evaluate: @escaping @Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult,
    evaluateFile: (@Sendable (FileToolAction, WorkingDirectory?) async -> EvaluationResult)? = nil,
    mintOnDeny: (@Sendable (EvaluationResult, WorkingDirectory?) async -> AllowOnceUnlockMint?)? =
        nil,
    recordHostAsk: (@Sendable (HookRequest, ProposedAction) async throws -> Void)? = nil
) -> HookEvaluateWorld {
    let incomplete = EvaluationResult(outcome: .indeterminate(.corePacksUnavailable))
    return HookEvaluateWorld(
        evaluate: evaluate,
        evaluateFile: evaluateFile ?? { _, _ in incomplete },
        mintOnDeny: mintOnDeny ?? { _, _ in nil },
        recordHostAsk: recordHostAsk ?? { _, _ in }
    )
}

/// The ask stop for a plain-voice deny stop `text` with no code: the same
/// stop, except that on macOS a recorded ask names the RV app instead of
/// the owner's own terminal.
func askStop(_ text: String) -> String {
    #if os(macOS)
    text.replacingOccurrences(of: "who     \(ownTerminalLine())", with: "who     \(approveInRVLine())")
    #else
    text
    #endif
}

/// The `who` line of a stop text, without its label: what a host's
/// separate `next` field carries.
func stopWho(_ text: String) -> String? {
    text.split(separator: "\n").last.flatMap { line in
        line.hasPrefix("who     ") ? String(line.dropFirst("who     ".count)) : nil
    }
}
