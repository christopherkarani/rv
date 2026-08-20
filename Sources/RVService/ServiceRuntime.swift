import Foundation
import RVDomain
import RVEngine
import RVIPC
import RVPacks
import RVPolicy

public actor ServiceRuntime {
    public let corePacksReady: Bool
    public let idleExitSeconds: Int

    private let gated: GatedEvaluate
    private var catalog: PackCatalog
    private let allowOnce: AllowOnceStore
    private let log: (any ServiceLog)?

    public init(
        snapshots: [PackSnapshot]? = nil,
        catalog: PackCatalog? = nil,
        allowOnce: AllowOnceStore? = nil,
        allowOnceDirectory: URL? = nil,
        idleExitSeconds: Int = IdleWatchdog.defaultSeconds,
        log: (any ServiceLog)? = nil
    ) {
        let gated = GatedEvaluate(EvaluateSession(snapshots: snapshots))
        self.gated = gated
        self.corePacksReady = gated.corePacksReady
        if let catalog {
            self.catalog = catalog
        } else {
            let home = (ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "")
            self.catalog = (try? PacksFacade.makeCatalog(home: home)) ?? PackCatalog()
        }
        if let allowOnce {
            self.allowOnce = allowOnce
        } else if let allowOnceDirectory {
            self.allowOnce = AllowOnceStore(baseDirectory: allowOnceDirectory)
        } else {
            self.allowOnce = AllowOnceStore.live()
        }
        self.idleExitSeconds = idleExitSeconds
        self.log = log
    }

    public func acknowledge(_ hello: Hello) -> HelloAck {
        if hello.protocolName != ProtocolVersion.name {
            return HelloAck(ok: false, skewReason: "protocol")
        }
        if !corePacksReady {
            return HelloAck(ok: false, skewReason: "core packs unavailable")
        }
        return HelloAck(ok: true)
    }

    public func handleIncoming(_ body: Data, handshakeOK: Bool) async -> (Data, Bool) {
        if let hello = try? IPCJSON.decode(Hello.self, from: body), hello.clientSemver.isEmpty == false {
            let ack = acknowledge(hello)
            let data = (try? IPCJSON.encode(ack)) ?? Data()
            return (data, ack.ok)
        }
        guard handshakeOK else {
            let response = IPCResponse(
                id: UUID(),
                result: .error(.protocolSkew("handshake required"))
            )
            let data = (try? IPCJSON.encode(response)) ?? Data()
            return (data, false)
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

    public func dispatch(_ request: IPCRequest) async -> IPCResponse {
        if request.protocolName != ProtocolVersion.name {
            return IPCResponse(id: request.id, result: .error(.protocolSkew(request.protocolName)))
        }
        let started = DispatchTime.now()
        let result: IPCResult
        switch request.method {
        case .evaluate(let params):
            result = .evaluate(await makeEvaluateReply(params.request, cwd: params.cwd))
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

    public func insertGranted(matchingView: MatchingView, cwd: String, now: Date = Date()) async throws {
        try await allowOnce.insertGranted(matchingView: matchingView, cwd: cwd, now: now)
    }

    public func makeEvaluateReply(_ request: EvaluationRequest, cwd: String? = nil) async -> EvaluateReply {
        EvaluateReply(result: await runEvaluate(request, cwd: cwd), via: "xpc")
    }

    private func runEvaluate(_ request: EvaluationRequest, cwd: String?) async -> EvaluationResult {
        await gated.apply(request, cwd: cwd, store: allowOnce, now: Date())
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
        return ExplainReply(
            result: result,
            normalized: normalized,
            ruleID: result.matched?.ruleID,
            packID: result.matched?.packID ?? result.matchedSafe?.packID,
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
        let risk: ClassifyRisk
        switch result.decision {
        case .allow:
            if let severity = result.matched?.severity {
                risk = ClassifyRisk(rawValue: severity.rawValue) ?? .medium
            } else {
                risk = .safe
            }
        case .deny:
            risk = ClassifyRisk(rawValue: result.matched?.severity.rawValue ?? ClassifyRisk.high.rawValue) ?? .high
        case .indeterminate:
            risk = .high
        }
        var reasons: [ClassifyReason] = []
        if let matched = result.matched {
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
            ruleID: result.matched?.ruleID,
            packID: result.matched?.packID,
            reasons: reasons,
            suggestions: suggestions
        )
    }

    private func setPackEnabled(_ params: SetPackEnabledParams) -> IPCResult {
        let home = (ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "")
        do {
            if params.enabled {
                _ = try PacksFacade.enable(home: home, ids: [params.id.rawValue])
            } else {
                _ = try PacksFacade.disable(home: home, ids: [params.id.rawValue])
            }
            catalog = try PacksFacade.makeCatalog(home: home)
            guard let updated = catalog.records.first(where: { $0.id == params.id }) else {
                return .error(.packNotFound(params.id))
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
        let home = (ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "")
        if let refreshed = try? PacksFacade.makeCatalog(home: home) {
            catalog = refreshed
        }
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
}
