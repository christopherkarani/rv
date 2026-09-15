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

    /// Compile set for evaluate and pending peek. A lock so ApprovalRuntime's
    /// injected peek sees `rebuildGated` without hopping back into this actor.
    private let gatedSlot: UnfairLock<GatedEvaluate>
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
    private let approvals: ApprovalRuntime
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
        self.gatedSlot = UnfairLock(gated)
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
        self.idleExitSeconds = idleExitSeconds
        self.log = log
        self.analytics = analytics
        self.clock = clock
        let resolvedPending = Self.resolvePendingApprovals(
            pendingApprovals,
            home: resolvedHome
        )
        self.pendingApprovals = resolvedPending
        self.analyticsEnabledPackIDs = Self.analyticsEnabledPackIDs(from: self.catalog)
        let resolvedAllowOnce = self.allowOnce
        let gatedSlot = self.gatedSlot
        self.approvals = ApprovalRuntime(
            pendingApprovals: resolvedPending,
            allowOnce: resolvedAllowOnce,
            clock: clock,
            peek: { command, cwd, now in
                await LiveEvaluateWorld(
                    home: resolvedHome,
                    store: resolvedAllowOnce,
                    gated: gatedSlot.withLock { $0 },
                    clock: { now }
                ).peek(command: command, cwd: cwd)
            }
        )
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

    public func handleIncoming(
        _ body: Data,
        handshakeOK: Bool,
        stdinOverlay: Data? = nil
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
            return await handleUnreadyIncoming(body, stdinOverlay: stdinOverlay)
        }
        do {
            let request = try decodeRequest(body, stdinOverlay: stdinOverlay)
            let response = await dispatch(request)
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
    private func handleUnreadyIncoming(_ body: Data, stdinOverlay: Data?) async -> IncomingReply {
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
                let response = await dispatch(overlaid)
                return IncomingReply(
                    frame: (try? IPCJSON.encode(response)) ?? Data(),
                    handshakeAccepted: true
                )
            case .skew(let reason):
                let response = IPCResponse(
                    id: overlaid.id,
                    result: .error(.protocolSkew(reason))
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

    private func implicitHelloSemver(_ method: IPCMethod) -> String? {
        switch method {
        case .evaluate(let params):
            return params.clientSemver
        case .hookEvaluate(let params):
            return params.clientSemver
        case .explain, .classify, .listPacks, .setPackEnabled, .doctorSnapshot,
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
                result = .evaluate(await evaluate(params.request, cwd: params.cwd))
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
        case .doctorSnapshot:
            result = .doctorSnapshot(doctorSnapshot())
        case .pendingList:
            result = await approvals.list()
        case .pendingWatch(let params):
            result = await approvals.watch(afterGeneration: params.afterGeneration)
        case .pendingResolve(let params):
            result = await approvals.resolve(params)
        case .rulePreview(let params):
            result = await approvals.previewRule(params)
        case .ruleSave(let params):
            result = await approvals.saveRule(params)
        }
        logIfNeeded(request: request, result: result, started: started)
        return IPCResponse(id: request.id, result: result)
    }

    package func insertGranted(matchingView: MatchingView, cwd: WorkingDirectory, now: Date = Date()) async throws {
        try await allowOnce.insertGranted(matchingView: matchingView, cwd: cwd, now: now)
    }

    public func evaluate(_ request: EvaluationRequest, cwd: WorkingDirectory? = nil) async -> EvaluateReply {
        EvaluateReply(result: await runEvaluate(request, cwd: cwd))
    }

    private func makeHookEvaluateResult(_ params: HookEvaluateParams) async -> IPCResult {
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
            return .hookEvaluate(reply)
        } catch let error as IPCError {
            return .error(error)
        } catch {
            return .error(.hookEvaluateFailed)
        }
    }

    private func liveWorld() -> LiveEvaluateWorld {
        LiveEvaluateWorld(
            home: configHome,
            store: allowOnce,
            gated: gatedSlot.withLock { $0 },
            clock: clock
        )
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

    private func setPackEnabled(_ params: SetPackEnabledParams) -> IPCResult {
        guard let configHome else {
            return .error(.packEnableFailed)
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
                    pack: PackRecord(id: updated.id, enabled: updated.isEnabled, bundled: updated.isBundled)
                )
            )
        } catch PacksCommandError.unknownID {
            return .error(.packNotFound(params.id))
        } catch {
            return .error(.packEnableFailed)
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
        let packs = catalog.records.map { PackRecord(id: $0.id, enabled: $0.isEnabled, bundled: $0.isBundled) }
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
        gatedSlot.withLock { $0 = GatedEvaluate(session) }
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
