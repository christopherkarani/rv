import Foundation
import RVDomain
import RVEngine
import RVFileStore
import RVHistory
import RVPolicy

/// Peek shows a matching grant without consuming it. Apply spends it.
public enum EvaluationIntent: Sendable, Equatable {
    case peek
    case apply
}

/// Policy-gate verb after the Evaluate session.
private enum PolicyVerb: Sendable {
    case peek
    case apply

    var recordsDenial: Bool {
        switch self {
        case .peek:
            false
        case .apply:
            true
        }
    }
}

/// Evaluates a command through the Evaluate session, then the Policy gate.
public struct GatedEvaluate: Sendable {
    public var corePacksReady: Bool { resolvedSession().corePacksReady }

    /// Session file-tracking for judge context. Shared per process owner
    /// (the daemon's ServiceRuntime holds one); direct constructions get a
    /// fresh per-process store that starts empty.
    let touched: SessionTouchedStore

    private enum Source: Sendable {
        case prepared(EvaluateSession)
        case deferred(
            build: @Sendable () -> EvaluateSession,
            slot: UnfairLock<EvaluateSession?>
        )
    }

    private let source: Source

    /// Creates a door around an Evaluate session.
    public init(_ session: EvaluateSession = EvaluateSession(), touched: SessionTouchedStore? = nil) {
        self.source = .prepared(session)
        self.touched = touched ?? SessionTouchedStore()
    }

