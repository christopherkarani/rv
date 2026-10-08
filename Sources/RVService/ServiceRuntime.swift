import Foundation
import RVAnalytics
import RVDomain
import RVEngine
import RVHistory
import RVHooks
import RVIPC
import RVPacks
import RVPolicy

/// One IPC frame plus whether this connection's handshake is now accepted.
public struct IncomingReply: Sendable, Equatable {
    public var frame: Data
    public var handshakeAccepted: Bool

    public init(frame: Data, handshakeAccepted: Bool) {
        self.frame = frame
        self.handshakeAccepted = handshakeAccepted
    }
}

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
    /// Step 8B.1 sole grant authority: service-held memory, one instance per
    /// daemon lifetime. A restart drops the table and invalidates every grant.
    private let grants: EphemeralAllowOnceTable
    private let log: (any ServiceLog)?
    private let analytics: AnalyticsCoordinator?
    private let clock: @Sendable () -> Date
    private let pendingApprovals: (any PendingApprovalCoordinating)?
    private let approvals: ApprovalRuntime
    private var analyticsEnabledPackIDs: [String] = []
    /// Operator launch ceremonies (proposal → review → permit). Shared with
    /// the XPC UI sessions so IPC dispatch and the UI bridge see one state.
    let ceremonies: WorkspaceOperatorCeremonyService
    /// Principal-bound action-approval ceremonies (ASK → review → grant).
    /// Shared with the XPC host/UI sessions so transport and bridges see
    /// one state. Separate authority from `ceremonies`, always.
    let actionCeremonies: ActionApprovalCeremonyService
    /// Hook-ask review ceremonies (pending wait → review → allow-once).
    /// Shared with the XPC UI sessions. Resolves through `HookAskResolver`
    /// only: never an `AgentInstance` grant (F3).
    let hookCeremonies: HookReviewCeremonyService

    package private(set) var compiledPackIDs: [PackID]
    private var compiledPackIDSet: Set<PackID>

    public init(
        snapshots: [PackSnapshot]? = nil,
        catalog: PackCatalog? = nil,
        home: HomeDirectory? = nil,
        allowOnce: AllowOnceStore? = nil,
        allowOnceDirectory: URL? = nil,
        grants: EphemeralAllowOnceTable? = nil,
        idleExitSeconds: Int = IdleWatchdog.defaultSeconds,
        log: (any ServiceLog)? = nil,
        analytics: AnalyticsCoordinator? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        pendingApprovals: PendingApprovalsBinding = .automatic
    ) {
        self.init(
            snapshots: snapshots,
            catalog: catalog,
            home: home,
            allowOnce: allowOnce,
            allowOnceDirectory: allowOnceDirectory,
            grants: grants,
            idleExitSeconds: idleExitSeconds,
            log: log,
            analytics: analytics,
            clock: clock,
            pendingApprovals: pendingApprovals,
            ceremonies: WorkspaceOperatorCeremonyService(),
            actionCeremonies: ActionApprovalCeremonyService())
    }

    init(
        snapshots: [PackSnapshot]?,
        catalog: PackCatalog?,
        home: HomeDirectory?,
        allowOnce: AllowOnceStore?,
        allowOnceDirectory: URL?,
        grants: EphemeralAllowOnceTable? = nil,
        idleExitSeconds: Int,
        log: (any ServiceLog)?,
        analytics: AnalyticsCoordinator?,
        clock: @escaping @Sendable () -> Date,
        pendingApprovals: PendingApprovalsBinding,
        ceremonies: WorkspaceOperatorCeremonyService,
        actionCeremonies: ActionApprovalCeremonyService? = nil,
        hookCeremonies: HookReviewCeremonyService? = nil
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
            self.allowOnce = AllowOnceStore.makeLive(home: resolvedHome)
        } else {
            self.allowOnce = AllowOnceStore(baseDirectory: uniqueEphemeralAllowOnceDirectory())
        }
        self.grants = grants ?? EphemeralAllowOnceTable()
        self.idleExitSeconds = idleExitSeconds
        self.log = log
        self.analytics = analytics
        self.clock = clock
        self.pendingApprovals = Self.resolvePendingApprovals(
            pendingApprovals,
            home: resolvedHome
        )
        self.approvals = ApprovalRuntime(
            allowOnce: self.allowOnce,
            clock: clock,
            pendingApprovals: self.pendingApprovals
        )
        self.analyticsEnabledPackIDs = Self.analyticsEnabledPackIDs(from: self.catalog)
        self.ceremonies = ceremonies
        self.actionCeremonies = actionCeremonies ?? ActionApprovalCeremonyService()
        self.hookCeremonies = hookCeremonies ?? HookReviewCeremonyService(
            pending: self.pendingApprovals,
            allowOnce: self.allowOnce,
            grants: self.grants,
            home: resolvedHome,
            clock: clock
        )
    }

    public func acknowledge(_ hello: Hello) -> HelloAck {
        if hello.protocolName != ProtocolVersion.name {
            return HelloAck(status: .skew(HelloSkewReason.protocolSkew))
        }
        if ProtocolVersion.isMajorSkew(
            clientSemver: hello.clientSemver,
            serviceSemver: ProtocolVersion.serviceSemver
        ) {
            return HelloAck(status: .skew(HelloSkewReason.majorVersion))
        }
        if !corePacksReady {
            return HelloAck(status: .skew(HelloSkewReason.corePacksUnavailable))
        }
        return HelloAck(status: .ok)
    }

    public func handleIncoming(
        _ body: Data,
        handshakeOK: Bool,
        stdinOverlay: Data? = nil,
        context: AuthenticatedRequestContext = .unauthenticated
    ) async -> IncomingReply {
        if let hello = try? IPCJSON.decode(Hello.self, from: body), hello.clientSemver.isEmpty == false {
            let ack = acknowledge(hello)
            let data = (try? IPCJSON.encode(ack)) ?? Data()
            switch ack.status {
            case .ok:
                return IncomingReply(frame: data, handshakeAccepted: true)
            case .skew:
                return IncomingReply(frame: data, handshakeAccepted: false)
            }
        }
        if handshakeOK == false {
            return await handleUnreadyIncoming(body, stdinOverlay: stdinOverlay, context: context)
        }
        do {
            let request = try decodeRequest(body, stdinOverlay: stdinOverlay)
            let response = await dispatch(request, context: context)
            return IncomingReply(
                frame: (try? IPCJSON.encode(response)) ?? Data(),
                handshakeAccepted: true
            )
        } catch {
            let response = IPCResponse(id: UUID(), result: .error(.decodeFailed))
            return IncomingReply(
                frame: (try? IPCJSON.encode(response)) ?? Data(),
                handshakeAccepted: true
            )
        }
    }

    /// Implicit hello on first evaluate when `clientSemver` is set. Old clients Hello first.
    private func handleUnreadyIncoming(
        _ body: Data, stdinOverlay: Data?, context: AuthenticatedRequestContext
    ) async -> IncomingReply {
        guard let request = try? IPCJSON.decode(IPCRequest.self, from: body) else {
            let response = IPCResponse(
                id: UUID(),
                result: .error(.protocolSkew(.handshakeRequired))
            )
            let data = (try? IPCJSON.encode(response)) ?? Data()
            return IncomingReply(frame: data, handshakeAccepted: false)
        }
        let overlaid: IPCRequest
        do {
            overlaid = try Self.applyStdinOverlay(request, stdinOverlay)
        } catch {
            let response = IPCResponse(id: request.id, result: .error(.decodeFailed))
            return IncomingReply(
                frame: (try? IPCJSON.encode(response)) ?? Data(),
                handshakeAccepted: false
            )
        }
        if let clientSemver = implicitHelloSemver(overlaid.method),
           clientSemver.isEmpty == false
        {
            let hello = Hello(protocolName: overlaid.protocolName, clientSemver: clientSemver)
            let ack = acknowledge(hello)
            switch ack.status {
            case .ok:
                let response = await dispatch(overlaid, context: context)
                return IncomingReply(
                    frame: (try? IPCJSON.encode(response)) ?? Data(),
                    handshakeAccepted: true
                )
            case .skew(let reason):
                let response = IPCResponse(
                    id: overlaid.id,
                    result: .error(.protocolSkew(Self.ipcSkewReason(reason)))
                )
                return IncomingReply(
                    frame: (try? IPCJSON.encode(response)) ?? Data(),
                    handshakeAccepted: false
                )
            }
        }
        let response = IPCResponse(
            id: UUID(),
            result: .error(.protocolSkew(.handshakeRequired))
        )
        let data = (try? IPCJSON.encode(response)) ?? Data()
        return IncomingReply(frame: data, handshakeAccepted: false)
    }

    private func decodeRequest(_ body: Data, stdinOverlay: Data?) throws -> IPCRequest {
        try Self.applyStdinOverlay(
            try IPCJSON.decode(IPCRequest.self, from: body),
            stdinOverlay
        )
    }

    private static func applyStdinOverlay(
        _ request: IPCRequest,
        _ stdinOverlay: Data?
    ) throws -> IPCRequest {
        guard let stdinOverlay else { return request }
        return try request.applyingHookStdinOverlay(stdinOverlay)
    }

    private static func ipcSkewReason(_ reason: HelloSkewReason) -> SkewReason {
        switch reason {
        case .protocolSkew:
            return .protocolSkew
        case .majorVersion:
            return .majorVersion
        case .corePacksUnavailable:
            return .corePacksUnavailable
        }
    }

    private func implicitHelloSemver(_ method: IPCMethod) -> String? {
        switch method {
        case .evaluate(let params):
            return params.clientSemver
        case .hookEvaluate(let params):
            return params.clientSemver
        case .explain, .classify, .listPacks, .setPackEnabled, .doctorSnapshot,
            .pendingList, .pendingWatch, .pendingResolve, .rulePreview, .ruleSave,
            .proposeWorkspaceLaunch, .launchProposalStatus:
            return nil
        case .attestTTYRedemption(let params):
            return params.clientSemver
        }
    }

    public func dispatch(
        _ request: IPCRequest,
        context: AuthenticatedRequestContext = .unauthenticated
    ) async -> IPCResponse {
        if request.protocolName != ProtocolVersion.name {
            return IPCResponse(id: request.id, result: .error(.protocolSkew(.protocolSkew)))
        }
        // Protocol hygiene before authorization: a skewed client learns to
        // upgrade instead of a misleading denial. Still never evaluates.
        if Self.isMajorSkewed(implicitHelloSemver(request.method)) {
            return IPCResponse(id: request.id, result: .error(.protocolSkew(.majorVersion)))
        }
        guard ServiceMethodAuthorization.permits(request.method, context: context) else {
            return IPCResponse(id: request.id, result: .error(.authorizationDenied))
        }
        let started = DispatchTime.now()
        let result: IPCResult
        switch request.method {
        case .evaluate(let params):
            result = .evaluate(await evaluate(params.request, cwd: params.cwd))
        case .hookEvaluate(let params):
            switch await makeHookEvaluateResult(params) {
            case .success(let reply): result = .hookEvaluate(reply)
            case .failure(let error): result = .error(error)
            }
        case .explain(let params):
            result = .explain(await explain(params))
        case .classify(let params):
            result = .classify(await classify(params))
        case .listPacks:
            result = .listPacks(listPacks())
        case .setPackEnabled(let params):
            switch setPackEnabled(params) {
            case .success(let reply): result = .setPackEnabled(reply)
            case .failure(let error): result = .error(error)
            }
        case .doctorSnapshot:
            result = .doctorSnapshot(doctorSnapshot())
        case .pendingList:
            switch await approvals.pendingListResult() {
            case .success(let reply): result = .pendingList(reply)
            case .failure(let error): result = .error(error)
            }
        case .pendingWatch(let params):
            switch await approvals.pendingWatchResult(afterGeneration: params.afterGeneration) {
            case .success(let reply): result = .pendingWatch(reply)
            case .failure(let error): result = .error(error)
            }
        case .pendingResolve(let params):
            switch await approvals.pendingResolveResult(
                params,
                peek: ApprovalRuntime.livePeek(
                    home: configHome,
                    grants: grants,
                    gated: { await self.currentGated() }
                )
            ) {
            case .success(let reply): result = .pendingResolve(reply)
            case .failure(let error): result = .error(error)
            }
        case .rulePreview(let params):
            switch await approvals.rulePreviewResult(params) {
            case .success(let reply): result = .rulePreview(reply)
            case .failure(let error): result = .error(error)
            }
        case .ruleSave(let params):
            switch await approvals.ruleSaveResult(params) {
            case .success(let reply): result = .ruleSave(reply)
            case .failure(let error): result = .error(error)
            }
        case .proposeWorkspaceLaunch(let params):
            do {
                let reply = try await ceremonies.propose(
                    params,
                    requester: WorkspaceAuthorizationRequester(context: context),
                    clientRequestID: request.id)
                result = .proposeWorkspaceLaunch(reply)
            } catch let error as WorkspaceOperatorCeremonyError {
                result = .error(Self.ceremonyError(error))
            } catch {
                result = .error(.authorizationDenied)
            }
        case .launchProposalStatus(let params):
            result = .launchProposalStatus(await ceremonies.proposalStatus(params))
        case .attestTTYRedemption(let params):
            result = await attestTTYRedemption(params)
        }
        logIfNeeded(request: request, result: result, started: started)
        return IPCResponse(id: request.id, result: result)
    }

    private static func ceremonyError(_ error: WorkspaceOperatorCeremonyError) -> IPCError {
        switch error {
        case .invalidProposal:
            return .launchProposalFailed("invalidProposal")
        case .unknownHost:
            return .launchProposalFailed("unknownHost")
        case .prepareFailed(let reason):
            return .launchProposalFailed(reason)
        case .storeFull:
            return .launchProposalFailed("storeFull")
        case .unknownOperation:
            return .unknownMethod
        case .notReviewable, .authorizationRejected:
            return .authorizationDenied
        case .descriptionMismatch:
            return .launchProposalFailed("stale")
        }
    }

    /// Step 8B.1 test seam: plants directly into the owned memory table.
    /// Production plants arrive only via ceremony completions.
    package func insertGranted(
        matchingView: MatchingView,
        cwd: WorkingDirectory,
        codeHash: String = UUID().uuidString,
        now: Date = Date(),
        maskedSegments: [String]? = nil,
        invocationPrefix: [String] = []
    ) async -> EphemeralAllowOnceTable.PlantResult {
        await grants.plant(
            matchingView: matchingView, cwd: cwd, codeHash: codeHash, now: now,
            maskedSegments: maskedSegments, invocationPrefix: invocationPrefix
        )
    }

    /// Genuine-CLI TTY attestation handler. The matrix already restricted
    /// this method to the pinned `.cli` role; re-validate every field
    /// anyway (a buggy caller must plant nothing), then plant one memory
    /// grant. The daemon writes no projection (the attesting CLI flips its
    /// own). Double-attests report planted:false and create no second grant.
    private func attestTTYRedemption(_ params: AttestTTYRedemptionParams) async -> IPCResult {
        func denied() -> IPCResult { .error(.authorizationDenied) }
        guard params.fingerprint.count == 64,
            params.fingerprint.allSatisfy(\.isHexDigit),
            params.fingerprint == params.fingerprint.lowercased()
        else {
            return denied()
        }
        // params.cwd decoded through WorkingDirectory.init(from:), which
        // already applies the validating initializer; undecodable paths
        // never reach dispatch.
        guard params.codeHash.count == 64,
            params.codeHash.allSatisfy(\.isHexDigit),
            params.codeHash == params.codeHash.lowercased()
        else {
            return denied()
        }
        // M-07: the attested payload digest binds the planted grant. Shape
        // only — the daemon never sees exact text, so the genuine-CLI
        // ceremony (same trust as the fingerprint) vouches the value.
        if let digest = params.payloadDigest {
            guard digest.count == 64,
                digest.allSatisfy(\.isHexDigit),
                digest == digest.lowercased()
            else {
                return denied()
            }
        }
        let now = clock()
        switch await grants.plant(
            fingerprint: params.fingerprint,
            cwd: params.cwd,
            codeHash: "tty:\(params.codeHash)",
            now: now,
            payloadContentDigest: params.payloadDigest
        ) {
        case .planted:
            // Memory only. The attesting CLI flips its own display
            // projection after planted:true; the daemon never writes the
            // shared projection file (no cross-process append race).
            return .attestTTYRedemption(AttestTTYRedemptionReply(
                planted: true, epoch: grants.epoch.uuidString
            ))
        case .alreadyRedeemed:
            return .attestTTYRedemption(AttestTTYRedemptionReply(
                planted: false, epoch: grants.epoch.uuidString
            ))
        case .refused:
            return denied()
        }
    }

    public func evaluate(_ request: EvaluationRequest, cwd: WorkingDirectory? = nil) async -> EvaluateReply {
        EvaluateReply(result: await runEvaluate(request, cwd: cwd))
    }

    /// Service-local entry point: only a live host validation can construct the
    /// context. The bridge revalidates after this operation before releasing it.
    func evaluateAgent(
        _ params: EvaluateParams, requestID: UUID, context: ServiceValidatedAgentContext
    ) async -> EvaluateReply {
        let started = DispatchTime.now()
        rebuildWhenUncovered(wanted: WalkedPackIDs(ids: params.request.enabledPacks))
        let reply = EvaluateReply(result: gated.evaluateAgent(params.request, cwd: params.cwd, home: configHome))
        log?.record(ServiceLogEvent(method: "agentEvaluate", elapsedMs:
            Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000,
            requestID: requestID, principal: context.reference))
        return reply
    }

    private func makeHookEvaluateResult(
        _ params: HookEvaluateParams
    ) async -> Result<HookEvaluateReply, IPCError> {
        do {
            rebuildWhenUncovered(wanted: EvaluationWorld.walkedPackIDs(home: configHome))
            let reply = try await HookDoor.run(
                host: params.host,
                stdin: params.stdin,
                world: HookEvaluateWorld.live(
                    world: liveWorld(),
                    host: params.host,
                    pending: pendingApprovals,
                    clock: clock,
                    recordDecision: analyticsRecorder()
                )
            )
            return .success(reply)
        } catch let error as IPCError {
            return .failure(error)
        } catch {
            return .failure(.hookEvaluateFailed)
        }
    }

    private func liveWorld() -> LiveEvaluateWorld {
        LiveEvaluateWorld(
            home: configHome,
            store: allowOnce,
            grants: grants,
            gated: gated,
            clock: clock
        )
    }

    /// Compile set after the last `rebuildGated` / `setPackEnabled`. Read at peek
    /// time so allow-once does not snapshot `gated` across the ApprovalRuntime hop.
    private func currentGated() -> GatedEvaluate {
        gated
    }

    private func runEvaluate(
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        host: LedgerHost = .tty
    ) async -> EvaluationResult {
        rebuildWhenUncovered(wanted: WalkedPackIDs(ids: request.enabledPacks))
        let result = await liveWorld().apply(request, cwd: cwd, host: host)
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

    private func analyticsRecorder() -> @Sendable (EvaluationResult) -> Void {
        let analytics = self.analytics
        let packs = analyticsEnabledPackIDs
        return { result in
            Self.recordAnalytics(result, analytics: analytics, enabledPackIDs: packs)
        }
    }

    private func recordAnalytics(for result: EvaluationResult) {
        Self.recordAnalytics(
            result,
            analytics: analytics,
            enabledPackIDs: analyticsEnabledPackIDs
        )
    }

    private static func recordAnalytics(
        _ result: EvaluationResult,
        analytics: AnalyticsCoordinator?,
        enabledPackIDs: [String]
    ) {
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
        Task {
            await analytics.recordDecision(kind)
            await analytics.noteEnabledPacks(enabledPackIDs)
            await analytics.flushDailyIfNeeded()
        }
    }

    private func explain(_ params: ExplainParams) async -> ExplainReply {
        let cwd = params.cwd
        let result = await liveWorld().peek(params.request, cwd: cwd)
        let normalized = result.matchingView.rawValue
        let stages = explainSteps(from: result).map {
            ExplainStage(name: $0.id, elapsedMs: 0)
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
        let cwd = params.cwd
        let result = await liveWorld().peek(params.request, cwd: cwd)
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

    private func setPackEnabled(_ params: SetPackEnabledParams) -> Result<SetPackEnabledReply, IPCError> {
        guard let configHome else {
            return .failure(.packEnableFailed)
        }
        do {
            if params.enabled {
                _ = try PacksFacade.enable(home: configHome, ids: [params.id.rawValue])
            } else {
                _ = try PacksFacade.disable(home: configHome, ids: [params.id.rawValue])
            }
            catalog = try PacksFacade.makeCatalog(home: configHome)
            guard let updated = catalog.records.first(where: { $0.id == params.id }) else {
                return .failure(.packNotFound(params.id))
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
            return .success(
                SetPackEnabledReply(
                    pack: PackRecord(id: updated.id, enabled: updated.isEnabled, bundled: updated.isBundled)
                )
            )
        } catch PacksCommandError.unknownID {
            return .failure(.packNotFound(params.id))
        } catch {
            return .failure(.packEnableFailed)
        }
    }

    private func listPacks() -> ListPacksReply {
        refreshCatalogFromDisk()
        let packs = catalog.records.map { PackRecord(id: $0.id, enabled: $0.isEnabled, bundled: $0.isBundled) }
        return ListPacksReply(
            packs: packs,
            enabledCount: packs.filter(\.enabled).count,
            totalCount: packs.count
        )
    }

    private func doctorSnapshot() -> DoctorSnapshotReply {
        refreshCatalogFromDisk()
        return DoctorSnapshotBuilder.make(
            catalog: catalog,
            corePacksReady: corePacksReady,
            idleExitSeconds: idleExitSeconds
        )
    }

    /// Config is the operator switch. Reload before list/doctor so a local
    /// `rv packs enable` is visible without bouncing rvd.
    private func refreshCatalogFromDisk() {
        if let refreshed = Self.makeCatalog(home: configHome) {
            catalog = refreshed
        }
        analyticsEnabledPackIDs = Self.analyticsEnabledPackIDs(from: catalog)
        rebuildWhenUncovered(
            wanted: EvaluationWorld.coverage(catalog: catalog, home: configHome).compiled
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
        case .proposeWorkspaceLaunch:
            method = "proposeWorkspaceLaunch"
        case .launchProposalStatus:
            method = "launchProposalStatus"
        case .attestTTYRedemption:
            method = "attestTTYRedemption"
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
            return try? PackCatalog.make(
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
                return PendingApprovalStore.makeLive(home: home)
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
