import RVDomain

/// Required ports for a live hook door. Production and tests build one value.
///
/// Step 8B: no spend port. Human approval arrives via RVOperatorUI or TTY
/// allow-once; the agent retries and the retry consumes the planted grant
/// through the ordinary evaluate port.
public struct HookEvaluateWorld: Sendable {
    public var evaluate: @Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult
    public var evaluateFile: @Sendable (FileToolAction, WorkingDirectory?) async -> EvaluationResult
    public var mintOnDeny: @Sendable (EvaluationResult, WorkingDirectory?) async -> AllowOnceUnlockMint?
    public var recordHostAsk: @Sendable (HookRequest, ProposedAction) async throws -> Void

    public init(
        evaluate: @escaping @Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult,
        evaluateFile: @escaping @Sendable (FileToolAction, WorkingDirectory?) async -> EvaluationResult,
        mintOnDeny: @escaping @Sendable (EvaluationResult, WorkingDirectory?) async -> AllowOnceUnlockMint?,
        recordHostAsk: @escaping @Sendable (HookRequest, ProposedAction) async throws -> Void
    ) {
        self.evaluate = evaluate
        self.evaluateFile = evaluateFile
        self.mintOnDeny = mintOnDeny
        self.recordHostAsk = recordHostAsk
    }
}