    /// Creates a door that defers session construction until first use, then reuses it.
    package init(lazySession: @escaping @Sendable () -> EvaluateSession, touched: SessionTouchedStore? = nil) {
        self.source = .deferred(
            build: lazySession,
            slot: UnfairLock(nil)
        )
        self.touched = touched ?? SessionTouchedStore()
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
    /// `session` keys the touched-file record; nil keeps prior behavior.
    public func runFile(
        _ action: FileToolAction,
        home: HomeDirectory? = nil,
        cwd: WorkingDirectory? = nil,
        host: LedgerHost = .tty,
        now: Date = Date(),
        session: SessionID? = nil
    ) -> EvaluationResult {
        let workspace = Self.workspaceURL(cwd: cwd)
        let detailed = SecretAllowPaths.loadEffectiveDetailed(home: home, workspace: workspace)
        Self.auditDroppedRepoLiterals(
            detailed.droppedRepoLiterals,
            home: home,
            workspace: workspace,
            now: now
        )
        let result = evaluateFileTool(
            action,
            allowPaths: detailed.effective,
            home: home
        )
        // Training semantics: the agent created/modified this path. Reads
        // never record — a read-only view proves nothing was written.
        if case .allow = result.decision,
           action.kind == .edit || action.kind == .write {
            touched.record(paths: [action.path.rawValue], session: session, workspace: cwd, now: now)
        }
        // Observe is whole-guard: the file door logs-and-allows too,
        // and records no denial.
        if JudgeRuntime.guardMode(home: home) == .observe {
            return EvaluationResult(
                outcome: .plain,
                matchingView: result.matchingView,
                analysis: result.analysis
            )
        }
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
        grants: EphemeralAllowOnceTable,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        host: LedgerHost = .tty,
        tool: LedgerTool = .bash,
        session: SessionID? = nil
    ) async -> EvaluationResult {
        switch intent {
        case .peek:
            await peek(
                command: command,
                cwd: cwd,
                home: home,
                grants: grants,
                now: now,
                allowlist: allowlist,
                host: host,
                tool: tool,
                session: session
            )
        case .apply:
            await apply(
                command: command,
                cwd: cwd,
                home: home,
                grants: grants,
                now: now,
                allowlist: allowlist,
                host: host,
                tool: tool,
                session: session
            )
        }
    }

    /// Shows a matching grant without spending it. TTY `test` / `explain`.
    public func peek(
        command: ShellCommand,
        cwd: WorkingDirectory?,
        home: HomeDirectory? = nil,
        grants: EphemeralAllowOnceTable,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        host: LedgerHost = .tty,
        tool: LedgerTool = .bash,
        session: SessionID? = nil
    ) async -> EvaluationResult {
        await peek(
            Self.makeRequest(command: command, home: home),
            cwd: cwd,
            home: home,
            grants: grants,
            now: now,
            allowlist: allowlist,
            host: host,
            tool: tool,
            session: session
        )
    }

    /// Spends a matching grant. Hook / `rvd` / in-process fallback.
    public func apply(
        command: ShellCommand,
        cwd: WorkingDirectory?,
        home: HomeDirectory? = nil,
        grants: EphemeralAllowOnceTable,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        host: LedgerHost = .tty,
        tool: LedgerTool = .bash,
        session: SessionID? = nil
    ) async -> EvaluationResult {
        await apply(
            Self.makeRequest(command: command, home: home),
            cwd: cwd,
            home: home,
            grants: grants,
            now: now,
            allowlist: allowlist,
            host: host,
            tool: tool,
            session: session
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
        grants: EphemeralAllowOnceTable,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        host: LedgerHost = .tty,
        tool: LedgerTool = .bash,
        session: SessionID? = nil
    ) async -> EvaluationResult {
        await gated(
            PolicyVerb.peek,
            request,
            cwd: cwd,
            home: home,
            grants: grants,
            now: now,
            allowlist: allowlist,
            host: host,
            tool: tool,
            session: session
        )
    }

    /// Wire-path apply for an already-built request (ServiceRuntime evaluate).
    /// CLI and in-process fallback must use `apply(command:)` so pack resolution stays shared.
    func apply(
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory? = nil,
        grants: EphemeralAllowOnceTable,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        host: LedgerHost = .tty,
        tool: LedgerTool = .bash,
        session: SessionID? = nil
    ) async -> EvaluationResult {
        await gated(
            PolicyVerb.apply,
            request,
            cwd: cwd,
            home: home,
            grants: grants,
            now: now,
            allowlist: allowlist,
            host: host,
            tool: tool,
            session: session
        )
    }

    private func gated(
        _ verb: PolicyVerb,
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory?,
        grants: EphemeralAllowOnceTable,
        now: Date,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot,
        host: LedgerHost,
        tool: LedgerTool,
        session: SessionID? = nil
    ) async -> EvaluationResult {
        // Observe: evaluate everything, log the would-be verdict, allow.
        // Grants are never spent and denials never recorded on this path.
        if JudgeRuntime.guardMode(home: home) == .observe {
            var wouldBe = evaluateWithSemantics(request, cwd: cwd, home: home, now: now)
            var allowLane = true
            if case .allow = wouldBe.decision {
                switch scriptVerdict(for: request, cwd: cwd, home: home, now: now) {
                case .deny(let hit):
                    wouldBe = Self.projectScriptHit(hit, over: wouldBe)
                case .unresolved:
                    allowLane = false
                case .clear:
                    break
                }
            }
            // Observe still records (observation, not enforcement); peek never
            // records — a read-only view proves nothing was written.
            if case .apply = verb, case .allow = wouldBe.decision {
                touched.record(
                    paths: Self.shellWriteTargets(command: request.command, analysis: wouldBe.analysis),
                    session: session, workspace: cwd, now: now
                )
            }
            return JudgeRuntime.observe(
                wouldBe: wouldBe, command: request.command, home: home,
                provenance: request.provenance, now: now, cwd: cwd,
                allowSafeLane: allowLane, isPeek: verb == .peek,
                session: session, touched: touched
            )
        }
        let result = evaluateWithSemantics(request, cwd: cwd, home: home, now: now)
        // Order matters: the script check and the judge run BEFORE the
        // Policy gate, and the gate then sees the final deny exactly
        // once. A judge/script Ask can therefore redeem the grant its
        // approval plants (no infinite Ask loop), and an allow-once
        // grant for a pack deny is never spent on a result the judge
        // would have re-denied afterwards.
        let candidate = applyScriptAndJudge(
            to: result, request: request, cwd: cwd, home: home, now: now,
            isPeek: verb == .peek, session: session, touched: touched
        )
        // Fast path: allow/indeterminate never touch PolicyGate or the
        // allowlist loader; PolicyGate returns them unchanged anyway.
        let finished: EvaluationResult
        switch candidate.decision {
        case .allow, .indeterminate:
            finished = candidate
        case .deny:
            if HookAuthorization.policyGateAccess(for: candidate) == .skip {
                finished = candidate
            } else {
                let snapshot = allowlist()
                let rebasing = GitRebaseProbe.rebaseInProgress(cwd: cwd)
                let safety = SafetyStore.loadEffective(
                    home: home,
                    workspace: Self.workspaceURL(cwd: cwd)
                )
                finished = await Self.applyPolicy(
                    verb,
                    result: candidate,
                    cwd: cwd,
                    snapshot: snapshot,
                    grants: grants,
                    now: now,
                    rebaseInProgress: rebasing,
                    safety: safety,
                    maskedSegments: Normalize.maskedSegments(of: request.command),
                    invocationPrefix: Normalize.invocationPrefix(of: request.command)
                )
            }
        }
        // Record only the final allowed apply: the judge already scored
        // this command inside applyScriptAndJudge, and the Policy gate may
        // have redeemed or kept a deny above.
        if case .apply = verb, case .allow = finished.decision {
            touched.record(
                paths: Self.shellWriteTargets(command: request.command, analysis: finished.analysis),
                session: session, workspace: cwd, now: now
            )
        }
        if verb.recordsDenial {
            recordDenialIfNeeded(finished, path: nil, home: home, host: host, tool: tool, now: now)
        }
        return finished
    }

    /// Script check, then judge, over a pack-allow. Anything else is
    /// returned untouched: a pack deny is a floor neither may lower.
    private func applyScriptAndJudge(
        to result: EvaluationResult,
        request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory?,
        now: Date,
        isPeek: Bool,
        session: SessionID? = nil,
        touched: SessionTouchedStore? = nil
    ) -> EvaluationResult {
        guard case .allow = result.decision else { return result }
        var allowLane = true
        switch scriptVerdict(for: request, cwd: cwd, home: home, now: now) {
        case .deny(let hit):
            return Self.projectScriptHit(hit, over: result)
        case .unresolved:
            allowLane = false
        case .clear:
            break
        }
        return JudgeRuntime.apply(
            to: result, command: request.command, home: home,
            provenance: request.provenance, now: now, cwd: cwd,
            allowSafeLane: allowLane, isPeek: isPeek,
            session: session, touched: touched
        )
    }

    private static func projectScriptHit(
        _ hit: EvaluationResult, over base: EvaluationResult
    ) -> EvaluationResult {
        EvaluationResult(
            outcome: hit.outcome,
            matchingView: base.matchingView,
            analysis: base.analysis,
            boundReview: hit.boundReview
        )
    }

    private func scriptVerdict(
        for request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory?,
        now: Date
    ) -> PackageScriptGate.Verdict {
        PackageScriptGate.evaluate(command: request.command, cwd: cwd, home: home) { body, packageCwd in
            let bodyRequest = EvaluationRequest(
                command: body,
                enabledPacks: request.enabledPacks,
                budget: request.budget,
                provenance: request.provenance
            )
            return evaluateWithSemantics(bodyRequest, cwd: packageCwd, home: home, now: now)
        }
    }

    private static func applyPolicy(
        _ verb: PolicyVerb,
        result: EvaluationResult,
        cwd: WorkingDirectory?,
        snapshot: AllowlistSnapshot,
        grants: EphemeralAllowOnceTable,
        now: Date,
        rebaseInProgress: Bool,
        safety: SafetyLevel,
        maskedSegments: [String]?,
        invocationPrefix: [String]
    ) async -> EvaluationResult {
        switch verb {
        case .peek:
            return await PolicyGate.preview(
                for: result,
                cwd: cwd,
                allowlist: snapshot,
                grants: grants,
                now: now,
                rebaseInProgress: rebaseInProgress,
                safety: safety,
                maskedSegments: maskedSegments,
                invocationPrefix: invocationPrefix
            ).result
        case .apply:
            return await PolicyGate.consumingGrant(
                for: result,
                cwd: cwd,
                allowlist: snapshot,
                grants: grants,
                now: now,
                rebaseInProgress: rebaseInProgress,
                safety: safety,
                maskedSegments: maskedSegments,
                invocationPrefix: invocationPrefix
            ).result
        }
    }

    /// Policy-store I/O (safety, secret allow-paths, typed rules) around the
    /// Engine evaluation door. The door owns evaluate → unwrap → probe →
    /// analyze → apply; the Policy gate runs after, in `gated`.
    /// Phase 2A has no principal-bound human grant transaction. Evaluate the
    /// canonical packs and hard policy without reading or consuming owner grants.
    /// A denied action stays denied until that separate authority flow exists.
    /// The script check and judge DO apply here — the guard is whole, on
    /// every door; only grant redemption is absent.
    func evaluateAgent(
        _ request: EvaluationRequest, cwd: WorkingDirectory?, home: HomeDirectory?
    ) -> EvaluationResult {
        let now = Date()
        let result = evaluateWithSemantics(request, cwd: cwd, home: home, now: now)
        if JudgeRuntime.guardMode(home: home) == .observe {
            var wouldBe = result
            var allowLane = true
            if case .allow = result.decision {
                switch scriptVerdict(for: request, cwd: cwd, home: home, now: now) {
                case .deny(let hit):
                    wouldBe = Self.projectScriptHit(hit, over: result)
                case .unresolved:
                    allowLane = false
                case .clear:
                    break
                }
            }
            return JudgeRuntime.observe(
                wouldBe: wouldBe, command: request.command, home: home,
                provenance: request.provenance, now: now, cwd: cwd,
                allowSafeLane: allowLane
            )
        }
        return applyScriptAndJudge(
            to: result, request: request, cwd: cwd, home: home, now: now, isPeek: false
        )
    }

    private func evaluateWithSemantics(
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        home: HomeDirectory? = nil,
        now: Date = Date()
    ) -> EvaluationResult {
        let workspace = Self.workspaceURL(cwd: cwd)
        let detailed = SecretAllowPaths.loadEffectiveDetailed(home: home, workspace: workspace)
        Self.auditDroppedRepoLiterals(
            detailed.droppedRepoLiterals,
            home: home,
            workspace: workspace,
            now: now
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
                matchingView: Normalize.matchingView(of: request.command)
            )
        }
        return resolvedSession().evaluateWithSemantics(
            request,
            safety: SafetyStore.loadEffective(home: home, workspace: workspace),
            allowPaths: detailed.effective,
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
        try PolicyWorkspace(home: home, workspace: workspaceURL(cwd: cwd))
            .loadEffectiveRules(builtin: [])
    }

    /// After apply stayed deny. Not peek. Not Ask. Nil when the deny is not unlockable.
    /// Missing HOME has no durable store `rv allow-once` can redeem, so skip the code.
    public static func mintUnlockCode(
        for result: EvaluationResult,
        cwd: WorkingDirectory?,
        store: AllowOnceStore,
        now: Date,
        home: HomeDirectory?,
        maskedSegments: [String]? = nil,
        invocationPrefix: [String] = [],
        invocationDisplay: String? = nil
    ) async -> AllowOnceUnlockMint? {
        guard home != nil else { return nil }
        guard let cwd, HookAuthorization.shouldMintUnlock(result: result, cwd: cwd) else {
            return nil
        }
        guard case .deny(let deny) = result.decision else { return nil }
        return await store.mintFromDeny(
            matchingView: result.matchingView,
            cwd: cwd,
            ruleID: deny.ruleID,
            now: now,
            maskedSegments: maskedSegments,
            invocationPrefix: invocationPrefix,
            invocationDisplay: invocationDisplay
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

extension GatedEvaluate {
    /// One JSONL row in `exemption-drops.jsonl`: repo-layer literals dropped
    /// for lack of machine blessing at one evaluation. Dropped literals are
    /// exemption patterns from `policy.toml`, never secret values.
    ///
    /// The boundary-check audit is borrowed from OpenShell: a candidate that
    /// allows beyond the boundary is reported, not applied.
    /// https://docs.nvidia.com/openshell/latest/how-it-works/policies/prover
    struct ExemptionDropRecord: Sendable, Equatable, Codable {
        var dropped: [String]
        var workspace: String?
        var recordedAt: TimeInterval
    }

    static let exemptionDropsFileName = "exemption-drops.jsonl"

    static func exemptionDropsFileURL(home: HomeDirectory) -> URL {
        RVPolicyPaths.exemptionDropsFile(
            inConfigDir: RVPolicyPaths.configDirectory(home: home))
    }

    /// Best-effort post-evaluation audit write: lock, I/O, or encode failures
    /// drop the row silently. Enforcement is unaffected — the effective set
    /// stands whether or not the audit row persists. Nil home or an empty
    /// dropped set writes nothing. Rows prune to `RVHistory.maxRows`, newest
    /// last. The row describes repo policy state observed at evaluation, not
    /// the decision, so peek audits the same as apply.
    ///
    /// Backed by `FileLockedJSONLStore` (cross-process `LOCK_EX` around
    /// load-modify-save): rvd, hook processes, and CLI fallback evaluate
    /// concurrently, and the previous in-process-lock rewrite lost rows to
    /// last-writer-wins between processes. A row identical in dropped set
    /// and workspace to the newest row is suppressed, so repeated hook
    /// checks against one unblessed repo cannot churn the cap and evict
    /// other workspaces' history.
    static func auditDroppedRepoLiterals(
        _ dropped: [String],
        home: HomeDirectory?,
        workspace: URL?,
        now: Date
    ) {
        guard dropped.isEmpty == false, let home else { return }
        let store = FileLockedJSONLStore<ExemptionDropRecord>(
            baseDirectory: RVPolicyPaths.configDirectory(home: home),
            fileName: exemptionDropsFileName
        )
        _ = try? store.withLock {
            var rows = store.load()
            if let last = rows.last,
                last.dropped == dropped,
                last.workspace == workspace?.path
            {
                return
            }
            rows.append(
                ExemptionDropRecord(
                    dropped: dropped,
                    workspace: workspace?.path,
                    recordedAt: now.timeIntervalSince1970
                )
            )
            try store.save(Array(rows.suffix(RVHistory.maxRows)))
        }
    }
}

extension GatedEvaluate {
    /// Written paths for an allowed shell command, for session file-tracking.
    /// Primary source is the typed analysis: create/overwrite targets and
    /// move destinations are known writes. Reads, deletes, and chmods never
    /// record (deletes remove rather than create; the training signal is
    /// agent-created paths). When analysis yields no write targets, a
    /// conservative text scan covers the plain redirect/mkdir/touch shapes.
    static func shellWriteTargets(command: ShellCommand, analysis: SemanticAnalysis) -> [String] {
        if let action = analysis.filesystemAction {
            switch action {
            case .create(let targets), .overwrite(let targets):
                return targets.map(\.canonical).filter { $0.isEmpty == false }
            case .move(_, let destination):
                return destination.canonical.isEmpty ? [] : [destination.canonical]
            case .delete, .chmod, .read:
                return []
            }
        }
        return shellRedirectWriteTargets(in: command.rawValue)
    }

    /// Conservative write-target scan: redirect targets (`> path`), `tee`
    /// outputs, `mkdir`/`touch` operands. Plain absolute or `./`-relative
    /// paths only; anything with glob, expansion, assignment, URL, or
    /// brace characters poisons its whole `&&`/`;`-segment (skipped, never
    /// guessed). `tee` may follow a pipe, so it matches anywhere;
    /// `mkdir`/`touch` match as the segment's command only.
    static func shellRedirectWriteTargets(in command: String) -> [String] {
        var out: [String] = []
        var segments = command.split(separator: "\n").flatMap { $0.split(separator: ";") }
        segments = segments.flatMap { $0.split(separator: "&&") }
        let dirty: Set<Character> = ["$", "`", "*", "?", "[", "]", "(", ")", "~", "=", "{", "}"]
        for rawSegment in segments.flatMap({ $0.split(separator: "||") }) {
            let segment = rawSegment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard segment.isEmpty == false else { continue }
            if segment.contains("://") || segment.contains(where: { dirty.contains($0) }) { continue }
            let tokens = segment.split(whereSeparator: \.isWhitespace).map { stripQuotes(String($0)) }
            guard tokens.allSatisfy({ $0.contains(where: { dirty.contains($0) }) == false }) else { continue }
            var index = tokens.startIndex
            while index < tokens.endIndex {
                let token = tokens[index]
                if token == ">" || token == ">>" || isFDRedirect(token) {
                    let next = tokens.index(after: index)
                    if next < tokens.endIndex, isPlainPath(tokens[next]) {
                        out.append(tokens[next])
                    }
                } else if let attached = attachedRedirectTarget(token), isPlainPath(attached) {
                    out.append(attached)
                } else if token == "tee" {
                    var next = tokens.index(after: index)
                    while next < tokens.endIndex {
                        let operand = tokens[next]
                        if isPlainPath(operand) { out.append(operand) }
                        next = tokens.index(after: next)
                    }
                } else if index == tokens.startIndex, token == "mkdir" || token == "touch" {
                    let makeDir = token == "mkdir"
                    var next = tokens.index(after: index)
                    while next < tokens.endIndex {
                        let operand = tokens[next]
                        if isPlainPath(operand) {
                            out.append(makeDir && operand.hasSuffix("/") == false ? operand + "/" : operand)
                        }
                        next = tokens.index(after: next)
                    }
                }
                index = tokens.index(after: index)
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    private static func stripQuotes(_ token: String) -> String {
        guard token.count >= 2,
              (token.hasPrefix("\"") && token.hasSuffix("\""))
                || (token.hasPrefix("'") && token.hasSuffix("'"))
        else { return token }
        return String(token.dropFirst().dropLast())
    }

    private static func isFDRedirect(_ token: String) -> Bool {
        var rest = token
        while let first = rest.first, first.isNumber { rest.removeFirst() }
        return rest == ">" || rest == ">>"
    }

    private static func attachedRedirectTarget(_ token: String) -> String? {
        var rest = token
        while let first = rest.first, first.isNumber { rest.removeFirst() }
        guard rest.hasPrefix(">") else { return nil }
        rest.removeFirst()
        if rest.hasPrefix(">") { rest.removeFirst() }
        return rest.isEmpty ? nil : rest
    }

    private static func isPlainPath(_ token: String) -> Bool {
        // /dev/null is a sink, not a created file: `2>/dev/null` must not
        // pollute the touched set with `./null`.
        guard token != "/dev/null" else { return false }
        guard token.hasPrefix("/") || token.hasPrefix("./") else { return false }
        guard token.contains(":") == false else { return false }
        return token.count > 2
    }
}
