import RVDomain

/// Required ports for a live hook door. Production builds one value;
/// tests may still call the seven-argument `hookWire` adapter.
public struct HookEvaluateWorld: Sendable {
    public var evaluate: @Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult
    public var evaluateFile: @Sendable (FileToolAction, WorkingDirectory?) async -> EvaluationResult
    public var spend: @Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult
    public var mintOnDeny: @Sendable (EvaluationResult, WorkingDirectory?) async -> String?
    public var recordHostAsk: @Sendable (HookRequest, ProposedAction) async throws -> Void
    public var clearHostAsk: @Sendable (HookRequest, ProposedAction) async throws -> Void

    public init(
        evaluate: @escaping @Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult,
        evaluateFile: @escaping @Sendable (FileToolAction, WorkingDirectory?) async -> EvaluationResult,
        spend: @escaping @Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult,
        mintOnDeny: @escaping @Sendable (EvaluationResult, WorkingDirectory?) async -> String?,
        recordHostAsk: @escaping @Sendable (HookRequest, ProposedAction) async throws -> Void,
        clearHostAsk: @escaping @Sendable (HookRequest, ProposedAction) async throws -> Void
    ) {
        self.evaluate = evaluate
        self.evaluateFile = evaluateFile
        self.spend = spend
        self.mintOnDeny = mintOnDeny
        self.recordHostAsk = recordHostAsk
        self.clearHostAsk = clearHostAsk
    }
}
