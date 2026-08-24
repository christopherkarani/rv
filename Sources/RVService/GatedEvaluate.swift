import Foundation
import os
import RVDomain
import RVPolicy

/// Peek shows a matching grant without consuming it. Apply spends it.
public enum EvaluationIntent: Sendable, Equatable {
    case peek
    case apply
}

/// Runs the Evaluate session, then the Policy gate.
public struct GatedEvaluate: Sendable {
    public var corePacksReady: Bool { resolvedSession().corePacksReady }

    private enum Source: Sendable {
        case prepared(EvaluateSession)
        case deferred(
            build: @Sendable () -> EvaluateSession,
            slot: OSAllocatedUnfairLock<EvaluateSession?>
        )
    }

    private let source: Source

    /// Creates a door around an Evaluate session.
    public init(_ session: EvaluateSession = EvaluateSession()) {
        self.source = .prepared(session)
    }

    /// Creates a door that defers session construction until first use, then reuses it.
    package init(lazySession: @escaping @Sendable () -> EvaluateSession) {
        self.source = .deferred(
            build: lazySession,
            slot: OSAllocatedUnfairLock(initialState: nil)
        )
    }

    private func resolvedSession() -> EvaluateSession {
        switch source {
        case .prepared(let session):
            return session
        case .deferred(let build, let slot):
            return slot.withLock { stored in
                if let stored {
                    return stored
                }
                let built = build()
                stored = built
                return built
            }
        }
    }

    /// Builds `EvaluationRequest` and runs peek or apply.
    public func run(
        _ intent: EvaluationIntent,
        command: ShellCommand,
        cwd: String?,
        home: HomeDirectory? = nil,
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

    /// Walk set for peek/apply and the XPC wire request. Nil home is day-one walk.
    public static func makeRequest(
        command: ShellCommand,
        home: HomeDirectory? = nil
    ) -> EvaluationRequest {
        EvaluationRequest(
            command: command,
            enabledPacks: EnabledPacks.resolve(home: home).ids
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
        let result = resolvedSession().evaluate(request)
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
