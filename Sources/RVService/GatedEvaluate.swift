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
        let resolvedHome = home
            ?? ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? ""
        let enabled = (try? PacksFacade.effectiveIDs(home: resolvedHome)) ?? dayOnePackIDs
        return EvaluationRequest(command: command, enabledPacks: enabled)
    }

    /// Shows a matching grant / allowlist without spending it.
    public func peek(
        _ request: EvaluationRequest,
        cwd: String?,
        store: AllowOnceStore,
        now: Date
    ) async -> EvaluationResult {
        await gated(.peek, request, cwd: cwd, store: store, now: now)
    }

    /// Spends a matching grant after an engine deny; honor user allowlist first.
    public func apply(
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
