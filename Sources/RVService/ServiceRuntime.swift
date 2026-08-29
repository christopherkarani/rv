import Foundation
import RVAnalytics
import RVDomain
import RVEngine
import RVHooks
import RVIPC
import RVPacks
import RVPolicy

public actor ServiceRuntime {
    public let corePacksReady: Bool
    public let idleExitSeconds: Int

    private var gated: GatedEvaluate
    private var catalog: PackCatalog
    private var lastUncoveredWanted: Set<PackID> = []
    private var lastCoverageRebuildAt: UInt64 = 0
    private let sessionSnapshots: [PackSnapshot]
    private let configHome: HomeDirectory?
    private let allowOnce: AllowOnceStore
    private let log: (any ServiceLog)?
    private let analytics: AnalyticsCoordinator?
    private let clock: @Sendable () -> Date
    private let pendingApprovals: (any PendingApprovalCoordinating)?
    private var pendingGeneration: UInt64 = 0
    private var pendingSetFingerprint: [String] = []
    private var analyticsEnabledPackIDs: [String] = []

    package private(set) var compiledPackIDs: [PackID]
    private var compiledPackIDSet: Set<PackID>

    public init(
        snapshots: [PackSnapshot]? = nil,
        catalog: PackCatalog? = nil,
        home: HomeDirectory? = nil,
        allowOnce: AllowOnceStore? = nil,
        allowOnceDirectory: URL? = nil,
        idleExitSeconds: Int = IdleWatchdog.defaultSeconds,
        log: (any ServiceLog)? = nil,
        analytics: AnalyticsCoordinator? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        pendingApprovals: PendingApprovalsBinding = .automatic
    ) {
        let resolvedHome = home ?? HomeDirectory.process()
        self.configHome = resolvedHome
        if let catalog {
            self.catalog = catalog
        } else {
            self.catalog = Self.makeCatalog(home: resolvedHome) ?? PackCatalog()
        }
        let loaded = EvaluationWorld.resolveSnapshots(snapshots)
        self.sessionSnapshots = loaded
        let coverage = EvaluationWorld.coverage(catalog: self.catalog, home: resolvedHome)
        let session = EvaluateSession(
            snapshots: loaded,
            compiledPacks: coverage.compiled
        )
        self.compiledPackIDs = session.compiledPackIDs
        self.compiledPackIDSet = Set(session.compiledPackIDs)
        let gated = GatedEvaluate(session)
        self.gated = gated
        self.corePacksReady = gated.corePacksReady
        if let allowOnce {
            self.allowOnce = allowOnce
        } else if let allowOnceDirectory {
            self.allowOnce = AllowOnceStore(baseDirectory: allowOnceDirectory)
        } else if let resolvedHome {
            self.allowOnce = AllowOnceStore.live(home: resolvedHome)
        } else {
            self.allowOnce = AllowOnceStore(baseDirectory: uniqueEphemeralAllowOnceDirectory())
        }
        self.idleExitSeconds = idleExitSeconds
        self.log = log
        self.analytics = analytics
        self.clock = clock
        self.pendingApprovals = Self.resolvePendingApprovals(
            pendingApprovals,
            home: resolvedHome
        )
        self.analyticsEnabledPackIDs = Self.analyticsEnabledPackIDs(from: self.catalog)
    }

    public func acknowledge(_ hello: Hello) -> HelloAck {
        if hello.protocolName != ProtocolVersion.name {
            return HelloAck(status: .skew(.protocolSkew))
        }
        if ProtocolVersion.isMajorSkew(
            clientSemver: hello.clientSemver,
            serviceSemver: ProtocolVersion.serviceSemver
        ) {
            return HelloAck(status: .skew(.majorVersion))
        }
        if !corePacksReady {
            return HelloAck(status: .skew(.corePacksUnavailable))
        }
        return HelloAck(status: .ok)
    }

    public func handleIncoming(_ body: Data, handshakeOK: Bool) async -> (Data, Bool) {
        if let hello = try? IPCJSON.decode(Hello.self, from: body), hello.clientSemver.isEmpty == false {
            let ack = acknowledge(hello)
            let data = (try? IPCJSON.encode(ack)) ?? Data()
            switch ack.status {
            case .ok:
                return (data, true)
            case .skew:
                return (data, false)
            }
        }
        if handshakeOK == false {
            return await handleUnreadyIncoming(body)
        }
        do {
            let request = try IPCJSON.decode(IPCRequest.self, from: body)
            let response = await dispatch(request)
            return ((try? IPCJSON.encode(response)) ?? Data(), true)
        } catch {
            let response = IPCResponse(id: UUID(), result: .error(.decodeFailed))
            return ((try? IPCJSON.encode(response)) ?? Data(), true)
        }
    }

    /// Implicit hello on first evaluate when `clientSemver` is set. Old clients Hello first.
    private func handleUnreadyIncoming(_ body: Data) async -> (Data, Bool) {
        if let request = try? IPCJSON.decode(IPCRequest.self, from: body),
           let clientSemver = implicitHelloSemver(request.method),
           clientSemver.isEmpty == false
        {
            let hello = Hello(protocolName: request.protocolName, clientSemver: clientSemver)
            let ack = acknowledge(hello)
            switch ack.status {
            case .ok:
                let response = await dispatch(request)
                return ((try? IPCJSON.encode(response)) ?? Data(), true)
            case .skew(let reason):
                let response = IPCResponse(
                    id: request.id,
                    result: .error(.protocolSkew(reason))
                )
                return ((try? IPCJSON.encode(response)) ?? Data(), false)
            }
        }
        let response = IPCResponse(
            id: UUID(),
            result: .error(.protocolSkew(.handshakeRequired))
        )
        let data = (try? IPCJSON.encode(response)) ?? Data()
        return (data, false)
    }

    private func implicitHelloSemver(_ method: IPCMethod) -> String? {
        switch method {
        case .evaluate(let params):
            return params.clientSemver
        case .hookEvaluate(let params):
            return params.clientSemver
        case .explain, .classify, .listPacks, .setPackEnabled, .allowOnceConsume, .doctorSnapshot,
            .pendingList, .pendingWatch, .pendingResolve, .rulePreview, .ruleSave:
            return nil
        }
    }

    public func dispatch(_ request: IPCRequest) async -> IPCResponse {
        if request.protocolName != ProtocolVersion.name {
            return IPCResponse(id: request.id, result: .error(.protocolSkew(.protocolSkew)))
        }
        let started = DispatchTime.now()
        let result: IPCResult
        switch request.method {
        case .evaluate(let params):
            if Self.isMajorSkewed(params.clientSemver) {
                result = .error(.protocolSkew(.majorVersion))
            } else {
                result = .evaluate(await makeEvaluateReply(params.request, cwd: params.cwd))
            }
        case .hookEvaluate(let params):
            if Self.isMajorSkewed(params.clientSemver) {
                result = .error(.protocolSkew(.majorVersion))
            } else {
                result = await makeHookEvaluateResult(params)
            }
        case .explain(let params):
            result = .explain(await explain(params))
        case .classify(let params):
            result = .classify(await classify(params))
        case .listPacks:
            result = .listPacks(listPacks())
        case .setPackEnabled(let params):
            result = setPackEnabled(params)
        case .allowOnceConsume:
            result = .error(.unknownMethod)
        case .doctorSnapshot:
            result = .doctorSnapshot(doctorSnapshot())
        case .pendingList:
            result = await pendingListResult()
        case .pendingWatch(let params):
            result = await pendingWatchResult(afterGeneration: params.afterGeneration)
        case .pendingResolve(let params):
            result = await pendingResolveResult(params)
        case .rulePreview(let params):
            result = await rulePreviewResult(params)
        case .ruleSave(let params):
            result = await ruleSaveResult(params)
        }
        logIfNeeded(request: request, result: result, started: started)
        return IPCResponse(id: request.id, result: result)
    }

    package func insertGranted(matchingView: MatchingView, cwd: WorkingDirectory, now: Date = Date()) async throws {
        try await allowOnce.insertGranted(matchingView: matchingView, cwd: cwd, now: now)
    }

    public func makeEvaluateReply(_ request: EvaluationRequest, cwd: WorkingDirectory? = nil) async -> EvaluateReply {
        EvaluateReply(result: await runEvaluate(request, cwd: cwd))
    }

    private func makeHookEvaluateResult(_ params: HookEvaluateParams) async -> IPCResult {
        do {
            let reply = try await HookDoor.run(
                host: params.host,
                stdin: params.stdin,
                evaluate: { command, cwd in
                    // Same pack resolution as the rv-cli miss path
                    // (`EvaluationWorld.walkedPackIDs`): a warm rvd must never decide on a
                    // narrower or wider set than a cold one.
                    let request = GatedEvaluate.makeRequest(command: command, home: self.configHome)
                    return await self.runEvaluate(request, cwd: cwd)
                },
                spendHostAsk: { command, cwd in
                    await self.runSpendHostAsk(command: command, cwd: cwd)
                }
            )
            return .hookEvaluate(reply)
        } catch let error as IPCError {
            return .error(error)
        } catch {
            return .error(.engine("hook evaluate failed"))
        }
    }

    private func runEvaluate(_ request: EvaluationRequest, cwd: WorkingDirectory?) async -> EvaluationResult {
        rebuildWhenUncovered(wanted: WalkedPackIDs(ids: request.enabledPacks))
        let now = clock()
        let baseDirectory = allowOnce.baseDirectory
        let result = await gated.apply(
            request,
            cwd: cwd,
            home: configHome,
            store: allowOnce,
            now: now,
            allowlist: {
                AllowlistStore(baseDirectory: baseDirectory)
                    .loadUserSnapshot(workspacePath: cwd.map(\.rawValue), now: now)
            }
        )
        recordAnalytics(for: result)
        return result
    }

    private func runSpendHostAsk(command: ShellCommand, cwd: WorkingDirectory?) async -> EvaluationResult {
        rebuildWhenUncovered(wanted: EvaluationWorld.walkedPackIDs(home: configHome))
        let now = clock()
        let baseDirectory = allowOnce.baseDirectory
        let result = await gated.spendHostAsk(
            command: command,
            cwd: cwd,
            home: configHome,
            store: allowOnce,
            now: now,
            allowlist: {
                AllowlistStore(baseDirectory: baseDirectory)
                    .loadUserSnapshot(workspacePath: cwd.map(\.rawValue), now: now)
            }
        )
        recordAnalytics(for: result)
        return result
    }

    /// Frame-level major-version guard: runs even when a Hello on this
    /// connection already succeeded, so a skewed `clientSemver` can never ride
    /// an open handshake into an evaluation. Applies to evaluate and
    /// hookEvaluate alike; an absent or empty semver stays legacy-compatible.
    private static func isMajorSkewed(_ clientSemver: String?) -> Bool {
        guard let clientSemver, clientSemver.isEmpty == false else {
            return false
        }
        return ProtocolVersion.isMajorSkew(
            clientSemver: clientSemver,
            serviceSemver: ProtocolVersion.serviceSemver
        )
    }

    private func recordAnalytics(for result: EvaluationResult) {
        guard let analytics else { return }
        let kind: AnalyticsDecisionKind
        switch result.decision {
        case .allow:
            kind = .allow
        case .deny:
            kind = .deny
        case .indeterminate:
            kind = .indeterminate
        }
        let packs = analyticsEnabledPackIDs
        Task {
            await analytics.recordDecision(kind)
            await analytics.noteEnabledPacks(packs)
            await analytics.flushDailyIfNeeded()
        }
    }

    private func explain(_ params: ExplainParams) async -> ExplainReply {
        let now = clock()
        let baseDirectory = allowOnce.baseDirectory
        let cwd = params.cwd
        let result = await gated.peek(
            params.request,
            cwd: cwd,
            home: configHome,
            store: allowOnce,
            now: now,
            allowlist: {
                AllowlistStore(baseDirectory: baseDirectory)
                    .loadUserSnapshot(workspacePath: cwd.map(\.rawValue), now: now)
            }
        )
        let normalized = result.matchingView.rawValue
        let stages = explainSteps(from: result).map {
            ExplainStage(name: $0.id.rawValue, elapsedMs: 0)
        }
        let suggestion: String?
        switch result.decision {
        case .deny:
            suggestion = "Run it in Terminal, or rv allow-once."
        case .indeterminate:
            suggestion = "Run it in Terminal."
        case .allow:
            suggestion = nil
        }
        return ExplainReply(
            result: result,
            normalized: normalized,
            suggestion: suggestion,
            stages: stages
        )
    }

    private func classify(_ params: ClassifyParams) async -> ClassifyReply {
        let now = clock()
        let baseDirectory = allowOnce.baseDirectory
        let cwd = params.cwd
        let result = await gated.peek(
            params.request,
            cwd: cwd,
            home: configHome,
            store: allowOnce,
            now: now,
            allowlist: {
                AllowlistStore(baseDirectory: baseDirectory)
                    .loadUserSnapshot(workspacePath: cwd.map(\.rawValue), now: now)
            }
        )
        let suggestions: [String]
        switch result.decision {
        case .deny:
            suggestions = ["Run it in Terminal, or rv allow-once."]
        case .indeterminate:
            suggestions = ["Run it in Terminal."]
        case .allow:
            suggestions = []
        }
        return ClassifyReply(result: result, suggestions: suggestions)
    }

    private func setPackEnabled(_ params: SetPackEnabledParams) -> IPCResult {
        guard let configHome else {
            return .error(.engine("pack enable failed"))
        }
        do {
            if params.enabled {
                _ = try PacksFacade.enable(home: configHome, ids: [params.id.rawValue])
            } else {
                _ = try PacksFacade.disable(home: configHome, ids: [params.id.rawValue])
            }
            catalog = try PacksFacade.makeCatalog(home: configHome)
            guard let updated = catalog.records.first(where: { $0.id == params.id }) else {
                return .error(.packNotFound(params.id))
            }
            rebuildGated()
            lastUncoveredWanted = []
            analyticsEnabledPackIDs = Self.analyticsEnabledPackIDs(from: catalog)
            let packs = analyticsEnabledPackIDs
            if let analytics {
                Task {
                    await analytics.noteEnabledPacks(packs)
                }
            }
            return .setPackEnabled(
                SetPackEnabledReply(
                    pack: PackRecord(id: updated.id, enabled: updated.enabled, bundled: updated.bundled)
                )
            )
        } catch PacksCommandError.unknownID {
            return .error(.packNotFound(params.id))
        } catch {
            return .error(.engine("pack enable failed"))
        }
    }

    private func listPacks() -> ListPacksReply {
        if let refreshed = Self.makeCatalog(home: configHome) {
            catalog = refreshed
        }
        analyticsEnabledPackIDs = Self.analyticsEnabledPackIDs(from: catalog)
        rebuildWhenUncovered(
            wanted: EvaluationWorld.coverage(catalog: catalog, home: configHome).compiled
        )
        let packs = catalog.records.map { PackRecord(id: $0.id, enabled: $0.enabled, bundled: $0.bundled) }
        return ListPacksReply(
            packs: packs,
            enabledCount: packs.filter(\.enabled).count,
            totalCount: packs.count
        )
    }

    private func doctorSnapshot() -> DoctorSnapshotReply {
        DoctorSnapshotBuilder.make(
            catalog: catalog,
            corePacksReady: corePacksReady,
            idleExitSeconds: idleExitSeconds
        )
    }

    private func pendingListResult() async -> IPCResult {
        do {
            return .pendingList(try await makePendingListReply())
        } catch {
            return .error(PendingListProjection.ipcError(from: error))
        }
    }

    private func pendingWatchResult(afterGeneration: UInt64) async -> IPCResult {
        do {
            let reply = try await makePendingListReply()
            if afterGeneration == reply.generation {
                return .pendingWatch(PendingListReply(generation: reply.generation, items: []))
            }
            return .pendingWatch(reply)
        } catch {
            return .error(PendingListProjection.ipcError(from: error))
        }
    }

    private func rulePreviewResult(_ params: RulePreviewParams) async -> IPCResult {
        guard let pendingApprovals else {
            return .error(PendingListProjection.coordinatorUnavailable)
        }
        do {
            let record = try await pendingApprovals.load(id: params.id, now: clock())
            let preview = RulePinning.preview(
                record: record,
                polarity: pinnedPolarity(params.polarity)
            )
            return .rulePreview(
                RulePreviewReply(
                    sentence: preview.sentence,
                    draft: preview.draft,
                    allowedToSave: preview.allowedToSave
                )
            )
        } catch {
            return .error(PendingListProjection.ipcError(from: error))
        }
    }

    private func ruleSaveResult(_ params: RuleSaveParams) async -> IPCResult {
        guard let pendingApprovals else {
            return .error(PendingListProjection.coordinatorUnavailable)
        }
        let polarity = pinnedPolarity(params.polarity)
        do {
            let now = clock()
            let record = try await pendingApprovals.load(id: params.id, now: now)
            let commandText = record.action.supportingCommand?.rawValue ?? ""
            let outcome = try RulePinStore(baseDirectory: allowOnce.baseDirectory).save(
                record: record,
                polarity: polarity,
                draft: params.draft,
                now: now,
                matchingView: Normalize.matchingView(of: commandText)
            )
            let decision: ApprovalDecision = polarity == .allow ? .createRule : .deny
            do {
                let resolved = try await pendingApprovals.resolve(
                    id: record.id,
                    decision: decision,
                    fingerprint: record.fingerprint,
                    identity: record.identity,
                    now: now
                )
                let terminal: Bool
                switch resolved.state {
                case .awaitingHuman:
                    terminal = false
                case .resolved, .consumed, .expired, .canceled, .timedOut:
                    terminal = true
                }
                return .ruleSave(RuleSaveReply(ruleID: outcome.ruleID, waitResolved: terminal))
            } catch let error as PendingApprovalError {
                switch error {
                case .alreadyResolved, .alreadyConsumed, .expired, .canceled, .timedOut:
                    return .ruleSave(RuleSaveReply(ruleID: outcome.ruleID, waitResolved: true))
                case .notFound, .invalidRequest, .duplicateID, .fingerprintMismatch, .identityMismatch,
                    .continuationMismatch, .notResolved, .encodeFailed, .lockFailed:
                    return .error(PendingListProjection.ipcError(from: error))
                }
            }
        } catch let error as RulePinError {
            switch error {
            case .draftMismatch:
                return .error(.ruleDraftMismatch)
            case .hardStop:
                return .error(.ruleHardStop)
            case .missingMatchingView:
                return .error(.engine("rule pin requires a matching view"))
            }
        } catch {
            return .error(PendingListProjection.ipcError(from: error))
        }
    }

    private func pinnedPolarity(_ wire: RulePolarity) -> PinnedRulePolarity {
        switch wire {
        case .allow:
            return .allow
        case .block:
            return .block
        }
    }

    private func pendingResolveResult(_ params: PendingResolveParams) async -> IPCResult {
        guard let pendingApprovals else {
            return .error(PendingListProjection.coordinatorUnavailable)
        }
        let decision: ApprovalDecision
        switch params.decision {
        case .allowOnce:
            if params.identity.session.rawValue.isEmpty {
                return .error(.pendingIdentityMismatch)
            }
            decision = .allowOnce
        case .deny:
            decision = .deny
        }
        do {
            let resolved = try await pendingApprovals.resolve(
                id: params.id,
                decision: decision,
                fingerprint: params.fingerprint,
                identity: params.identity,
                now: clock()
            )
            let terminal: Bool
            switch resolved.state {
            case .awaitingHuman:
                terminal = false
            case .resolved, .consumed, .expired, .canceled, .timedOut:
                terminal = true
            }
            return .pendingResolve(PendingResolveReply(id: resolved.id, terminal: terminal))
        } catch {
            return .error(PendingListProjection.ipcError(from: error))
        }
    }

    private func makePendingListReply() async throws -> PendingListReply {
        guard let pendingApprovals else {
            throw PendingListProjection.coordinatorUnavailable
        }
        let records = try await pendingApprovals.list(now: clock())
        let fingerprint = PendingListProjection.fingerprint(records)
        if fingerprint != pendingSetFingerprint {
            pendingGeneration += 1
            pendingSetFingerprint = fingerprint
        }
        return PendingListReply(
            generation: pendingGeneration,
            items: PendingListProjection.items(from: records)
        )
    }

    private func logIfNeeded(request: IPCRequest, result: IPCResult, started: DispatchTime) {
        let method: String
        var decision: String?
        var ruleID: String?
        switch request.method {
        case .evaluate:
            method = "evaluate"
        case .hookEvaluate:
            method = "hookEvaluate"
        case .explain:
            method = "explain"
        case .classify:
            method = "classify"
        case .listPacks:
            method = "listPacks"
        case .setPackEnabled:
            method = "setPackEnabled"
        case .allowOnceConsume:
            method = "allowOnce.consume"
        case .doctorSnapshot:
            method = "doctorSnapshot"
        case .pendingList:
            method = "pendingList"
        case .pendingWatch:
            method = "pendingWatch"
        case .pendingResolve:
            method = "pendingResolve"
        case .rulePreview:
            method = "rulePreview"
        case .ruleSave:
            method = "ruleSave"
        }
        if case .evaluate(let reply) = result {
            switch reply.result.decision {
            case .allow:
                decision = "allow"
            case .deny(let deny):
                decision = "deny"
                ruleID = deny.ruleID.rawValue
            case .indeterminate(let reason):
                decision = "indeterminate"
                ruleID = reason.rawValue
            }
        }
        log?.record(
            ServiceLogEvent(
                method: method,
                decision: decision,
                ruleID: ruleID,
                elapsedMs: elapsedMs(since: started),
                requestID: request.id
            )
        )
    }

    private func elapsedMs(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    private func rebuildGated() {
        let coverage = EvaluationWorld.coverage(catalog: catalog, home: configHome)
        let session = EvaluateSession(
            snapshots: sessionSnapshots,
            compiledPacks: coverage.compiled
        )
        let compiledPackIDs = session.compiledPackIDs
        self.compiledPackIDs = compiledPackIDs
        compiledPackIDSet = Set(compiledPackIDs)
        gated = GatedEvaluate(session)
    }

    /// Wire request walk set. Those IDs must already be compiled, or we rebuild.
    private func rebuildWhenUncovered(wanted: WalkedPackIDs) {
        rebuildWhenUncovered(wantedIDs: wanted.ids)
    }

    /// Coverage compile set after catalog refresh (`listPacks`).
    private func rebuildWhenUncovered(wanted: CompiledPackIDs) {
        rebuildWhenUncovered(wantedIDs: wanted.ids)
    }

    /// Warm-runtime self-heal for behind-our-back config edits: `rv packs
    /// enable` writes config.toml directly, so a request can name packs this
    /// session never compiled. Uncompiled-but-requested packs are dropped
    /// toward allow, so rebuild before evaluating. Failed attempts retry at
    /// most once per second so a pack that can never compile costs one
    /// rebuild per interval, not one per evaluate.
    private func rebuildWhenUncovered(wantedIDs: [PackID]) {
        guard wantedIDs.contains(where: { !compiledPackIDSet.contains($0) }) else { return }
        let wantedIDs = Set(wantedIDs)
        let now = DispatchTime.now().uptimeNanoseconds
        if wantedIDs == lastUncoveredWanted,
           now < lastCoverageRebuildAt &+ 1_000_000_000
        {
            return
        }
        lastUncoveredWanted = wantedIDs
        lastCoverageRebuildAt = now
        catalog = Self.makeCatalog(home: configHome) ?? catalog
        analyticsEnabledPackIDs = Self.analyticsEnabledPackIDs(from: catalog)
        rebuildGated()
    }

    /// Catalog for a home; nil home mirrors the old empty-HOME catalog with the day-one packs enabled.
    private static func makeCatalog(home: HomeDirectory?) -> PackCatalog? {
        guard let home else {
            return try? PackCatalog.bundlingAll(
                enabled: Set(dayOnePackIDs),
                index: PackRegistry.loadIndex()
            )
        }
        return try? PacksFacade.makeCatalog(home: home)
    }

    private static func analyticsEnabledPackIDs(from catalog: PackCatalog) -> [String] {
        catalog.enabledIDs.map(\.rawValue)
    }

    private static func resolvePendingApprovals(
        _ binding: PendingApprovalsBinding,
        home: HomeDirectory?
    ) -> (any PendingApprovalCoordinating)? {
        switch binding {
        case .automatic:
            if let home {
                return PendingApprovalStore.live(home: home)
            }
            return PendingApprovalStore(baseDirectory: uniqueEphemeralPendingDirectory())
        case .coordinator(let coordinator):
            return coordinator
        case .missing:
            return nil
        }
    }
}

private func uniqueEphemeralAllowOnceDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-allow-once-\(UUID().uuidString)", isDirectory: true)
}

private func uniqueEphemeralPendingDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-pending-\(UUID().uuidString)", isDirectory: true)
}
