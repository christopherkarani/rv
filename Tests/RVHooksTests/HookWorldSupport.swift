import RVDomain
import RVHooks

/// Test-local HookEvaluateWorld. Omitted file port returns indeterminate
/// so encodeFileDeny emits `incompleteEvalSentence`.
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
