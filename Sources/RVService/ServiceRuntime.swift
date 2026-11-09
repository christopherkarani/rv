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

    /// The live compile-set module owns the catalog, snapshots, compiled
    /// door, and the freshness rule (throttle + rebuild). Callers here
    /// request a ready door/world for a wanted set; the hook ceremony,
    /// built in `init` before `self` can be captured, shares the same
    /// module reference and reads the same live set at peek time.
    private let compileSet: LiveCompileSet
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
    /// Operator launch ceremonies (proposal → review → permit). Shared with
    /// the XPC UI sessions so IPC dispatch and the UI bridge see one state.
    let ceremonies: WorkspaceOperatorCeremonyService
    /// Principal-bound action-approval ceremonies (ASK → review → grant).
    /// Shared with the XPC host/UI sessions so transport and bridges see
    /// one state. Separate authority from `ceremonies`, always.
    let actionCeremonies: ActionApprovalCeremonyService
    /// Owner-presence check for owner actions and non-macOS allow-once.
    let ownerPresence: OwnerPresence
    /// Hook-ask review ceremonies (pending wait → review → allow-once).
    /// Shared with the XPC UI sessions. Resolves through `HookAskResolver`
    /// only: never an `AgentInstance` grant (F3).
    let hookCeremonies: HookReviewCeremonyService

    package var compiledPackIDs: [PackID] { compileSet.compiledPackIDs }

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
        hookCeremonies: HookReviewCeremonyService? = nil,
        ownerPresence: OwnerPresence = OwnerPresence()
    ) {
        self.ownerPresence = ownerPresence
        let resolvedHome = home ?? HomeDirectory.process()
        self.configHome = resolvedHome
        // Built before the hook ceremony below: the ceremony captures
        // this local module reference, never `self` (init order).
        let compileSet = LiveCompileSet(
            snapshots: snapshots,
            catalog: catalog,
            home: resolvedHome
        )
        self.compileSet = compileSet
        self.corePacksReady = compileSet.corePacksReady
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
        self.ceremonies = ceremonies
        self.actionCeremonies = actionCeremonies ?? ActionApprovalCeremonyService()
        self.hookCeremonies = hookCeremonies ?? HookReviewCeremonyService(
            pending: self.pendingApprovals,
            allowOnce: self.allowOnce,
            grants: self.grants,
            compileSet: compileSet,
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
        context: AuthenticatedRequestContext = .unauthenticated,
        sameUIDSocket: Bool = false,
        receivedAt: ContinuousClock.Instant? = nil
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
            return await handleUnreadyIncoming(
                body, stdinOverlay: stdinOverlay, context: context, sameUIDSocket: sameUIDSocket,
                receivedAt: receivedAt)
        }
        do {
            let request = try decodeRequest(body, stdinOverlay: stdinOverlay)
            let response = await dispatch(
                request, context: context, sameUIDSocket: sameUIDSocket, receivedAt: receivedAt)
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
        _ body: Data,
        stdinOverlay: Data?,
        context: AuthenticatedRequestContext,
        sameUIDSocket: Bool,
        receivedAt: ContinuousClock.Instant?
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
                let response = await dispatch(
                    overlaid, context: context, sameUIDSocket: sameUIDSocket,
                    receivedAt: receivedAt)
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
        // Echo the decoded id so clients can always correlate handshakeRequired
        // with the call that triggered it (undecodable bodies keep a fresh id).
        let response = IPCResponse(
            id: request.id,
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
        case .confirmOwnerAction(let params):
            return params.clientSemver
        }
    }

    /// `receivedAt` is when the transport read the frame, before any actor
    /// hop: a hookEvaluate's `HookDeadline` budget runs from there.
    public func dispatch(
        _ request: IPCRequest,
        context: AuthenticatedRequestContext = .unauthenticated,
        sameUIDSocket: Bool = false,
        receivedAt: ContinuousClock.Instant? = nil
    ) async -> IPCResponse {
        if request.protocolName != ProtocolVersion.name {
            return IPCResponse(id: request.id, result: .error(.protocolSkew(.protocolSkew)))
        }
        // Protocol hygiene before authorization: a skewed client learns to
        // upgrade instead of a misleading denial. Still never evaluates.
        if Self.isMajorSkewed(implicitHelloSemver(request.method)) {
            return IPCResponse(id: request.id, result: .error(.protocolSkew(.majorVersion)))
        }
        let allowed = Self.sameUIDSocketSession(request.method, enabled: sameUIDSocket)
            || ServiceMethodAuthorization.permits(request.method, context: context)
        guard allowed else {
            return IPCResponse(id: request.id, result: .error(.authorizationDenied))
        }
        let started = DispatchTime.now()
        let result: IPCResult
        switch request.method {
        case .evaluate(let params):
            result = .evaluate(await evaluate(params.request, cwd: params.cwd))
        case .hookEvaluate(let params):
            let deadline = HookDeadline(receivedAt: receivedAt ?? .now)
            switch await makeHookEvaluateResult(params, deadline: deadline) {
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
                peek: compileSet.livePeek(store: nil, grants: grants)
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
            result = await attestTTYRedemption(params, context: context)
        case .confirmOwnerAction(let params):
            result = await confirmOwnerAction(params, context: context)
        }
        logIfNeeded(request: request, result: result, started: started)
        return IPCResponse(id: request.id, result: result)
    }

    /// The production SDK socket has already attested a same-UID peer, so
    /// it may evaluate, consult hooks and read control state without a
    /// component role. Owner mutations stay on the role matrix, which never
    /// admits them over generic IPC: a same-user process (including one an
    /// agent started) must not disable packs or save rules by reaching the
    /// socket. TTY attestation and launch proposals stay on the matrix too.
    static func sameUIDSocketSession(_ method: IPCMethod, enabled: Bool) -> Bool {
        guard enabled else { return false }
        switch ServiceMethodAuthorization.requirement(for: method) {
        case .ttyAttestation, .launchProposal, .ownerMutation, .ownerConfirm:
            return false
        case .diagnostic, .agent, .hookConsult, .controlRead:
            return true
        }
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

    /// The device owner approves `params.summary`: rvd verifies presence
    /// (see `OwnerPresence`), audits the outcome, and answers. The CLI
    /// performs the action only on `.approved`.
    private func confirmOwnerAction(
        _ params: ConfirmOwnerActionParams, context: AuthenticatedRequestContext
    ) async -> IPCResult {
        let summary = String(params.summary.unicodeScalars
            .filter { $0.properties.generalCategory != .control }
            .prefix(ConfirmOwnerActionParams.maxSummaryBytes)
            .map(Character.init))
        guard summary.isEmpty == false else { return .error(.authorizationDenied) }
        let verdict = await ownerPresence.confirm(summary, proof: params.proof, context: context)
        let reply: ConfirmOwnerActionReply
        switch verdict {
        case .approved: reply = ConfirmOwnerActionReply(outcome: .approved)
        case .denied(let denied): reply = denied
        }
        OwnerPresence.audit(
            summary: summary, approved: reply.outcome == .approved, outcome: reply.outcome.rawValue,
            context: context, home: configHome)
        return .confirmOwnerAction(reply)
    }

    /// Allow-once redeem: plants one memory grant once the device owner
    /// approves. The daemon writes no projection (the redeeming CLI flips
    /// its own row). Double-attests report planted:false and create no
    /// second grant.
    ///
    /// Who approves. The caller is an authenticated same-user peer and its
    /// role confers nothing: on macOS rvd shows the LocalAuthentication
    /// prompt itself (Touch ID or the login password), for the pinned `.cli`
    /// and for the unsigned CLI of a one-click install alike; on Linux rvd
    /// checks the login password the CLI read from its terminal.
    ///
    /// Why a coding agent cannot redeem its own code. It sees the code in
    /// the hook deny and runs as the same user, so it can reach rvd without
    /// the CLI and without a TTY, and send this request itself (running
    /// `rv allow-once` through its hook is already denied by the
    /// self-protection guard). It still has to get past the prompt, and it
    /// cannot: LocalAuthentication is answered at the console by the owner's
    /// finger or login password, which a process cannot synthesise; with no
    /// login session (headless, ssh) no prompt can be shown and the answer
    /// is `unavailable`. The prompt names only what rvd itself issued and
    /// matched against this request (command, cwd, payload digest, code), so
    /// the agent cannot dress a dangerous grant up as a harmless one through
    /// the same-user pending file, and a code rvd never issued raises no
    /// prompt at all. One prompt at a time, closed after 60 s, and five
    /// declines in ten minutes lock owner checks for ten minutes, shared
    /// with owner actions, so it cannot wear the owner down with prompts.
    private func attestTTYRedemption(
        _ params: AttestTTYRedemptionParams, context: AuthenticatedRequestContext = .unauthenticated
    ) async -> IPCResult {
        func denied() -> IPCResult { .error(.authorizationDenied) }
        // Shape re-checks for in-process callers: wire bytes already
        // passed validating decode, but a constructed value can carry
        // any raw string. Same rule, same refusal as before. They run
        // before the owner check so garbage never reaches a prompt.
        guard GrantFingerprint(validatingHex: params.fingerprint.rawValue) != nil else {
            return denied()
        }
        // params.cwd decoded through WorkingDirectory.init(from:), which
        // already applies the validating initializer; undecodable paths
        // never reach dispatch.
        guard isLowercaseHex64(params.codeHash.rawValue) else {
            return denied()
        }
        // M-07: the attested payload digest binds the planted grant. Shape
        // only here; on macOS it must also equal the digest rvd issued.
        if let digest = params.payloadDigest {
            guard ContentPayloadDigest(validatingHex: digest.rawValue) != nil else {
                return denied()
            }
        }
        var description = ""
        if ownerPresence.promptsInRvd {
            guard let found = await redemptionDescription(params, context: context) else {
                return .error(.allowOnceNotFound)
            }
            if found.redeemed {
                // Already planted in this rvd lifetime: answer the retry
                // without a second prompt.
                return .attestTTYRedemption(AttestTTYRedemptionReply(
                    planted: false, epoch: grants.epoch.uuidString))
            }
            description = found.text
        }
        let verdict = await ownerPresence.confirmRedemption(
            description, proof: params.ownerProof, context: context)
        let approved = verdict == .approved
        let outcome: String
        switch verdict {
        case .approved: outcome = ConfirmOwnerActionReply.Outcome.approved.rawValue
        case .denied(let reply): outcome = reply.outcome.rawValue
        }
        // The audit names the redeem, never the command: the audit log is a
        // same-user file, like the pending file that keeps only its head.
        OwnerPresence.audit(
            summary: "redeem allow-once code", approved: approved, outcome: outcome,
            context: context, home: configHome)
        if case .denied(let reply) = verdict {
            // No proof at all stays a plain refusal; an owner check that
            // ran and refused tells the CLI why.
            guard reply.outcome != .proofRequired else { return denied() }
            return .attestTTYRedemption(AttestTTYRedemptionReply(
                planted: false, epoch: grants.epoch.uuidString, ownerCheck: reply))
        }
        let now = clock()
        switch await grants.plant(
            fingerprint: params.fingerprint,
            cwd: params.cwd,
            codeHash: CodeHash(rawValue: "tty:\(params.codeHash.rawValue)"),
            now: now,
            payloadContentDigest: params.payloadDigest
        ) {
        case .planted:
            await allowOnce.markIssuedRedeemed(codeHash: params.codeHash.rawValue)
            // Memory only. The attesting CLI flips its own display
            // projection after planted:true; the daemon never writes the
            // shared projection file (no cross-process append race).
            return .attestTTYRedemption(AttestTTYRedemptionReply(
                planted: true, epoch: grants.epoch.uuidString
            ))
        case .alreadyRedeemed:
            await allowOnce.markIssuedRedeemed(codeHash: params.codeHash.rawValue)
            return .attestTTYRedemption(AttestTTYRedemptionReply(
                planted: false, epoch: grants.epoch.uuidString
            ))
        case .refused:
            return denied()
        }
    }

    /// rvd's own prompt text for this redeem, or nil when rvd has nothing it
    /// can vouch for (no prompt is shown then).
    ///
    /// The code rvd issued on a hook deny is the source: rvd kept the whole
    /// command in memory, and every field of the request must match it.
    /// A row pre-armed with `rv allow-once mint` was never seen by rvd; its
    /// only record is the same-user pending file, whose text the agent can
    /// rewrite. The pinned `.cli` keeps that path (its trust is unchanged);
    /// for anyone else such a code is not found.
    private func redemptionDescription(
        _ params: AttestTTYRedemptionParams, context: AuthenticatedRequestContext
    ) async -> (text: String, redeemed: Bool)? {
        let now = clock()
        let hash = params.codeHash.rawValue
        if let issued = await allowOnce.issued(codeHash: hash, now: now) {
            guard issued.fingerprint == params.fingerprint, issued.cwd == params.cwd,
                issued.payloadDigest == params.payloadDigest
            else { return nil }
            return (
                AllowOncePromptText.reason(command: issued.command, cwd: issued.cwd, ruleID: issued.ruleID),
                issued.redeemed
            )
        }
        guard context.componentRole == .cli, context.peer != nil,
            let pending = await allowOnce.pendingRow(codeHash: hash, now: now),
            pending.fingerprint == params.fingerprint.rawValue, pending.row.cwd == params.cwd,
            pending.payloadDigest == params.payloadDigest?.rawValue
        else { return nil }
        let command = AllowOncePromptText.invoked(
            view: pending.row.commandRedacted, invocationDisplay: pending.row.invocationDisplay)
        return (AllowOncePromptText.reason(command: command, cwd: pending.row.cwd, ruleID: pending.row.ruleID), false)
    }

    public func evaluate(_ request: EvaluationRequest, cwd: WorkingDirectory? = nil) async -> EvaluateReply {
        EvaluateReply(result: await runEvaluate(request, cwd: cwd))
    }

    /// `request` evaluated under the owner's configured packs. Every door
    /// (hook, SDK evaluate, explain, classify, the workspace host bridge)
    /// resolves packs from the same config, so a caller's list can no longer
    /// drop a pack the owner enabled. Before this, a caller that sent
    /// day-one or an empty list skipped packs such as `cloud.aws`, and the
    /// same command could get different verdicts depending on which door
    /// asked. Packs a caller lists beyond the config are kept in the request
    /// but only take effect once the owner enables them.
    func ownerScoped(_ request: EvaluationRequest) -> EvaluationRequest {
        var ids = EvaluationWorld.walkedPackIDs(home: configHome).ids
        for id in request.enabledPacks where ids.contains(id) == false {
            ids.append(id)
        }
        var scoped = request
        scoped.enabledPacks = ids
        return scoped
    }

    /// Service-local entry point: only a live host validation can construct the
    /// context. The bridge revalidates after this operation before releasing it.
    func evaluateAgent(
        _ params: EvaluateParams, requestID: UUID, context: ServiceValidatedAgentContext
    ) async -> EvaluateReply {
        let started = DispatchTime.now()
        let request = ownerScoped(params.request)
        let gated = compileSet.readyDoor(
            wanted: WalkedPackIDs(ids: request.enabledPacks)
        )
        let home = configHome
        // Off the actor: the judge path blocks (load wait, inference).
        let reply = EvaluateReply(result: await JudgeOffload.run {
            gated.evaluateAgent(request, cwd: params.cwd, home: home)
        })
        log?.record(ServiceLogEvent(method: "agentEvaluate", elapsedMs:
            Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000,
            requestID: requestID, principal: context.reference))
        return reply
    }

    /// rvd idle exit asks before dropping the process: unexpired allow-once
    /// grants live only in this table, so exiting would revoke them.
    public func hasLiveAllowOnceGrants() async -> Bool {
        await grants.hasLiveGrants(now: clock())
    }

    private func makeHookEvaluateResult(
        _ params: HookEvaluateParams,
        deadline: HookDeadline
    ) async -> Result<HookEvaluateReply, IPCError> {
        do {
            let reply = try await HookDoor.run(
                host: params.host,
                stdin: params.stdin,
                world: HookEvaluateWorld.live(
                    world: readyWorld(
                        wanted: EvaluationWorld.walkedPackIDs(home: configHome)
                    ),
                    host: params.host,
                    pending: pendingApprovals,
                    clock: clock,
                    recordDecision: analyticsRecorder()
                ),
                deadline: deadline
            )
            return .success(reply)
        } catch let error as IPCError {
            return .failure(error)
        } catch {
            return .failure(.hookEvaluateFailed)
        }
    }

    /// Ready world for `wanted`: the compile-set module heals coverage
    /// before the world exists, so no caller evaluates stale.
    private func readyWorld(wanted: WalkedPackIDs) -> LiveEvaluateWorld {
        compileSet.readyWorld(
            wanted: wanted,
            store: allowOnce,
            grants: grants,
            clock: clock
        )
    }

    private func runEvaluate(
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        host: LedgerHost = .tty
    ) async -> EvaluationResult {
        let scoped = ownerScoped(request)
        let result = await readyWorld(wanted: WalkedPackIDs(ids: scoped.enabledPacks))
            .apply(scoped, cwd: cwd, host: host)
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
        let packs = compileSet.analyticsEnabledPackIDs
        return { result in
            Self.recordAnalytics(result, analytics: analytics, enabledPackIDs: packs)
        }
    }

    private func recordAnalytics(for result: EvaluationResult) {
        Self.recordAnalytics(
            result,
            analytics: analytics,
            enabledPackIDs: compileSet.analyticsEnabledPackIDs
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
        // Same coverage rule as evaluate: explain must not peek through
        // a door compiled before the request's packs were enabled.
        let request = ownerScoped(params.request)
        let result = await readyWorld(
            wanted: WalkedPackIDs(ids: request.enabledPacks)
        ).peek(request, cwd: cwd)
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
        // Same coverage rule as evaluate (see `explain`).
        let request = ownerScoped(params.request)
        let result = await readyWorld(
            wanted: WalkedPackIDs(ids: request.enabledPacks)
        ).peek(request, cwd: cwd)
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
        guard configHome != nil else {
            return .failure(.packEnableFailed)
        }
        do {
            // The compile-set module's single mutation entry: config
            // write, catalog reload, and rebuild land together, so the
            // next ready door already covers the change.
            try compileSet.setPackEnabled(params.id, enabled: params.enabled)
            guard let updated = compileSet.catalog.records.first(where: { $0.id == params.id }) else {
                return .failure(.packNotFound(params.id))
            }
            let packs = compileSet.analyticsEnabledPackIDs
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
        // Refresh (reload + coverage heal) is the compile-set module's:
        // config is the operator switch, visible without bouncing rvd.
        let packs = compileSet.refreshCatalogFromDisk().records
            .map { PackRecord(id: $0.id, enabled: $0.isEnabled, bundled: $0.isBundled) }
        return ListPacksReply(
            packs: packs,
            enabledCount: packs.filter(\.enabled).count,
            totalCount: packs.count
        )
    }

    private func doctorSnapshot() -> DoctorSnapshotReply {
        DoctorSnapshotBuilder.make(
            catalog: compileSet.refreshCatalogFromDisk(),
            corePacksReady: corePacksReady,
            idleExitSeconds: idleExitSeconds,
            home: configHome
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
        case .confirmOwnerAction:
            method = "confirmOwnerAction"
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
