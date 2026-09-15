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

/// Evaluates a command through the Evaluate session, then the Policy gate.
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
        host: LedgerHost = .tty,
        now: Date = Date()
    ) -> EvaluationResult {
        let allowPaths = SecretAllowPaths.loadEffective(
            home: home,
            workspace: Self.workspaceURL(cwd: cwd)
        )
        let result = evaluateFileTool(
            action,
            allowPaths: allowPaths,
            home: home
        )
        recordDenialIfNeeded(
            result,
            path: action.path.rawValue,
            home: home,
            host: host,
            tool: .file(action.kind),
            now: now
        )
        return result
    }

    /// Trampoline onto `peek(command:)` or `apply(command:)`.
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
        host: LedgerHost = .tty,
        tool: LedgerTool = .bash
    ) async -> EvaluationResult {
        switch intent {
        case .peek:
            await peek(
                command: command,
                cwd: cwd,
                home: home,
                store: store,
                now: now,
                allowlist: allowlist,
                host: host,
                tool: tool
            )
        case .apply:
            await apply(
                command: command,
                cwd: cwd,
                home: home,
                store: store,
                now: now,
                allowlist: allowlist,
                host: host,
                tool: tool
            )
        }
    }

    /// Shows a matching grant without spending it. TTY `test` / `explain`.
    public func peek(
        command: ShellCommand,
        cwd: WorkingDirectory?,
        home: HomeDirectory? = nil,
        store: AllowOnceStore,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        host: LedgerHost = .tty,
        tool: LedgerTool = .bash
    ) async -> EvaluationResult {
        await peek(
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

    /// Spends a matching grant. Hook / `rvd` / in-process fallback.
    public func apply(
        command: ShellCommand,
        cwd: WorkingDirectory?,
        home: HomeDirectory? = nil,
        store: AllowOnceStore,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        host: LedgerHost = .tty,
        tool: LedgerTool = .bash
    ) async -> EvaluationResult {
        await apply(
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
    /// CLI and in-process fallback must use `peek(command:)` so pack resolution stays shared.
    func peek(
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory? = nil,
        store: AllowOnceStore,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        host: LedgerHost = .tty,
        tool: LedgerTool = .bash
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
        host: LedgerHost = .tty,
        tool: LedgerTool = .bash
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
        host: LedgerHost = .tty,
        tool: LedgerTool = .bash
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
    /// CLI and in-process fallback must use `apply(command:)` so pack resolution stays shared.
    func apply(
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory? = nil,
        store: AllowOnceStore,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        host: LedgerHost = .tty,
        tool: LedgerTool = .bash
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

    private func gated(
        _ verb: PolicyVerb,
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory?,
        store: AllowOnceStore,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        host: LedgerHost,
        tool: LedgerTool
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
            return await PolicyGate.preview(
                for: result,
                cwd: cwd,
                allowlist: snapshot,
                store: store,
                now: now,
                rebaseInProgress: rebaseInProgress
            ).result
        case .apply:
            return await PolicyGate.consumingGrant(
                for: result,
                cwd: cwd,
                allowlist: snapshot,
                store: store,
                now: now,
                rebaseInProgress: rebaseInProgress
            ).result
        case .hostAskSpend:
            let applied = await PolicyGate.consumingGrant(
                for: result,
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

    /// Policy-store I/O (safety, secret allow-paths, typed rules) around the
    /// Engine evaluation door. The door owns evaluate → unwrap → probe →
    /// analyze → apply; the Policy gate runs after, in `gated`.
    private func evaluateWithSemantics(
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory? = nil
    ) -> EvaluationResult {
        let workspace = Self.workspaceURL(cwd: cwd)
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
                matchingView: Normalize.matchingView(of: request.command)
            )
        }
        return resolvedSession().evaluateWithSemantics(
            request,
            safety: SafetyStore.loadEffective(home: home, workspace: workspace),
            allowPaths: SecretAllowPaths.loadEffective(home: home, workspace: workspace),
            home: home,
            workingDirectory: cwd,
            gitProbe: { unwrapped in
                GitLiveProbe.world(unwrapped: unwrapped, fallbackCwd: cwd)
            },
            filesystemProbe: { unwrapped in
                FilesystemLiveProbe.context(
                    unwrapped: unwrapped,
                    command: request.command,
                    cwd: cwd,
                    homeDirectory: home
                )
            },
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
    ) async -> AllowOnceUnlockCode? {
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

    private static func workspaceURL(cwd: WorkingDirectory?) -> URL? {
        cwd.map { URL(fileURLWithPath: $0.rawValue, isDirectory: true) }
    }

    private func recordDenialIfNeeded(
        _ result: EvaluationResult,
        path: String?,
        home: HomeDirectory?,
        host: LedgerHost,
        tool: LedgerTool,
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
        let category: LedgerCategory
        if let text = matched?.matchedText,
           let rule = SecretPathCatalog.dayOne.firstMatch(of: text)
        {
            category = .secret(rule.category)
        } else {
            category = .pack(deny.ruleID.pack)
        }
        DenialLedger(configDirectory: configDir).append(
            DenialLedgerRecord(
                timestamp: now,
                host: host,
                tool: tool,
                ruleID: deny.ruleID,
                category: category,
                path: DenialPathRedaction.redact(rawPath, home: home)
            ),
            now: now
        )
    }
}
