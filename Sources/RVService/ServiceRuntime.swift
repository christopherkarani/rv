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

    package private(set) var compiledPackIDs: [PackID]

    public init(
        snapshots: [PackSnapshot]? = nil,
        catalog: PackCatalog? = nil,
        home: HomeDirectory? = nil,
        allowOnce: AllowOnceStore? = nil,
        allowOnceDirectory: URL? = nil,
        idleExitSeconds: Int = IdleWatchdog.defaultSeconds,
        log: (any ServiceLog)? = nil,
        analytics: AnalyticsCoordinator? = nil
    ) {
        let resolvedHome = home ?? HomeDirectory.process()
        self.configHome = resolvedHome
        if let catalog {
            self.catalog = catalog
        } else {
            self.catalog = Self.makeCatalog(home: resolvedHome) ?? PackCatalog()
        }
        let loaded = snapshots
            ?? ((try? PackRegistry.loadAll()) ?? ((try? PackRegistry.loadDayOne()) ?? []))
        self.sessionSnapshots = loaded
        let session = EvaluateSession(
            snapshots: loaded,
            enabledPacks: Self.compileEnabledIDs(from: self.catalog)
        )
        self.compiledPackIDs = session.compiledPackIDs
        let gated = GatedEvaluate(session)
        self.gated = gated
        self.corePacksReady = gated.corePacksReady
        if let allowOnce {
            self.allowOnce = allowOnce
        } else if let allowOnceDirectory {
            self.allowOnce = AllowOnceStore(baseDirectory: allowOnceDirectory)
        } else {
            self.allowOnce = AllowOnceStore.live()
        }
        self.idleExitSeconds = idleExitSeconds
        self.log = log
        self.analytics = analytics
    }

    public func acknowledge(_ hello: Hello) -> HelloAck {
        if hello.protocolName != ProtocolVersion.name {
            return HelloAck(ok: false, skewReason: .protocolSkew)
        }
        if ProtocolVersion.isMajorSkew(
            clientSemver: hello.clientSemver,
            serviceSemver: ProtocolVersion.serviceSemver
        ) {
            return HelloAck(ok: false, skewReason: .majorVersion)
        }
        if !corePacksReady {
            return HelloAck(ok: false, skewReason: .corePacksUnavailable)
        }
        return HelloAck(ok: true)
    }

    public func handleIncoming(_ body: Data, handshakeOK: Bool) async -> (Data, Bool) {
        if let hello = try? IPCJSON.decode(Hello.self, from: body), hello.clientSemver.isEmpty == false {
            let ack = acknowledge(hello)
            let data = (try? IPCJSON.encode(ack)) ?? Data()
            return (data, ack.ok)
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
            if ack.ok == false {
                let response = IPCResponse(
                    id: request.id,
                    result: .error(.protocolSkew(ack.skewReason?.rawValue ?? "protocol"))
                )
                return ((try? IPCJSON.encode(response)) ?? Data(), false)
            }
            let response = await dispatch(request)
            return ((try? IPCJSON.encode(response)) ?? Data(), true)
        }
        let response = IPCResponse(
            id: UUID(),
            result: .error(.protocolSkew("handshake required"))
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
        case .explain, .classify, .listPacks, .setPackEnabled, .allowOnceConsume, .doctorSnapshot:
            return nil
        }
    }

    public func dispatch(_ request: IPCRequest) async -> IPCResponse {
        if request.protocolName != ProtocolVersion.name {
            return IPCResponse(id: request.id, result: .error(.protocolSkew(request.protocolName)))
        }
        let started = DispatchTime.now()
        let result: IPCResult
        switch request.method {
        case .evaluate(let params):
            if Self.isMajorSkewed(params.clientSemver) {
                result = .error(.protocolSkew(SkewReason.majorVersion.rawValue))
            } else {
                result = .evaluate(await makeEvaluateReply(params.request, cwd: params.cwd))
            }
        case .hookEvaluate(let params):
            if Self.isMajorSkewed(params.clientSemver) {
                result = .error(.protocolSkew(SkewReason.majorVersion.rawValue))
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
        }
        logIfNeeded(request: request, result: result, started: started)
        return IPCResponse(id: request.id, result: result)
    }

    package func insertGranted(matchingView: MatchingView, cwd: String, now: Date = Date()) async throws {
        try await allowOnce.insertGranted(matchingView: matchingView, cwd: cwd, now: now)
    }

    public func makeEvaluateReply(_ request: EvaluationRequest, cwd: String? = nil) async -> EvaluateReply {
        EvaluateReply(result: await runEvaluate(request, cwd: cwd))
    }

    private func makeHookEvaluateResult(_ params: HookEvaluateParams) async -> IPCResult {
        do {
            let reply = try await HookDoor.run(
                host: params.host,
                stdin: params.stdin
            ) { command, cwd in
                // Same pack resolution as the rv-cli miss path
                // (`EnabledPacks.resolve`): a warm rvd must never decide on a
                // narrower or wider set than a cold one.
                let request = GatedEvaluate.makeRequest(command: command, home: self.configHome)
                return await self.runEvaluate(request, cwd: cwd)
            }
            return .hookEvaluate(reply)
        } catch let error as IPCError {
            return .error(error)
        } catch {
            return .error(.engine("hook evaluate failed"))
        }
    }

    private func runEvaluate(_ request: EvaluationRequest, cwd: String?) async -> EvaluationResult {
        rebuildWhenUncovered(wanted: Set(request.enabledPacks))
        let result = await gated.apply(request, cwd: cwd, store: allowOnce, now: Date())
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
        let packs = catalog.records.filter(\.enabled).map(\.id.rawValue)
        Task {
            await analytics.recordDecision(kind)
            await analytics.noteEnabledPacks(packs)
            await analytics.flushDailyIfNeeded()
        }
    }

    private func explain(_ params: ExplainParams) async -> ExplainReply {
        let result = await gated.peek(
            params.request,
            cwd: params.cwd,
            store: allowOnce,
            now: Date()
        )
        let normalized = result.matchingView.isEmpty
            ? Normalize.matchingView(of: params.request.command.rawValue).rawValue
            : result.matchingView.rawValue
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
        let ruleID: RuleID?
        let packID: PackID?
        switch result.outcome {
        case .hit(let match, _):
            ruleID = match.ruleID
            packID = match.packID
        case .safeOnly(let safe):
            ruleID = nil
            packID = safe.packID
        case .deny(_, let match):
            ruleID = match?.ruleID
            packID = match?.packID
        case .quickRejected, .plain, .indeterminate:
            ruleID = nil
            packID = nil
        }
        return ExplainReply(
            result: result,
            normalized: normalized,
            ruleID: ruleID,
            packID: packID,
            suggestion: suggestion,
            stages: stages
        )
    }

    private func classify(_ params: ClassifyParams) async -> ClassifyReply {
        let result = await gated.peek(
            params.request,
            cwd: params.cwd,
            store: allowOnce,
            now: Date()
        )
        let matched: RuleMatch?
        switch result.outcome {
        case .hit(let match, _):
            matched = match
        case .deny(_, let match):
            matched = match
        case .quickRejected, .plain, .safeOnly, .indeterminate:
            matched = nil
        }
        let risk: ClassifyRisk
        switch result.decision {
        case .allow:
            if let severity = matched?.severity {
                risk = ClassifyRisk(rawValue: severity.rawValue) ?? .medium
            } else {
                risk = .safe
            }
        case .deny:
            risk = ClassifyRisk(rawValue: matched?.severity.rawValue ?? ClassifyRisk.high.rawValue) ?? .high
        case .indeterminate:
            risk = .high
        }
        var reasons: [ClassifyReason] = []
        if let matched {
            reasons.append(
                ClassifyReason(ruleID: matched.ruleID, explanation: matched.explanation ?? matched.reason)
            )
        }
        let suggestions: [String]
        switch result.decision {
        case .deny:
            suggestions = ["Run it in Terminal, or rv allow-once."]
        case .indeterminate:
            suggestions = ["Run it in Terminal."]
        case .allow:
            suggestions = []
        }
        return ClassifyReply(
            decision: result.decision,
            risk: risk,
            ruleID: matched?.ruleID,
            packID: matched?.packID,
            reasons: reasons,
            suggestions: suggestions
        )
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
            let packs = catalog.records.filter(\.enabled).map(\.id.rawValue)
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
        rebuildWhenUncovered(wanted: Set(Self.compileEnabledIDs(from: catalog)))
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
        let session = EvaluateSession(
            snapshots: sessionSnapshots,
            enabledPacks: Self.compileEnabledIDs(from: catalog)
        )
        compiledPackIDs = session.compiledPackIDs
        gated = GatedEvaluate(session)
    }

    /// Warm-runtime self-heal for behind-our-back config edits: `rv packs
    /// enable` writes config.toml directly, so a request can name packs this
    /// session never compiled. Uncompiled-but-requested packs are dropped
    /// toward allow, so rebuild before evaluating. Failed attempts retry at
    /// most once per second so a pack that can never compile costs one
    /// rebuild per interval, not one per evaluate.
    private func rebuildWhenUncovered(wanted: Set<PackID>) {
        guard !wanted.isSubset(of: Set(compiledPackIDs)) else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if wanted == lastUncoveredWanted,
           now < lastCoverageRebuildAt &+ 1_000_000_000
        {
            return
        }
        lastUncoveredWanted = wanted
        lastCoverageRebuildAt = now
        catalog = Self.makeCatalog(home: configHome) ?? catalog
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

    /// Catalog-enabled IDs, plus day-one so a catalog disable cannot uncompile
    /// required core rules or change the request evaluate set.
    private static func compileEnabledIDs(from catalog: PackCatalog) -> [PackID] {
        if catalog.records.isEmpty {
            return dayOnePackIDs
        }
        var ids = catalog.records.filter(\.enabled).map(\.id)
        for id in dayOnePackIDs where !ids.contains(id) {
            ids.append(id)
        }
        return ids
    }
}
