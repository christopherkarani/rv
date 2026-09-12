import Foundation
import RVDomain
import RVEngine
import RVHistory
import RVPolicy

/// Peek shows a matching grant without consuming it. Apply spends it.
public enum EvaluationIntent: Sendable, Equatable {
    case peek
    case apply
}

/// Policy-gate verb after the Evaluate session. Host Ask spend is apply, then
/// plant-and-spend this turn — not a third EvaluationIntent.
private enum PolicyVerb: Sendable {
    case peek
    case apply
    case hostAskSpend

    var recordsDenial: Bool {
        switch self {
        case .peek:
            false
        case .apply, .hostAskSpend:
            true
        }
    }
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

    /// Catalog-only file-tool door. Packs and Policy gate never see the path.
    public func runFile(
        _ action: FileToolAction,
        home: HomeDirectory? = nil,
        cwd: WorkingDirectory? = nil,
        host: String = "tty",
        now: Date = Date()
    ) -> EvaluationResult {
        let allowPaths = SecretAllowPaths.loadEffective(
            home: home,
            workspace: Self.workspaceURL(cwd: cwd)
        )
        let result = evaluateFileTool(
            action,
            allowPaths: allowPaths,
            home: home?.rawValue
        )
        recordDenialIfNeeded(
            result,
            path: action.path.rawValue,
            home: home,
            host: host,
            tool: action.kind.ledgerName,
            now: now
        )
        return result
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
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        host: String = "tty",
        tool: String = "Bash"
    ) async -> EvaluationResult {
        await gated(
            Self.policyVerb(intent),
            Self.makeRequest(command: command, home: home),
            cwd: cwd,
            home: home,
            store: store,
            now: now,
            allowlist: allowlist,
            host: host,
            tool: tool
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
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        host: String = "tty",
        tool: String = "Bash"
    ) async -> EvaluationResult {
        await gated(
            PolicyVerb.peek,
            request,
            cwd: cwd,
            home: home,
            store: store,
            now: now,
            allowlist: allowlist,
            host: host,
            tool: tool
        )
    }

    /// Host Ask spend: honor an existing grant, else plant+spend this turn. Fail-closed.
    public func spendHostAsk(
        command: ShellCommand,
        cwd: WorkingDirectory?,
        home: HomeDirectory? = nil,
        store: AllowOnceStore,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        host: String = "tty",
        tool: String = "Bash"
    ) async -> EvaluationResult {
        await spendHostAsk(
            Self.makeRequest(command: command, home: home),
            cwd: cwd,
            home: home,
            store: store,
            now: now,
            allowlist: allowlist,
            host: host,
            tool: tool
        )
    }

    func spendHostAsk(
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory? = nil,
        store: AllowOnceStore,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        host: String = "tty",
        tool: String = "Bash"
    ) async -> EvaluationResult {
        await gated(
            .hostAskSpend,
            request,
            cwd: cwd,
            home: home,
            store: store,
            now: now,
            allowlist: allowlist,
            host: host,
            tool: tool
        )
    }

    /// Wire-path apply for an already-built request (ServiceRuntime evaluate).
    /// CLI and in-process fallback must use `run(.apply, ...)` so pack resolution stays shared.
    func apply(
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory? = nil,
        store: AllowOnceStore,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        host: String = "tty",
        tool: String = "Bash"
    ) async -> EvaluationResult {
        await gated(
            PolicyVerb.apply,
            request,
            cwd: cwd,
            home: home,
            store: store,
            now: now,
            allowlist: allowlist,
            host: host,
            tool: tool
        )
    }

    private static func policyVerb(_ intent: EvaluationIntent) -> PolicyVerb {
        switch intent {
        case .peek:
            .peek
        case .apply:
            .apply
        }
    }

    private func gated(
        _ verb: PolicyVerb,
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory?,
        store: AllowOnceStore,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        host: String,
        tool: String
    ) async -> EvaluationResult {
        let result = evaluateWithSemantics(request, cwd: cwd, home: home)
        // Fast path: allow/indeterminate never touch PolicyGate or the
        // allowlist loader; PolicyGate returns them unchanged anyway.
        let finished: EvaluationResult
        switch result.decision {
        case .allow, .indeterminate:
            finished = result
        case .deny:
            if Self.skipsPolicyGate(result) {
                finished = result
            } else {
                let snapshot = allowlist()
                let rebasing = GitRebaseProbe.rebaseInProgress(cwd: cwd)
                finished = await Self.applyPolicy(
                    verb,
                    result: result,
                    cwd: cwd,
                    snapshot: snapshot,
                    store: store,
                    now: now,
                    rebaseInProgress: rebasing
                )
            }
        }
        if verb.recordsDenial {
            recordDenialIfNeeded(finished, path: nil, home: home, host: host, tool: tool, now: now)
        }
        return finished
    }

    private static func applyPolicy(
        _ verb: PolicyVerb,
        result: EvaluationResult,
        cwd: WorkingDirectory?,
        snapshot: AllowlistSnapshot,
        store: AllowOnceStore,
        now: Date,
        rebaseInProgress: Bool
    ) async -> EvaluationResult {
        switch verb {
        case .peek:
            return await PolicyGate.peek(
                result,
                cwd: cwd,
                allowlist: snapshot,
                store: store,
                now: now,
                rebaseInProgress: rebaseInProgress
            ).result
        case .apply:
            return await PolicyGate.apply(
                result,
                cwd: cwd,
                allowlist: snapshot,
                store: store,
                now: now,
                rebaseInProgress: rebaseInProgress
            ).result
        case .hostAskSpend:
            let applied = await PolicyGate.apply(
                result,
                cwd: cwd,
                allowlist: snapshot,
                store: store,
                now: now,
                rebaseInProgress: rebaseInProgress
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
                rebaseInProgress: rebaseInProgress
            ).result
        }
    }

    private func evaluateWithSemantics(
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory? = nil
    ) -> EvaluationResult {
        let workspace = Self.workspaceURL(cwd: cwd)
        let pack = resolvedSession().evaluate(
            request,
            safety: SafetyStore.loadEffective(home: home, workspace: workspace),
            allowPaths: SecretAllowPaths.loadEffective(home: home, workspace: workspace),
            home: home?.rawValue
        )
        let gitContext = GitAnalysisContext(workingDirectory: cwd)
        let unwrapped = unwrapCommand(request.command, workingDirectory: cwd)
        let probe = filesystemProbe(
            unwrapped: unwrapped,
            command: request.command,
            cwd: cwd,
            home: home
        )
        let policy: EffectiveActionPolicy
        do {
            policy = EffectiveActionPolicy(rules: try Self.loadTypedRules(cwd: cwd, home: home))
        } catch {
            return EvaluationResult(
                outcome: .deny(
                    Deny(
                        ruleID: RuleID(
                            pack: ActionPolicyEngine.Builtin.pack,
                            pattern: "typed-rules-invalid"
                        ),
                        reason: "Typed rules could not be loaded."
                    ),
                    matched: nil
                ),
                matchingView: pack.matchingView
            )
        }
        return applySemantics(
            pack: pack,
            analysis: analyzeSemantics(
                unwrapped: unwrapped,
                gitContext: gitContext,
                filesystemContext: probe
            ),
            command: request.command,
            gitContext: gitContext,
            filesystemContext: probe,
            enabledPacks: request.enabledPacks,
            policy: policy
        )
    }

    /// Machine from `$HOME/.config/rv`; repo from `<cwd>/.rv`. Missing file is empty.
    /// Missing HOME skips machine and still loads repo when cwd is present.
    private static func loadTypedRules(
        cwd: WorkingDirectory?,
        home: HomeDirectory?
    ) throws -> [TypedRule] {
        let workspace = cwd.map { URL(fileURLWithPath: $0.rawValue, isDirectory: true) }
        if let home {
            return try TypedRuleStore(
                baseDirectory: RVPolicyPaths.configDirectory(home: home)
            ).loadEffective(builtin: [], workspace: workspace)
        }
        guard let workspace else {
            return []
        }
        let repo = try TypedRuleStore(baseDirectory: workspace).loadRepo(workspace: workspace)
        return TypedRuleStore.merge(builtin: [], machine: [], repo: repo)
    }

    /// Semantic hard bind. Pack denials (`boundReview == nil`) and
    /// `mandatoryHuman` still reach PolicyGate (peek/apply and Host Ask).
    private static func skipsPolicyGate(_ result: EvaluationResult) -> Bool {
        if case .deny = result.boundReview {
            return true
        }
        return false
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
        if case .deny = result.boundReview { return nil }
        guard let cwd, UnlockableDeny.matches(result: result, cwd: cwd) else { return nil }
        guard case .deny(let deny) = result.decision else { return nil }
        return await store.mintFromDeny(
            matchingView: result.matchingView,
            cwd: cwd,
            ruleID: deny.ruleID,
            now: now
        )
    }

    private func filesystemProbe(
        unwrapped: UnwrapOutcome,
        command: ShellCommand,
        cwd: WorkingDirectory?,
        home: HomeDirectory?
    ) -> FilesystemAnalysisContext {
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

    private static func workspaceURL(cwd: WorkingDirectory?) -> URL? {
        cwd.map { URL(fileURLWithPath: $0.rawValue, isDirectory: true) }
    }

    private func recordDenialIfNeeded(
        _ result: EvaluationResult,
        path: String?,
        home: HomeDirectory?,
        host: String,
        tool: String,
        now: Date
    ) {
        guard case .deny(let deny, let matched) = result.outcome else { return }
        guard let home else { return }
        let configDir = RVPolicyPaths.configDirectory(home: home)
        guard DenialLedgerPreferences.isEnabled(inConfigDirectory: configDir) else { return }
        let rawPath: String
        if let path, path.isEmpty == false {
            rawPath = path
        } else if let text = matched?.matchedText,
                  SecretPathCatalog.dayOne.firstMatch(of: text) != nil
        {
            rawPath = text
        } else {
            rawPath = ""
        }
        let category: String
        if let text = matched?.matchedText,
           let rule = SecretPathCatalog.dayOne.firstMatch(of: text)
        {
            category = rule.category.rawValue
        } else {
            category = deny.ruleID.pack.rawValue
        }
        DenialLedger(configDirectory: configDir).append(
            DenialLedgerRecord(
                timestamp: now,
                host: host,
                tool: tool,
                ruleID: deny.ruleID.rawValue,
                category: category,
                path: DenialPathRedaction.redact(rawPath, home: home.rawValue)
            ),
            now: now
        )
    }
}
