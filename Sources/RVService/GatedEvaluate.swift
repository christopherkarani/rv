import Foundation
import RVDomain
import RVEngine
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
            slot: UnfairLock<EvaluateSession?>
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
            slot: UnfairLock(nil)
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
    ///
    /// `allowlist` is invoked only on deny (T13: allow/indeterminate skip allowlist I/O).
    public func run(
        _ intent: EvaluationIntent,
        command: ShellCommand,
        cwd: WorkingDirectory?,
        home: HomeDirectory? = nil,
        store: AllowOnceStore,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot
    ) async -> EvaluationResult {
        await gated(
            intent,
            Self.makeRequest(command: command, home: home),
            cwd: cwd,
            home: home,
            store: store,
            now: now,
            allowlist: allowlist
        )
    }

    /// Walk set for peek/apply and the XPC wire request. Nil home is day-one walk.
    public static func makeRequest(
        command: ShellCommand,
        home: HomeDirectory? = nil
    ) -> EvaluationRequest {
        EvaluationRequest(
            command: command,
            enabledPacks: EvaluationWorld.walkedPackIDs(home: home).ids
        )
    }

    /// Wire-path peek for an already-built request (ServiceRuntime explain/classify).
    /// CLI and in-process fallback must use `run(.peek, ...)` so pack resolution stays shared.
    func peek(
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory? = nil,
        store: AllowOnceStore,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot
    ) async -> EvaluationResult {
        await gated(
            .peek,
            request,
            cwd: cwd,
            home: home,
            store: store,
            now: now,
            allowlist: allowlist
        )
    }

    /// Host Ask spend: honor an existing grant, else plant+spend this turn. Fail-closed.
    public func spendHostAsk(
        command: ShellCommand,
        cwd: WorkingDirectory?,
        home: HomeDirectory? = nil,
        store: AllowOnceStore,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot
    ) async -> EvaluationResult {
        await spendHostAsk(
            Self.makeRequest(command: command, home: home),
            cwd: cwd,
            home: home,
            store: store,
            now: now,
            allowlist: allowlist
        )
    }

    func spendHostAsk(
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory? = nil,
        store: AllowOnceStore,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot
    ) async -> EvaluationResult {
        let result = evaluateWithSemantics(request, cwd: cwd, home: home)
        switch result.decision {
        case .allow, .indeterminate:
            return result
        case .deny:
            let snapshot = allowlist()
            let rebasing = GitRebaseProbe.rebaseInProgress(cwd: cwd)
            let applied = await PolicyGate.apply(
                result,
                cwd: cwd,
                allowlist: snapshot,
                store: store,
                now: now,
                rebaseInProgress: rebasing
            )
            if case .allow = applied.result.decision {
                return applied.result
            }
            return await PolicyGate.spendHostAllowOnce(
                result,
                cwd: cwd,
                allowlist: snapshot,
                store: store,
                now: now,
                rebaseInProgress: rebasing
            ).result
        }
    }

    /// Wire-path apply for an already-built request (ServiceRuntime evaluate).
    /// CLI and in-process fallback must use `run(.apply, ...)` so pack resolution stays shared.
    func apply(
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory? = nil,
        store: AllowOnceStore,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot
    ) async -> EvaluationResult {
        await gated(
            .apply,
            request,
            cwd: cwd,
            home: home,
            store: store,
            now: now,
            allowlist: allowlist
        )
    }

    private func gated(
        _ intent: EvaluationIntent,
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory?,
        store: AllowOnceStore,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot
    ) async -> EvaluationResult {
        let result = evaluateWithSemantics(request, cwd: cwd, home: home)
        // Fast path: allow/indeterminate never touch PolicyGate or the
        // allowlist loader; PolicyGate returns them unchanged anyway.
        switch result.decision {
        case .allow, .indeterminate:
            return result
        case .deny:
            let snapshot = allowlist()
            let rebasing = GitRebaseProbe.rebaseInProgress(cwd: cwd)
            switch intent {
            case .peek:
                return await PolicyGate.peek(
                    result,
                    cwd: cwd,
                    allowlist: snapshot,
                    store: store,
                    now: now,
                    rebaseInProgress: rebasing
                ).result
            case .apply:
                return await PolicyGate.apply(
                    result,
                    cwd: cwd,
                    allowlist: snapshot,
                    store: store,
                    now: now,
                    rebaseInProgress: rebasing
                ).result
            }
        }
    }

    private func evaluateWithSemantics(
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory? = nil
    ) -> EvaluationResult {
        let pack = resolvedSession().evaluate(request)
        let probe = wrapperProbe(command: request.command, cwd: cwd, home: home)
        return applySemantics(
            pack: pack,
            command: request.command,
            gitContext: GitAnalysisContext(workingDirectory: cwd),
            filesystemContext: probe,
            enabledPacks: request.enabledPacks
        )
    }

    /// After apply stayed deny. Not peek. Not Ask. Nil when the deny is not unlockable.
    /// Missing HOME has no durable store `rv allow-once` can redeem, so skip the code.
    public static func mintUnlockCode(
        for result: EvaluationResult,
        cwd: WorkingDirectory?,
        store: AllowOnceStore,
        now: Date,
        home: HomeDirectory?
    ) async -> String? {
        guard home != nil else { return nil }
        guard case .deny(let deny) = result.decision else { return nil }
        guard RulePinning.blocksAllowOverride(result) == false else { return nil }
        guard let cwd else { return nil }
        return await store.mintFromDeny(
            matchingView: result.matchingView,
            cwd: cwd,
            ruleID: deny.ruleID,
            now: now
        )
    }

    private func wrapperProbe(
        command: ShellCommand,
        cwd: WorkingDirectory?,
        home: HomeDirectory?
    ) -> FilesystemAnalysisContext {
        let unwrapped = unwrapCommand(command, workingDirectory: cwd)
        let probeCommand: ShellCommand
        let probeCwd: WorkingDirectory?
        switch unwrapped {
        case .complete(let extracted):
            probeCommand = extracted.command
            probeCwd = extracted.workingDirectory ?? cwd
        case .limited:
            probeCommand = command
            probeCwd = cwd
        }
        return FilesystemLiveProbe.context(
            command: probeCommand,
            cwd: probeCwd,
            homeDirectory: home?.rawValue
        )
    }
}
