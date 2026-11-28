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
    /// Drains the hook-local evaluator's spool, one drain at a time off the
    /// cooperative pool; nil without a home.
    let hookLocalSpool: HookLocalSpoolDrainer?
    private let clock: @Sendable () -> Date
    /// Every hook decision, for `rv term` (`DecisionLog`). Nil outside rvd.
    private let decisionLog: DecisionLogRecorder?
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
    /// Each hookEvaluate's `HookDeadline` budget. Always
    /// `HookDeadline.budget` in rvd: only this module's internal init sets
    /// it, so no caller, request or launch environment can stretch it.
    let hookBudget: Duration
    /// `policyStatus` loads: off the cooperative pool, at most two at once.
    let policyStatusService: PolicyStatusService
    /// Live events (`events`): every hook decision rvd replies with, and
    /// every pending ask and resolution. In-process consumers subscribe
    /// here (`LiveEventBus.subscribe`); none writes on the hook path.
    package nonisolated let events: LiveEventBus
    /// Finishes once the pending store's events reach `events`.
    nonisolated let pendingEventsForwarded: Task<Void, Never>?
    /// Loosen proposals (F2): stored here, applied only after the owner check.
    let proposals: LoosenProposalService

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
        ownerPresence: OwnerPresence = OwnerPresence(),
        hookBudget: Duration = HookDeadline.budget,
        policyStatusService: PolicyStatusService = PolicyStatusService(),
        judge: any JudgePort = LiveJudgePort(),
        loosenApplier: LoosenApplier? = nil,
        recordsDecisions: Bool = false
    ) {
        self.ownerPresence = ownerPresence
        self.hookBudget = hookBudget
        self.policyStatusService = policyStatusService
        let resolvedHome = home ?? HomeDirectory.process()
        self.configHome = resolvedHome
        // Built before the hook ceremony below: the ceremony captures
        // this local module reference, never `self` (init order).
        let compileSet = LiveCompileSet(
            snapshots: snapshots,
            catalog: catalog,
            home: resolvedHome,
            uptimeNanoseconds: { DispatchTime.now().uptimeNanoseconds },
            judge: judge
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
        self.hookLocalSpool = resolvedHome.map { home in
            HookLocalSpoolDrainer(home: home, deliver: { drained in
                guard let analytics else { return }
                if drained.decisions.isEmpty == false { await analytics.recordDecisions(drained.decisions) }
                await analytics.noteEnabledPacks(compileSet.analyticsEnabledPackIDs)
                await analytics.flushDailyIfNeeded()
            })
        }
        self.clock = clock
        // rvd only (`RVDProcess`): tests and in-process runtimes never
        // write the decision log.
        self.decisionLog = recordsDecisions ? DecisionLogRecorder.live(home: resolvedHome, clock: clock) : nil
        self.pendingApprovals = Self.resolvePendingApprovals(
            pendingApprovals,
            home: resolvedHome
        )
        let events = LiveEventBus()
        self.events = events
        self.pendingEventsForwarded = self.pendingApprovals.map { LivePendingEvents.forward($0, to: events) }
        self.proposals = LoosenProposalService(
            store: resolvedHome.map { LoosenProposalStore(configDirectory: RVPolicyPaths.configDirectory(home: $0)) },
            applier: loosenApplier ?? resolvedHome.map(LoosenApplier.live(home:)),
            publish: { payload, time in events.publish(payload, at: time) })
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
        case .explain, .classify, .listPacks, .setPackEnabled, .doctorSnapshot, .policyStatus,
            .pendingList, .pendingWatch, .pendingResolve, .rulePreview, .ruleSave,
            .proposeWorkspaceLaunch, .launchProposalStatus, .events, .listProposals:
            return nil
        case .proposeLoosen(let params):
            return params.clientSemver
        case .decideProposal(let params):
            return params.clientSemver
        case .attestTTYRedemption(let params):
            return params.clientSemver
        case .confirmOwnerAction(let params):
            return params.clientSemver
        case .mintAllowOnce(let params):
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
            || Self.socketSessionReadsEvents(request.method, enabled: sameUIDSocket, context: context)
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
            let deadline = HookDeadline(receivedAt: receivedAt ?? .now, budget: hookBudget)
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
            // The pool query blocks on XPC: off the actor.
            let pool = await JudgeOffload.run { JudgeRuntime.poolProbe() }
            result = .doctorSnapshot(doctorSnapshot(pool: pool))
        case .policyStatus(let params):
            result = .policyStatus(await policyStatus(params))
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
        case .mintAllowOnce(let params):
            result = await mintAllowOnce(params, context: context)
        case .events(let params):
            result = .events(await liveEvents(params, context: context, sameUIDSocket: sameUIDSocket))
        case .proposeLoosen(let params):
            result = .proposeLoosen(await proposals.propose(params, now: clock()))
        case .listProposals(let params):
            result = .listProposals(await proposals.list(params, now: clock()))
        case .decideProposal(let params):
            result = .decideProposal(await decideProposal(params, context: context))
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
        // `ownerEvents` checks the uid: `socketSessionReadsEvents`.
        case .ttyAttestation, .launchProposal, .ownerMutation, .ownerConfirm, .ownerEvents, .proposals:
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

    /// Approve or decline one loosen proposal. Approving runs the same
    /// owner check and audit as `confirmOwnerAction`, on rvd's own prompt
    /// for the stored row; an approval rvd could not record is not given.
    private func decideProposal(
        _ params: DecideProposalParams, context: AuthenticatedRequestContext
    ) async -> DecideProposalReply {
        let presence = ownerPresence
        let home = configHome
        return await proposals.decide(params, now: clock) { prompt in
            let reply: ConfirmOwnerActionReply
            switch await presence.confirm(prompt, proof: params.proof, context: context) {
            case .approved:
                reply = ConfirmOwnerActionReply(
                    outcome: .approved, presence: presence.promptsItself ? .daemonPrompt : .password)
            case .denied(let denied):
                reply = denied
            }
            let recorded = await OwnerPresence.audit(
                summary: prompt, approved: reply.outcome == .approved, outcome: reply.outcome.rawValue,
                context: context, home: home)
            if reply.outcome == .approved, recorded == false {
                return (false, ConfirmOwnerActionReply(outcome: .auditUnwritable))
            }
            return (reply.outcome == .approved, reply)
        }
    }

    /// The device owner approves `params.summary`: rvd verifies presence
    /// (see `OwnerPresence`), audits the outcome, and answers. The CLI
    /// performs the action only on `.approved`.
    private func confirmOwnerAction(
        _ params: ConfirmOwnerActionParams, context: AuthenticatedRequestContext
    ) async -> IPCResult {
        // The prompt is all the macOS owner reads before the CLI applies the
        // full action: invisible, format and separator characters are shown
        // escaped, and a summary too long to show whole is refused, never
        // shortened (a cut could drop a destination or a data-loss warning).
        let summary = DisplayedText.approvalField(params.summary)
        guard summary.isEmpty == false,
              summary.unicodeScalars.count <= ConfirmOwnerActionParams.maxSummaryBytes
        else { return .error(.authorizationDenied) }
        let verdict = await ownerPresence.confirm(summary, proof: params.proof, context: context)
        let reply: ConfirmOwnerActionReply
        switch verdict {
        case .approved:
            // `confirm` approves only through rvd's prompt or, without one,
            // a verified password: say which, so the CLI can tell this rvd
            // from one that approved a pinned CLI unchecked.
            reply = ConfirmOwnerActionReply(
                outcome: .approved, presence: ownerPresence.promptsItself ? .daemonPrompt : .password)
        case .denied(let denied): reply = denied
        }
        let recorded = await OwnerPresence.audit(
            summary: summary, approved: reply.outcome == .approved, outcome: reply.outcome.rawValue,
            context: context, home: configHome)
        // An approval rvd could not record is not given: the CLI acts on it.
        if reply.outcome == .approved, recorded == false {
            return .confirmOwnerAction(ConfirmOwnerActionReply(outcome: .auditUnwritable))
        }
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
    /// first answers a request without a password with its own description
    /// of the code, which the CLI shows above the password prompt, then
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
    /// matched against this request (the exact command text the hook
    /// denied, cwd, payload digest, code), shown in full or not at all, so
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
        // only here; it must also equal the digest rvd issued.
        if let digest = params.payloadDigest {
            guard ContentPayloadDigest(validatingHex: digest.rawValue) != nil else {
                return denied()
            }
        }
        // Both platforms: only a code rvd issued, matching every field.
        let description: String
        switch await redemptionDescription(params) {
        case .notIssued:
            return .error(.allowOnceNotFound)
        case .notShowable:
            // Never a shortened command: the grant covers all of it.
            return .attestTTYRedemption(AttestTTYRedemptionReply(
                planted: false, epoch: grants.epoch.uuidString,
                ownerCheck: ConfirmOwnerActionReply(outcome: .unavailable), notShowable: true))
        case .found(_, redeemed: true):
            // Already planted in this rvd lifetime: answer the retry
            // without a second prompt.
            return .attestTTYRedemption(AttestTTYRedemptionReply(
                planted: false, epoch: grants.epoch.uuidString))
        case .found(let text, redeemed: false):
            description = text
        }
        let verdict = await ownerPresence.confirmRedemption(
            description, proof: params.ownerProof, context: context)
        if case .denied(let reply) = verdict, reply.outcome == .proofRequired {
            // Linux, no password yet: no owner check ran. Hand back rvd's
            // description for the CLI to show above the password prompt.
            return .attestTTYRedemption(AttestTTYRedemptionReply(
                planted: false, epoch: grants.epoch.uuidString, ownerCheck: reply,
                promptText: description))
        }
        let approved = verdict == .approved
        let outcome: String
        switch verdict {
        case .approved: outcome = ConfirmOwnerActionReply.Outcome.approved.rawValue
        case .denied(let reply): outcome = reply.outcome.rawValue
        }
        // The audit names the redeem, never the command: the audit log is a
        // same-user file, like the pending file that keeps only its head.
        let recorded = await OwnerPresence.audit(
            summary: "redeem allow-once code", approved: approved, outcome: outcome,
            context: context, home: configHome)
        if case .denied(let reply) = verdict {
            // The owner check ran and refused: tell the CLI why.
            return .attestTTYRedemption(AttestTTYRedemptionReply(
                planted: false, epoch: grants.epoch.uuidString, ownerCheck: reply))
        }
        // An approval rvd could not record plants nothing.
        guard recorded else {
            return .attestTTYRedemption(AttestTTYRedemptionReply(
                planted: false, epoch: grants.epoch.uuidString,
                ownerCheck: ConfirmOwnerActionReply(outcome: .auditUnwritable)))
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
                planted: true, epoch: grants.epoch.uuidString,
                presence: ownerPresence.promptsItself ? .daemonPrompt : .password
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

    /// `rv allow-once mint`: pre-arms one code for the exact command the
    /// owner typed, after the same owner check as redeem, with a prompt
    /// naming the whole command and cwd (escaped, never cut). rvd remembers
    /// the code in memory like a deny code, so the later redeem raises its
    /// prompt naming the command; an rvd restart loses it. A coding agent
    /// that reaches this request itself gets only a prompt the owner did
    /// not ask for, and minting alone grants nothing. The audit names the
    /// pre-arm, never the command.
    private func mintAllowOnce(
        _ params: MintAllowOnceParams, context: AuthenticatedRequestContext
    ) async -> IPCResult {
        let command = ShellCommand(rawValue: params.command)
        let view = Normalize.matchingView(of: command)
        guard view.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return .error(.authorizationDenied)
        }
        guard let shown = AllowOncePromptText.reason(command: params.command, cwd: params.cwd, ruleID: nil)
        else {
            return .mintAllowOnce(MintAllowOnceReply(
                ownerCheck: ConfirmOwnerActionReply(outcome: .unavailable), notShowable: true))
        }
        let description = "pre-arm a code to " + shown
        let verdict = await ownerPresence.confirmRedemption(
            description, proof: params.ownerProof, context: context)
        if case .denied(let reply) = verdict, reply.outcome == .proofRequired {
            return .mintAllowOnce(MintAllowOnceReply(ownerCheck: reply, promptText: description))
        }
        let outcome: String
        switch verdict {
        case .approved: outcome = ConfirmOwnerActionReply.Outcome.approved.rawValue
        case .denied(let reply): outcome = reply.outcome.rawValue
        }
        let recorded = await OwnerPresence.audit(
            summary: "pre-arm allow-once code", approved: verdict == .approved, outcome: outcome,
            context: context, home: configHome)
        if case .denied(let reply) = verdict {
            return .mintAllowOnce(MintAllowOnceReply(ownerCheck: reply))
        }
        // An approval rvd could not record mints nothing.
        guard recorded else {
            return .mintAllowOnce(MintAllowOnceReply(ownerCheck: ConfirmOwnerActionReply(outcome: .auditUnwritable)))
        }
        do {
            let code = try await allowOnce.mintPreArmed(
                matchingView: view,
                cwd: params.cwd,
                now: clock(),
                maskedSegments: Normalize.maskedSegments(of: command),
                invocationPrefix: Normalize.invocationPrefix(of: command),
                invocationDisplay: Normalize.invocationDisplay(of: command),
                rawCommand: params.command)
            return .mintAllowOnce(MintAllowOnceReply(code: code.rawValue))
        } catch AllowOnceError.alreadyPending {
            return .mintAllowOnce(MintAllowOnceReply(alreadyPending: true))
        } catch {
            return .error(.authorizationDenied)
        }
    }

    private enum RedemptionLookup: Equatable {
        /// rvd has nothing it can vouch for: no prompt is shown.
        case notIssued
        /// rvd knows the code but cannot show all of it: no prompt is shown.
        case notShowable
        case found(String, redeemed: Bool)
    }

    /// rvd's own prompt text for this redeem.
    ///
    /// The only source is a code rvd issued, on a hook deny or on an
    /// owner-approved `rv allow-once mint`: rvd kept the exact command text
    /// in memory, and every field of the request must match what it issued.
    /// A row in the same-user pending file that rvd did not issue (written
    /// by the agent, or from before an rvd restart) is not found, whatever
    /// the caller's role: rvd cannot vouch for its text.
    private func redemptionDescription(_ params: AttestTTYRedemptionParams) async -> RedemptionLookup {
        guard let issued = await allowOnce.issued(codeHash: params.codeHash.rawValue, now: clock()),
            issued.fingerprint == params.fingerprint, issued.cwd == params.cwd,
            issued.payloadDigest == params.payloadDigest
        else { return .notIssued }
        guard let command = issued.command,
            let text = AllowOncePromptText.reason(
                command: command, cwd: issued.cwd, ruleID: issued.ruleID, code: issued.code.rawValue)
        else { return .notShowable }
        return .found(text, redeemed: issued.redeemed)
    }

    public func evaluate(_ request: EvaluationRequest, cwd: WorkingDirectory? = nil) async -> EvaluateReply {
        let verdict = await runEvaluate(request, cwd: cwd)
        // Under observe, what enforce would have returned, only when it
        // differs from the observed allow (as `rv test` shows it).
        return EvaluateReply(
            result: verdict.result,
            wouldBe: verdict.observeOverrode ? verdict.wouldBe?.result : nil
        )
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
        let reply = EvaluateReply(result: await JudgeOffload.$judgeBudget.withValue(JudgeOffload.nonHookBudget) {
            await JudgeOffload.run {
                gated.evaluateAgent(request, cwd: params.cwd, home: home)
            }
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
            let tap = HookDecisionTap()
            // One id per call, minted before evaluation: the ledger row the
            // effects write and the decision-log row share it, and a watch
            // mode would-be is noted on it.
            let call = DecisionCall()
            let reply = try await DecisionCall.$current.withValue(call) { try await HookDoor.run(
                host: params.host,
                stdin: params.stdin,
                world: tap.tapping(HookEvaluateWorld.live(
                    world: readyWorld(
                        wanted: EvaluationWorld.walkedPackIDs(home: configHome)
                    ),
                    host: params.host,
                    pending: pendingApprovals,
                    clock: clock,
                    recordDecision: analyticsRecorder()
                ), host: params.host, clock: clock),
                deadline: deadline
            ) }
            // Once, after the reply is final; off the reply's path.
            tap.publish(to: events, timedOut: deadline.requiresTimeoutReply, home: configHome)
            // The decision log reads the same capture, also detached.
            if let decisionLog, let capture = tap.capture {
                decisionLog.record(capture, timedOut: deadline.requiresTimeoutReply, call: call)
            }
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
    ) async -> GatedVerdict {
        let scoped = ownerScoped(request)
        let world = readyWorld(wanted: WalkedPackIDs(ids: scoped.enabledPacks))
        // No hook deadline on this door: bound the judge alone (see
        // `JudgeOffload.nonHookBudget`); pattern search keeps its own ceiling.
        let verdict = await JudgeOffload.$judgeBudget.withValue(JudgeOffload.nonHookBudget) {
            await world.applyVerdict(scoped, cwd: cwd, host: host)
        }
        recordAnalytics(for: verdict.result)
        return verdict
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
        let spool = hookLocalSpool
        return { result in
            Self.recordAnalytics(result, analytics: analytics, enabledPackIDs: packs, spool: spool)
        }
    }

    private func recordAnalytics(for result: EvaluationResult) {
        Self.recordAnalytics(
            result,
            analytics: analytics,
            enabledPackIDs: compileSet.analyticsEnabledPackIDs,
            spool: hookLocalSpool
        )
    }

    /// Starts draining the hook-local spool every minute, so its rows and
    /// the daily analytics flush do not wait for rvd to evaluate something.
    /// rvd calls it once at launch.
    public nonisolated func startHookLocalSpoolTimer() {
        hookLocalSpool?.startTimer()
    }

    /// Counts `result` and asks for a drain of the hook-local spool (a
    /// non-blocking request: the drain runs on its own queue, one at a time).
    private static func recordAnalytics(
        _ result: EvaluationResult,
        analytics: AnalyticsCoordinator?,
        enabledPackIDs: [String],
        spool: HookLocalSpoolDrainer?
    ) {
        spool?.request()
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
        let world = readyWorld(wanted: WalkedPackIDs(ids: request.enabledPacks))
        let result = await JudgeOffload.$judgeBudget.withValue(JudgeOffload.nonHookBudget) {
            await world.peek(request, cwd: cwd)
        }
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
        let world = readyWorld(wanted: WalkedPackIDs(ids: request.enabledPacks))
        let result = await JudgeOffload.$judgeBudget.withValue(JudgeOffload.nonHookBudget) {
            await world.peek(request, cwd: cwd)
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

    private func doctorSnapshot(pool: JudgePoolProbe) -> DoctorSnapshotReply {
        DoctorSnapshotBuilder.make(
            catalog: compileSet.refreshCatalogFromDisk(),
            corePacksReady: corePacksReady,
            idleExitSeconds: idleExitSeconds,
            home: configHome,
            judgePool: pool
        )
    }

    /// The typed-policy load hooks run (`PolicyStoreInputs`), for rvd's
    /// HOME and the caller's cwd. Off the actor and the cooperative pool,
    /// capped (`PolicyStatusService`): a ceiling containment check over a
    /// large repo layer can take seconds, and hook evaluations must not
    /// queue behind it.
    private func policyStatus(_ params: PolicyStatusParams) async -> PolicyStatusReply {
        await policyStatusService.status(home: configHome, cwd: params.cwd)
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
        case .policyStatus:
            method = "policyStatus"
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
        case .mintAllowOnce:
            method = "mintAllowOnce"
        case .events:
            method = "events"
        case .proposeLoosen:
            method = "proposeLoosen"
        case .listProposals:
            method = "listProposals"
        case .decideProposal:
            method = "decideProposal"
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
