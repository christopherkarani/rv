import RVDomain

/// Injected capabilities for Hook mapper dispatch. Evaluate is required; the
/// rest fail closed when missing — same as today's nil closures.
///
/// XPC (`ServiceRuntime`) and miss (`ServiceClient`) each bind their own.
/// This is not HookDoorPorts; miss does not go through HookDoor.
public struct HookWirePorts: Sendable {
    public let evaluate: @Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult
    public let evaluateFile:
        (@Sendable (FileToolAction, WorkingDirectory?) async -> EvaluationResult)?
    public let spendHostAsk:
        (@Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult)?
    public let mintOnDeny:
        (@Sendable (EvaluationResult, WorkingDirectory?) async -> String?)?
    public let recordHostAsk:
        (@Sendable (HookRequest, ProposedAction) async throws -> Void)?
    public let clearHostAsk:
        (@Sendable (HookRequest, ProposedAction) async throws -> Void)?

    public init(
        evaluate: @escaping @Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult,
        evaluateFile: (@Sendable (FileToolAction, WorkingDirectory?) async -> EvaluationResult)? =
            nil,
        spendHostAsk: (@Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult)? = nil,
        mintOnDeny: (@Sendable (EvaluationResult, WorkingDirectory?) async -> String?)? = nil,
        recordHostAsk: (@Sendable (HookRequest, ProposedAction) async throws -> Void)? = nil,
        clearHostAsk: (@Sendable (HookRequest, ProposedAction) async throws -> Void)? = nil
    ) {
        self.evaluate = evaluate
        self.evaluateFile = evaluateFile
        self.spendHostAsk = spendHostAsk
        self.mintOnDeny = mintOnDeny
        self.recordHostAsk = recordHostAsk
        self.clearHostAsk = clearHostAsk
    }
}
