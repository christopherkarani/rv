import Foundation
import RVDomain
import RVPolicy

/// Peek shows a matching grant without consuming it. Apply spends it.
public enum EvaluationIntent: Sendable, Equatable {
    case peek
    case apply
}

/// Runs the Evaluate session, then the Policy gate.
public struct GatedEvaluate: Sendable {
    public var corePacksReady: Bool { session.corePacksReady }

    private let session: EvaluateSession

    /// Creates a door around an Evaluate session.
    public init(_ session: EvaluateSession = EvaluateSession()) {
        self.session = session
    }

    /// Builds `EvaluationRequest` and runs peek or apply.
    public func run(
        _ intent: EvaluationIntent,
        command: ShellCommand,
        cwd: String?,
        home: String? = nil,
        store: AllowOnceStore,
        now: Date
    ) async -> EvaluationResult {
        await gated(
            intent,
            Self.makeRequest(command: command, home: home),
            cwd: cwd,
            store: store,
            now: now
        )
    }

    /// HOME + effective pack IDs + day-one fallback. Shared by peek/apply and the XPC wire request.
    public static func makeRequest(
        command: ShellCommand,
        home: String? = nil
    ) -> EvaluationRequest {
        EvaluationRequest(
            command: command,
            enabledPacks: EnabledPacks.resolve(home: home ?? EnabledPacks.processHome())
        )
    }

    /// Wire-path peek for an already-built request (ServiceRuntime explain/classify).
    /// CLI and in-process fallback must use `run(.peek, ...)` so pack resolution stays shared.
    func peek(
        _ request: EvaluationRequest,
        cwd: String?,
        store: AllowOnceStore,
        now: Date
    ) async -> EvaluationResult {
        await gated(.peek, request, cwd: cwd, store: store, now: now)
    }

    /// Wire-path apply for an already-built request (ServiceRuntime evaluate).
    /// CLI and in-process fallback must use `run(.apply, ...)` so pack resolution stays shared.
    func apply(
        _ request: EvaluationRequest,
        cwd: String?,
        store: AllowOnceStore,
        now: Date
    ) async -> EvaluationResult {
        await gated(.apply, request, cwd: cwd, store: store, now: now)
    }

    private func gated(
        _ intent: EvaluationIntent,
        _ request: EvaluationRequest,
        cwd: String?,
        store: AllowOnceStore,
        now: Date
    ) async -> EvaluationResult {
        let result = session.evaluate(request)
        // Fast path: allow/indeterminate never touch PolicyGate or the
        // allowlist snapshot; PolicyGate returns them unchanged anyway.
        switch result.decision {
        case .allow, .indeterminate:
            return result
        case .deny:
            let allowlist = AllowlistStore(baseDirectory: store.baseDirectory)
                .loadUserSnapshot(workspacePath: cwd, now: now)
            switch intent {
            case .peek:
                return await PolicyGate.peek(
                    result,
                    cwd: cwd,
                    allowlist: allowlist,
                    store: store,
                    now: now
                ).result
            case .apply:
                return await PolicyGate.apply(
                    result,
                    cwd: cwd,
                    allowlist: allowlist,
                    store: store,
                    now: now
                ).result
            }
        }
    }
}
