#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVIPC
import Synchronization

/// In-memory admission evidence. The shell records the final outcome before
/// it returns, so the snapshot always holds the event; a failed file append
/// is diagnosed on stderr by `appendAdmissionEvent` instead of vanishing.
public final class RuntimeAdmissionEvidence: Sendable {
    private let events = Mutex<[RuntimeAdmissionEvent]>([])
    private let file: URL?

    public init(appendingTo file: URL? = nil) {
        self.file = file
    }

    /// `$HOME/.config/rv/runtime-admission.jsonl`, beside the session start log.
    public static func productionFile() -> URL? {
        guard let home = ProcessInfo.processInfo.environment["HOME"],
            home.hasPrefix("/"), home.contains("\0") == false
        else {
            return nil
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("rv", isDirectory: true)
            .appendingPathComponent("runtime-admission.jsonl", isDirectory: false)
    }

    public func record(_ event: RuntimeAdmissionEvent) {
        events.withLock { $0.append(event) }
        if let file {
            var stamped = event
            stamped.recordedAt = Date().timeIntervalSince1970
            appendAdmissionEvent(stamped, to: file)
        }
    }

    public func snapshot() -> [RuntimeAdmissionEvent] {
        events.withLock { $0 }
    }
}

/// How an authorized action is performed. The contained agent is not a case.
public enum RuntimeAdmissionExecutor: Sendable {
    /// No spawn and no side effect.
    case refuse
    /// Seatbelt the compiled argv in RV's process, without a second runtime session.
    case containedCommand
    /// Test and caller-supplied side effect. Invoked only after authorization.
    case effect(@Sendable (AllowedAction) -> Result<Int32, RuntimeAdmissionExecutorError>)
}

/// Cooperative cancel for one HTTPS GET. `finish` on the runtime sets it.
public final class HTTPCancellation: Sendable {
    private let state = Mutex(false)

    public init() {}

    public func cancel() {
        state.withLock { $0 = true }
    }

    public var isCancelled: Bool {
        state.withLock { $0 }
    }
}

/// How an authorized HTTPS GET is performed. The contained agent is not a case.
public enum RuntimeHTTPExecutor: Sendable {
    /// No socket and no HTTP exchange.
    case refuse
    /// Caller-supplied transfer. Invoked only after authorization.
    case effect(
        @Sendable (
            HTTPAction, HTTPCancellation, @escaping @Sendable () -> Bool
        ) -> Result<HTTPExecutionReceipt, HTTPEgressFailure>
    )
    /// Caller-supplied transfer receiving the broker's granted injection as
    /// an argument. Invoked only after authorization, like `.effect`; the
    /// injection rides with the exact action being performed, so the
    /// transfer correlates without a request-ID lookup. Nil whenever the
    /// broker is unconfigured or withholds.
    case effectWithCredential(
        @Sendable (
            HTTPAction, BrokeredCredentialInjection?, HTTPCancellation,
            @escaping @Sendable () -> Bool
        ) -> Result<HTTPExecutionReceipt, HTTPEgressFailure>
    )
    /// Dial the pinned public address from RV, with no proxy and no cookies.
    case direct
}

extension RuntimeHTTPExecutor {
    /// Transports that receive a granted injection as an argument rather
    /// than through the legacy delivery hook.
    var deliversCredentialAsArgument: Bool {
        switch self {
        case .direct, .effectWithCredential:
            return true
        case .refuse, .effect:
            return false
        }
    }
}

public struct RuntimeAdmissionConfiguration: Sendable {
    public var normalize:
        @Sendable (RuntimeAdmissionSubject, RuntimeRequestedAction) -> Result<
            ProposedAction, RuntimeAdmissionEvaluationError
        >
    public var executor: RuntimeAdmissionExecutor
    public var http: RuntimeHTTPExecutor
    public var approval:
        @Sendable (RuntimeActionRequestID, PendingAuthorization) -> Result<
            ApprovalDecision, AgentApprovalError
        >?
    public var policy: @Sendable (RuntimeSession) -> EffectiveActionPolicy
    public var evidence: RuntimeAdmissionEvidence
    /// Step 6 principal-bound approval driver. Nil (the default) keeps the
    /// pre-Step-6 behavior: ASK outcomes pend without a human path. When
    /// set, the session parks pending ASKs for a human decision and resumes
    /// the exact parked continuation at most once.
    public var askBackend: (any ActionApprovalAsking)?
    /// Phase 5 supervisor-side credential broker. Nil (the default) keeps
    /// the pre-broker behavior: no consultation, no broker audit events.
    /// When set, each authorized HTTP action consults the broker for an
    /// approved-endpoint injection; the value resolves in host memory only
    /// and is passed as an argument to the performing transport, never to
    /// the cage.
    public var credentialBroker: ContainedCredentialBroker?
    /// Supervisor-side delivery for a granted injection on transports that
    /// do not take it as an argument (legacy `.effect`, `.refuse`), and an
    /// observer tap otherwise. Nil (the default) drops the grant
    /// fail-closed with a `credentialUnwired` audit event on hook-delivered
    /// transports; `.direct` and `.effectWithCredential` receive the
    /// injection as a return-value argument whether or not a hook is set.
    public var credentialDelivery: (@Sendable (BrokeredCredentialInjection) -> Void)?

    public init(
        normalize: @escaping @Sendable (RuntimeAdmissionSubject, RuntimeRequestedAction) -> Result<
            ProposedAction, RuntimeAdmissionEvaluationError
        >,
        executor: RuntimeAdmissionExecutor,
        http: RuntimeHTTPExecutor = .refuse,
        approval: @escaping @Sendable (RuntimeActionRequestID, PendingAuthorization) -> Result<
            ApprovalDecision, AgentApprovalError
        >?,
        policy: @escaping @Sendable (RuntimeSession) -> EffectiveActionPolicy,
        evidence: RuntimeAdmissionEvidence,
        askBackend: (any ActionApprovalAsking)? = nil,
        credentialBroker: ContainedCredentialBroker? = nil,
        credentialDelivery: (@Sendable (BrokeredCredentialInjection) -> Void)? = nil
    ) {
        self.normalize = normalize
        self.executor = executor
        self.http = http
        self.approval = approval
        self.policy = policy
        self.evidence = evidence
        self.askBackend = askBackend
        self.credentialBroker = credentialBroker
        self.credentialDelivery = credentialDelivery
    }

    public static var failClosed: RuntimeAdmissionConfiguration {
        RuntimeAdmissionConfiguration(
            normalize: { _, _ in .failure(.failed) },
            executor: .refuse,
            http: .refuse,
            approval: { _, _ in nil },
            policy: { _ in .empty },
            evidence: RuntimeAdmissionEvidence()
        )
    }
}

// MARK: - Phase 5 credential broker

/// Supervisor-side credential broker. OpenShell `provider_credentials`
/// mirror: the SecretResolver stays in the supervisor; secret values live
/// in host memory and resolve only for approved (credential, endpoint)
/// pairs. Only non-secret prepared entries cross into the cage
/// environment; secret values are delivered only to supervisor-side
/// injection points, never over the pipes, never into logs.
///
/// The cage cannot address credentials at all: there is no credential wire
/// type. A grant is exercised when the cage's ordinary HTTP request rides
/// the existing admission pipes — capability binding and replay protection
/// are the gate's, unchanged — and the session consults the broker for the
/// authorized destination before performing it. Denied, pending, and
/// non-HTTP actions never consult the broker, so an unauthenticated cage
/// learns nothing about broker configuration.
public struct ContainedCredentialBroker: Sendable, Equatable {
    /// Whether the value may be injected supervisor-side or may cross as a
    /// non-secret prepared entry. Never both.
    public enum ValueKind: Sendable, Equatable {
        /// Injected supervisor-side at approved endpoints only. Never
        /// crosses into the cage environment.
        case secret
        /// Non-secret pointer (profile name, key id). May cross as a
        /// prepared entry; never resolved as an injection.
        case selector
    }

    public struct Credential: Sendable, Equatable {
        public var value: String
        public var kind: ValueKind
        public var approvedHosts: Set<String>
        /// Secrets only: mint a non-secret `rv-brokered:` placeholder entry
        /// so cage tools select key auth. Default false: even the
        /// placeholder is deny-by-default.
        public var placeholder: Bool

        public init(
            value: String,
            kind: ValueKind,
            approvedHosts: Set<String>,
            placeholder: Bool = false
        ) {
            self.value = value
            self.kind = kind
            self.approvedHosts = Set(approvedHosts.map { $0.lowercased() })
            self.placeholder = placeholder
        }
    }

    /// Audit generation correlating grants, placeholders, and evidence.
    /// Audit-only in Phase 5: no rotation logic reads it.
    public var revision: UInt64
    var credentials: [String: Credential]
    /// Endpoint routing: lowercased host to credential name.
    var grants: [String: String]

    public init(
        credentials: [String: Credential],
        grants: [String: String],
        revision: UInt64 = 0
    ) {
        self.revision = revision
        self.credentials = credentials
        var folded: [String: String] = [:]
        for (host, name) in grants {
            folded[host.lowercased()] = name
        }
        self.grants = folded
    }

    /// Names-only audit surface. Values are never enumerated.
    public var credentialNames: [String] {
        credentials.keys.sorted()
    }

    /// Non-secret entries the supervisor may apply after the environment
    /// strip. Selectors cross with their value; secrets cross only as a
    /// `rv-brokered:<name>@<revision>` marker when they opt into a
    /// placeholder — the marker carries the name and revision only.
    /// Malformed names, insane values, and non-credential-class names are
    /// dropped fail-closed. Sorted by name.
    public func preparedEntries() -> [BrokerPreparedEntry] {
        var entries: [BrokerPreparedEntry] = []
        for name in credentials.keys.sorted() {
            guard let credential = credentials[name],
                ContainedEnvironmentPolicy.isCredentialClass(name)
            else {
                continue
            }
            switch credential.kind {
            case .selector:
                guard ContainedEnvironmentPolicy.isValidName(name),
                    ContainedEnvironmentPolicy.isSaneValue(credential.value)
                else {
                    continue
                }
                entries.append(BrokerPreparedEntry(name: name, value: credential.value))
            case .secret:
                guard credential.placeholder else { continue }
                let marker = "rv-brokered:\(name)@\(revision)"
                guard ContainedEnvironmentPolicy.isValidName(name),
                    ContainedEnvironmentPolicy.isSaneValue(marker)
                else {
                    continue
                }
                entries.append(BrokerPreparedEntry(name: name, value: marker))
            }
        }
        return entries
    }

    /// Resolves a supervisor-side injection for one authorized destination
    /// host. Grants only when the endpoint routing names a credential AND
    /// that credential approves the host; either side missing withholds.
    /// Host comparison is case-insensitive; destinations here are already
    /// canonicalized lowercase by the HTTP layer.
    func resolve(host: String) -> BrokerResolution {
        let key = host.lowercased()
        guard let name = grants[key] else {
            return .withheld(.endpointNotApproved)
        }
        guard let credential = credentials[name] else {
            return .withheld(.credentialMissing)
        }
        guard credential.kind == .secret else {
            return .withheld(.credentialNotSecret)
        }
        guard credential.approvedHosts.contains(key) else {
            return .withheld(.endpointNotApproved)
        }
        return .granted(
            BrokeredCredentialInjection(credentialName: name, host: key, value: credential.value)
        )
    }
}

/// Supervisor-side injection resolved for one authorized HTTP action.
/// Host memory only: passed as an argument to the performing transport
/// (and to the legacy `credentialDelivery` tap when one is set), never
/// encoded, never logged, never sent over the pipes. Public so
/// supervisor-side transports in other modules can consume it; the cage
/// is a separate process and cannot reach host-side Swift state at all.
public struct BrokeredCredentialInjection: Sendable, Equatable {
    public var credentialName: String
    public var host: String
    public var value: String

    public init(credentialName: String, host: String, value: String) {
        self.credentialName = credentialName
        self.host = host
        self.value = value
    }
}

/// Why the broker withheld an injection. Names-only audit vocabulary.
enum BrokerWithheldReason: String, Sendable, Equatable {
    case endpointNotApproved
    case credentialMissing
    case credentialNotSecret
}

enum BrokerResolution: Sendable, Equatable {
    case granted(BrokeredCredentialInjection)
    case withheld(BrokerWithheldReason)
}

/// Plan and profile RV already compiled for this launch.
struct AdmittedLaunchContext: Sendable, Equatable {
    var plan: ContainedPlan
    var profileSource: String
    /// Provenance of `profileSource`: true only when the text came from
    /// `compileFirstSliceProfile`. The admitted-spawn gate refuses on this
    /// flag instead of scanning the text; hand-built contexts stay false
    /// and fail closed.
    var profileIsContainedCompilerOutput: Bool = false
    var workspacePath: String
    /// Process that owns this runtime. `-1` when the caller is not a session.
    /// An admitted command stops if this process has exited.
    var sessionLeader: pid_t = -1
    /// Workspace egress proxy port, when the owning runtime has one.
    var egressProxyPort: Int? = nil
    /// Owning runtime's productive-workspace facts, so each admitted
    /// command reuses them instead of re-resolving (probes plus
    /// idempotent `ensure`) per command.
    var productive: ProductiveWorkspaceResolution? = nil
}

/// One ASK parked for a human decision (Step 6). Host memory only.
private struct ParkedApproval: Sendable {
    /// Service-minted correlation. Grants nothing by possession.
    var approval: CreatedActionApproval
    /// The gate's exact pending for this request: action, reason, deny,
    /// explanation. Bound at park time; resume and deny derive here.
    var pending: PendingAuthorization
    var requestID: RuntimeActionRequestID
    var waiter: Task<Void, Never>?
}

/// A waiter's finished answer, queued for the watch thread to write.
private struct ParkedCompletion: Sendable {
    var response: RuntimeAdmissionResponse
    var event: RuntimeAdmissionEvent
}

/// Request-keyed capture of gate pendings for exact parking.
///
/// The gate calls the wrapped approval closure with (requestID, pending);
/// the submit wrapper takes exactly one pending per submit. Production
/// submits are watch-thread serialized per channel, so capture→take is
/// exact there; a take-miss (only under concurrent same-ID misuse) fails
/// closed to legacy pending, and a fingerprint cross-check in the wrapper
/// refuses to park a capture that does not belong to its decision.
private final class PendingCaptureBox: @unchecked Sendable {
    private let box = Mutex<[RuntimeActionRequestID: PendingAuthorization]>([:])

    func capture(_ id: RuntimeActionRequestID, _ pending: PendingAuthorization) {
        box.withLock { $0[id] = pending }
    }

    func take(_ id: RuntimeActionRequestID) -> PendingAuthorization? {
        box.withLock { $0.removeValue(forKey: id) }
    }
}

/// One runtime's admission state.
///
/// The request pipe is the channel. `RuntimeSessionID` is only the name the
/// claim must match. `close()` makes later bytes, including a copied
/// capability, unable to execute.
final class RuntimeAdmissionSession: Sendable {
    /// Upper bound on simultaneously parked ASKs per channel. A runtime
    /// awaiting more humans than this is pathological; beyond the cap ASKs
    /// keep the legacy pending-forever behavior instead of piling waiters
    /// (and status RPCs) onto the service.
    private static let maxParkedPerChannel = 8

    private let state: Mutex<ChannelState>
    private let configuration: RuntimeAdmissionConfiguration
    private let subject: RuntimeAdmissionSubject
    private let launch: AdmittedLaunchContext
    private let capture = PendingCaptureBox()
    /// Waiter status-poll interval. Production default 1s; tests inject less.
    private let parkPollInterval: TimeInterval
    /// Waiter overall bound. Production default 20min (past the 15min
    /// service TTL plus margin); tests inject less. The service TTL ends
    /// honest waits first; this bounds transport-dead spins.
    private let parkTimeout: TimeInterval

    private struct ChannelState: Sendable {
        var binding: RuntimeChannelBinding?
        var buffer = Data()
        var requestRead: Int32
        var responseWrite: Int32
        var httpToken: HTTPCancellation?
        var stop = false
        /// Live registry that resolves the trusted principal context. Set
        /// together with the channel's instance binding; nil on legacy
        /// channels, which keep the pre-identity behavior.
        var agentRegistry: AgentInstanceRegistry? = nil
        /// Step 6 parked ASKs awaiting a human decision, by request ID.
        /// Host memory only: the agent never sees approval or continuation
        /// IDs, and no resume path exists except each record's waiter.
        var parked: [RuntimeActionRequestID: ParkedApproval] = [:]
        /// Park slots reserved while the service-side approval is created.
        /// Lets the cap check, the duplicate check, and the insert stay
        /// atomic under one lock instead of spanning three.
        var parking: Set<RuntimeActionRequestID> = []
        /// Finished waiter answers queued for the pre-existing writer paths.
        /// Bytes are only ever written by `acceptBuffered`'s drain, so
        /// parking introduces no new file-descriptor races.
        var completions: [ParkedCompletion] = []
    }

    /// Binds this channel to an announced Agent Instance.
    ///
    /// Called once by the workspace host after announcing the launch attempt,
    /// while the child image is still stopped, so no request can arrive
    /// before the binding exists. Refuses to rebind: an established binding
    /// never moves to another instance. Every later submit resolves the
    /// trusted context fresh from the registry; a cached context is never
    /// reused, so revocation takes effect on the next request.
    func bindAgentInstance(_ id: AgentInstanceID, registry: AgentInstanceRegistry) -> Bool {
        state.withLock { channel in
            guard var binding = channel.binding, binding.agentInstanceID == nil else {
                return false
            }
            binding.agentInstanceID = id
            channel.binding = binding
            channel.agentRegistry = registry
            return true
        }
    }

    init(
        binding: RuntimeChannelBinding,
        configuration: RuntimeAdmissionConfiguration,
        launch: AdmittedLaunchContext,
        requestRead: Int32,
        responseWrite: Int32,
        parkPollInterval: TimeInterval = 1,
        parkTimeout: TimeInterval = 20 * 60
    ) {
        state = Mutex(
            ChannelState(
                binding: binding,
                requestRead: requestRead,
                responseWrite: responseWrite
            )
        )
        self.configuration = configuration
        self.subject = RuntimeAdmissionSubject(
            session: binding.session,
            policyWorkspace: launch.plan.workspace
        )
        self.launch = launch
        self.parkPollInterval = parkPollInterval
        self.parkTimeout = parkTimeout
    }

    func sendGrant() {
        let snapshot = state.withLock { ($0.binding, $0.responseWrite) }
        guard let binding = snapshot.0, snapshot.1 >= 0 else { return }
        guard case .success(let frame) = RuntimeAdmissionCodec.encodeGrant(
            capability: binding.capability,
            session: binding.session.id.rawValue
        ) else {
            return
        }
        _ = admissionWriteAll(snapshot.1, frame)
    }

    /// Reads whatever is currently available. A finished session drops bytes.
    func service() {
        guard state.withLock({ $0.binding?.phase == .active }) else {
            state.withLock { $0.buffer.removeAll() }
            return
        }
        let fd = state.withLock { $0.requestRead }
        if fd >= 0 {
            let bytes = admissionReadAvailable(fd)
            state.withLock { $0.buffer.append(bytes) }
        }
        _ = acceptBuffered()
    }

    /// Test entry for bytes that did not come from the granted pipe.
    @discardableResult
    func accept(_ data: Data) -> [RuntimeAdmissionDecision] {
        state.withLock { $0.buffer.append(data) }
        return acceptBuffered()
    }

    /// Legacy capability-only mediation (Step 8 F3). Principal-less
    /// channels authenticate on channel facts; bound channels still get
    /// principal binding-match and liveness checks. Sensitive operations
    /// must use `submitIdentityRequired`, never this door.
    @discardableResult
    func submitLegacy(
        _ frame: Result<RuntimeActionFrame, RuntimeAdmissionDecodeError>
    ) -> RuntimeAdmissionDecision {
        submitCore(frame, principalRequired: false)
    }

    /// Identity-required privileged mediation (Step 8 F3). Sensitive
    /// operations enter here, never via `submitLegacy`: a legacy binding
    /// that names no principal is rejected with `.principalRequired`
    /// before any policy or execution work, and only a freshly resolved
    /// usable trusted context reaches the gate. Future Secrets/MCP
    /// mediation must use this door.
    @discardableResult
    func submitIdentityRequired(
        _ frame: Result<RuntimeActionFrame, RuntimeAdmissionDecodeError>
    ) -> RuntimeAdmissionDecision {
        submitCore(frame, principalRequired: true)
    }

    private func submitCore(
        _ frame: Result<RuntimeActionFrame, RuntimeAdmissionDecodeError>,
        principalRequired: Bool
    ) -> RuntimeAdmissionDecision {
        // Snapshot binding and registry together: two separate locks could
        // pair a pre-bind channel with a post-bind registry or vice versa.
        let snapshot = state.withLock { ($0.binding, $0.agentRegistry) }
        var binding = snapshot.0
        let registry = snapshot.1
        // Fresh trusted context for every submit: resolving once and caching
        // would let a revoked principal act on a stale snapshot.
        let agentContext = binding.flatMap { registry?.context(forBinding: $0) }
        var subject = subject
        subject.agent = agentContext
        let leader = launch.sessionLeader
        // Capture the gate's exact pending per request when parking is
        // armed, so the park binds precisely what the gate decided — no
        // re-normalization, no TOCTOU between decision and approval. The
        // configured closure still makes the synchronous decision; capture
        // only retains it for the wrapper below.
        let approvalFor: @Sendable (RuntimeActionRequestID, PendingAuthorization) -> Result<
            ApprovalDecision, AgentApprovalError
        >?
        if configuration.askBackend != nil {
            let configured = configuration.approval
            let captureBox = capture
            approvalFor = { requestID, pending in
                captureBox.capture(requestID, pending)
                return configured(requestID, pending)
            }
        } else {
            approvalFor = configuration.approval
        }
        let gateEntry = principalRequired
            ? RuntimeAdmissionGate.submitIdentityRequired
            : RuntimeAdmissionGate.submitLegacy
        let decision = gateEntry(
            &binding,
            frame,
            configuration.policy(subject.session),
            approvalFor,
            agentContext,
            { [configuration, subject] accepted in
                RuntimeAdmissionStop.$shouldStop.withValue({
                    #if os(macOS)
                    if sessionLeaderHasExited(leader) { return true }
                    #endif
                    return blockingWorkIsCancelled()
                }) {
                    configuration.normalize(subject, accepted.action)
                }
            }
        )
        state.withLock { channel in
            if channel.stop {
                binding?.phase = .finished
            }
            // Only auth state (consumed sets, phase) flows back. Identity
            // fields never change via the gate, so a binding installed
            // after this submit snapshotted must survive the write-back
            // rather than be clobbered to the pre-bind snapshot.
            if binding?.agentInstanceID == nil {
                binding?.agentInstanceID = channel.binding?.agentInstanceID
            }
            channel.binding = binding
        }
        if let parked = tryParkApproval(
            frame: frame, decision: decision, agentContext: agentContext, binding: binding) {
            // The pending event is recorded exactly as the legacy path
            // records it; the waiter's eventual answer records a second,
            // outcome event. Callers must not write the superseded
            // pending projection: `responseDeferred` says so.
            configuration.evidence.record(parked.event)
            return parked
        }
        guard let allowed = decision.execute, binding?.phase == .active else {
            if decision.execute != nil {
                let inactive = inactiveDecision(binding: binding, event: decision.event)
                configuration.evidence.record(inactive.event)
                return inactive
            }
            configuration.evidence.record(decision.event)
            return decision
        }
        let consult = consultCredentialBroker(for: allowed, base: decision.event)
        if let brokerEvent = consult.event {
            configuration.evidence.record(brokerEvent)
        }
        let performed = perform(allowed, credential: consult.injection)
        var event = decision.event
        let response = admissionResponse(performed, event: &event)
        configuration.evidence.record(event)
        return RuntimeAdmissionDecision(
            binding: binding,
            response: response,
            event: event,
            execute: nil
        )
    }

    // MARK: - Step 6 parked approvals

    /// Parks a pending ASK for a human decision. Returns the deferred
    /// decision, or nil to keep the legacy path. Every doubt fails closed
    /// to legacy pending (no approval, no park, callers answer as before).
    private func tryParkApproval(
        frame: Result<RuntimeActionFrame, RuntimeAdmissionDecodeError>,
        decision: RuntimeAdmissionDecision,
        agentContext: AuthenticatedAgentContext?,
        binding: RuntimeChannelBinding?
    ) -> RuntimeAdmissionDecision? {
        guard let backend = configuration.askBackend,
            decision.execute == nil,
            case .pending(let ledgerReason) = decision.response,
            ledgerReason != .hostAsk,
            case .success(let accepted) = frame,
            // Consume this request's capture exactly once, before any other
            // check: a capture left behind by a refused park would leak one
            // entry per unparked pending submit.
            let pending = capture.take(accepted.requestID),
            binding?.phase == .active,
            let agentContext, agentContext.isUsable,
            // The capture must belong to THIS decision: same pending
            // reason the gate projected, same action fingerprint. Under
            // concurrent same-ID misuse (already broken pre-Step-6: the
            // gate would double-authorize), a mismatch refuses to park
            // instead of binding the wrong action.
            pending.reason.ledgerReason == ledgerReason,
            decision.event.fingerprint == pending.action.fingerprint.rawValue,
            // Reserve the slot under ONE lock: the cap check and the
            // duplicate check are atomic with the reservation, so two
            // concurrent submits can never both pass the checks and
            // over-park. Last in the chain: nothing after it can fail
            // and leak the reservation.
            reserveParkSlot(for: accepted.requestID)
        else {
            return nil
        }
        var parkedSubject = subject
        parkedSubject.agent = agentContext
        guard let created = backend.createApproval(
            subject: parkedSubject,
            action: pending.action,
            reason: pending.reason,
            policyContext: "runtime:\(subject.policyWorkspace.rawValue)"
        ) else {
            // No approval exists: legacy pending, exactly as before Step 6.
            releaseParkSlot(for: accepted.requestID)
            return nil
        }
        let requestID = accepted.requestID
        let admitted = state.withLock { channel -> Bool in
            channel.parking.remove(requestID)
            guard !channel.stop,
                channel.binding?.phase == .active,
                channel.parked[requestID] == nil,
                channel.parked.count < Self.maxParkedPerChannel
            else {
                return false
            }
            channel.parked[requestID] = ParkedApproval(
                approval: created, pending: pending, requestID: requestID, waiter: nil)
            return true
        }
        guard admitted else {
            // Lost a race, or the channel finished mid-approval: cancel
            // the orphaned service-side approval instead of parking it.
            backend.cancelApproval(created)
            return nil
        }
        let waiter = Task<Void, Never> { [weak self] in
            await self?.awaitParkedApproval(requestID: requestID)
        }
        state.withLock { $0.parked[requestID]?.waiter = waiter }
        var deferred = decision
        deferred.responseDeferred = true
        return deferred
    }

    /// Reserves one park slot under a single lock: the cap check, the
    /// duplicate check, and the reservation insert are atomic. The
    /// reservation converts to a park (or releases) in `tryParkApproval`
    /// once the service-side approval exists; `teardownParks` drops
    /// reservations that outlive the channel.
    private func reserveParkSlot(for requestID: RuntimeActionRequestID) -> Bool {
        state.withLock { channel in
            guard channel.parked.count + channel.parking.count < Self.maxParkedPerChannel,
                channel.parked[requestID] == nil,
                channel.parking.contains(requestID) == false
            else {
                return false
            }
            channel.parking.insert(requestID)
            return true
        }
    }

    private func releaseParkSlot(for requestID: RuntimeActionRequestID) {
        state.withLock { $0.parking.remove(requestID) }
    }

    /// Waits for one parked approval's human decision, off the watch thread.
    /// Polls safe status (never consuming) until the grant issues, then
    /// consumes exactly once for the exact parked continuation. Every
    /// terminal or doubtful outcome completes the park fail-closed; only a
    /// verified consumption resumes execution.
    private func awaitParkedApproval(requestID: RuntimeActionRequestID) async {
        guard let backend = configuration.askBackend else { return }
        let deadline = Date().addingTimeInterval(parkTimeout)
        let pollNanoseconds = UInt64(max(parkPollInterval, 0.001) * 1_000_000_000)
        while true {
            if Task.isCancelled { return }
            let take = state.withLock { channel -> (
                park: ParkedApproval?, binding: RuntimeChannelBinding?,
                registry: AgentInstanceRegistry?
            )? in
                guard !channel.stop, channel.binding?.phase == .active else { return nil }
                return (channel.parked[requestID], channel.binding, channel.agentRegistry)
            }
            // Unparked (torn down) or channel gone: finish() owns teardown;
            // nothing further to answer here.
            guard let take, let park = take.park else { return }
            // Step 8 (F3 re-review): fail a bound park as soon as its
            // principal dies instead of spinning to the deadline. The
            // approval can no longer be honestly consumed for this
            // instance, and resume revalidates again before executing.
            if let binding = take.binding, binding.agentInstanceID != nil {
                let live = take.registry.flatMap { registry in
                    registry.context(forBinding: binding)
                }
                guard let live, live.isUsable else {
                    backend.cancelApproval(park.approval)
                    failParked(requestID: requestID, park: park, cause: "principalRevoked")
                    return
                }
            }
            if Date() >= deadline {
                backend.cancelApproval(park.approval)
                failParked(requestID: requestID, park: park, cause: "approvalTimeout")
                return
            }
            // Transport blip: sleep and retry. The deadline bounds the wait;
            // service-side expiry turns honest waits terminal first.
            guard let status = backend.approvalStatus(park.approval) else {
                try? await Task.sleep(nanoseconds: pollNanoseconds)
                continue
            }
            // Exhaustive over the closed vocabulary: no default, so a new
            // status breaks this switch until classified. Undecodable wire
            // bytes never reach here (decode fails to nil above, which
            // polls on as a transport blip).
            switch status {
            case .pending, .awaitingAuthentication:
                try? await Task.sleep(nanoseconds: pollNanoseconds)
            case .authorized:
                if backend.consumeApproval(
                    park.approval,
                    actionDigestHex: CanonicalActionDigest.sha256Hex(of: park.pending.action)
                ) {
                    await resumeParked(requestID: requestID)
                } else {
                    failParked(requestID: requestID, park: park, cause: "approvalUnavailable")
                }
                return
            case .consumed:
                // Already spent without this waiter consuming (service-side
                // race or duplicate waiter, impossible by construction):
                // never execute here.
                failParked(requestID: requestID, park: park, cause: "approvalReplay")
                return
            case .denied:
                denyParked(requestID: requestID, park: park)
                return
            case .cancelled:
                failParked(requestID: requestID, park: park, cause: "approvalCancelled")
                return
            case .expired:
                failParked(requestID: requestID, park: park, cause: "approvalExpired")
                return
            case .invalidated:
                failParked(requestID: requestID, park: park, cause: "approvalInvalidated")
                return
            case .failed:
                failParked(requestID: requestID, park: park, cause: "approvalFailed")
                return
            case .unknown:
                // The ceremony forgot the terminal approval: fail closed
                // without executing.
                failParked(requestID: requestID, park: park, cause: "approvalUnknown")
                return
            }
        }
    }

    /// Resumes one consumed park: re-validates the channel, burns the
    /// fingerprint exactly like the gate, performs the exact parked action,
    /// and queues the answer. The grant is already spent; if the channel
    /// died in between, nothing runs and the burn is recorded. If the
    /// fingerprint is already spent (the action ran under another
    /// continuation), the resume answers the gate's replay rejection —
    /// never a second execution.
    private func resumeParked(requestID: RuntimeActionRequestID) async {
        struct Plan: Sendable {
            var park: ParkedApproval
            var binding: RuntimeChannelBinding
        }
        enum Take: Sendable {
            case plan(Plan)
            case replay(park: ParkedApproval, binding: RuntimeChannelBinding)
            case gone
        }
        let take: Take = state.withLock { channel in
            guard !channel.stop,
                var binding = channel.binding, binding.phase == .active,
                let park = channel.parked.removeValue(forKey: requestID)
            else { return .gone }
            // At-most-once, mirroring the gate: the fingerprint must still
            // be unconsumed. Burning before perform means a crash between
            // burn and perform loses the action instead of duplicating it.
            guard !binding.consumedFingerprints.contains(park.pending.action.fingerprint) else {
                return .replay(park: park, binding: binding)
            }
            binding.consumedFingerprints.insert(park.pending.action.fingerprint)
            channel.binding = binding
            return .plan(Plan(park: park, binding: binding))
        }
        switch take {
        case .gone:
            configuration.evidence.record(RuntimeAdmissionEvent(
                session: nil,
                requestID: requestID.rawValue.uuidString,
                fingerprint: nil,
                authorization: .approvalUnavailable,
                executionAttempted: false,
                result: "resumedButChannelGone"))
            return
        case .replay(let park, let binding):
            var event = baseEvent(
                binding: binding, park: park,
                authorization: .rejected, result: RuntimeAdmissionRejection.replay.rawValue)
            stamp(&event, agent: park.approval.subject.agent, binding: binding)
            configuration.evidence.record(event)
            enqueueCompletion(ParkedCompletion(
                response: .rejected(.replay), event: event))
            return
        case .plan(let plan):
            // Step 8 (F3 re-review): revalidate the principal at resume
            // time. The park captures the request only; if the instance
            // was revoked or died while awaiting the human, the approval
            // must not execute. Legacy principal-less channels proceed
            // as before. Residual: a revoke landing between this check
            // and spawn (microseconds of pure code) still executes —
            // inherent check-then-act, no attacker advantage (revoke is
            // defender-controlled), accepted.
            if plan.binding.agentInstanceID != nil {
                let registry = state.withLock { $0.agentRegistry }
                guard let registry,
                    let fresh = registry.context(forBinding: plan.binding),
                    fresh.isUsable
                else {
                    // The take above already removed the park, so complete
                    // here: failParked would find nothing and drop the
                    // answer. Evidence plus queued refusal, never execution.
                    var event = baseEvent(
                        binding: plan.binding, park: plan.park,
                        authorization: .approvalUnavailable, result: "principalRevoked")
                    stamp(&event, agent: plan.park.approval.subject.agent, binding: plan.binding)
                    configuration.evidence.record(event)
                    enqueueCompletion(ParkedCompletion(
                        response: .approvalUnavailable, event: event))
                    return
                }
            }
            let resolved = AgentAuthorization.resolve(
                plan.park.pending, approval: .success(.allowOnce))
            guard case .success(.allowed(let allowed)) = resolved else {
                // Unreachable: allowOnce always lifts a pending. Fail closed
                // with evidence if the impossible happens. The take above
                // already removed the park, so complete here directly.
                var event = baseEvent(
                    binding: plan.binding, park: plan.park,
                    authorization: .approvalUnavailable, result: "approvalUnavailable")
                stamp(&event, agent: plan.park.approval.subject.agent, binding: plan.binding)
                configuration.evidence.record(event)
                enqueueCompletion(ParkedCompletion(
                    response: .approvalUnavailable, event: event))
                return
            }
            // Outside the lock: perform spawns and blocks like the submit
            // path.
            var brokerBase = baseEvent(
                binding: plan.binding, park: plan.park,
                authorization: .allowed, result: "authorized")
            stamp(&brokerBase, agent: plan.park.approval.subject.agent, binding: plan.binding)
            let consult = consultCredentialBroker(for: allowed, base: brokerBase)
            if let brokerEvent = consult.event {
                configuration.evidence.record(brokerEvent)
            }
            let performed = perform(allowed, credential: consult.injection)
            var event = baseEvent(
                binding: plan.binding, park: plan.park,
                authorization: .allowed, result: "authorized")
            let response = admissionResponse(performed, event: &event)
            stamp(&event, agent: plan.park.approval.subject.agent, binding: plan.binding)
            configuration.evidence.record(event)
            enqueueCompletion(ParkedCompletion(response: response, event: event))
        }
    }

    /// Completes one park with the human's deny, carrying the gate's
    /// original denial. No grant exists; the continuation fails.
    private func denyParked(requestID: RuntimeActionRequestID, park: ParkedApproval) {
        let removed: Bool = state.withLock { channel in
            channel.parked.removeValue(forKey: requestID) != nil
        }
        guard removed else { return }
        var event = baseEvent(
            binding: state.withLock({ $0.binding }), park: park,
            authorization: .denied, result: park.pending.deny.ruleID.rawValue)
        stamp(&event, agent: park.approval.subject.agent, binding: state.withLock({ $0.binding }))
        configuration.evidence.record(event)
        enqueueCompletion(ParkedCompletion(
            response: .denied(park.pending.deny), event: event))
    }

    /// Completes one park fail-closed without executing. Mirrors the gate's
    /// `approvalFailed` shape; the cause distinguishes outcomes in evidence.
    private func failParked(
        requestID: RuntimeActionRequestID,
        park: ParkedApproval,
        cause: String,
        binding: RuntimeChannelBinding? = nil
    ) {
        let removed: Bool = state.withLock { channel in
            channel.parked.removeValue(forKey: requestID) != nil
        }
        guard removed else { return }
        let liveBinding = binding ?? state.withLock({ $0.binding })
        var event = baseEvent(
            binding: liveBinding, park: park,
            authorization: .approvalUnavailable, result: cause)
        stamp(&event, agent: park.approval.subject.agent, binding: liveBinding)
        configuration.evidence.record(event)
        enqueueCompletion(ParkedCompletion(response: .approvalUnavailable, event: event))
    }

    /// Base outcome event for one park, mirroring the gate's `make` fields.
    private func baseEvent(
        binding: RuntimeChannelBinding?,
        park: ParkedApproval,
        authorization: RuntimeAdmissionAuthorization,
        result: String
    ) -> RuntimeAdmissionEvent {
        let http = httpAudit(of: park.pending.action)
        return RuntimeAdmissionEvent(
            session: binding?.session.id.rawValue.uuidString,
            requestID: park.requestID.rawValue.uuidString,
            fingerprint: park.pending.action.fingerprint.rawValue,
            authorization: authorization,
            executionAttempted: false,
            result: result,
            httpMethod: http?.method,
            httpDestination: http?.destination,
            httpAddress: http?.address,
            httpQueryPresent: http?.queryPresent,
            workspace: binding?.session.workspaceSessionID.rawValue.uuidString)
    }

    /// Principal attribution for one park outcome, mirroring the gate's
    /// `stamp`: the retained agent description when one was parked, else
    /// the RV-held channel binding. Both sources are RV-held.
    private func stamp(
        _ event: inout RuntimeAdmissionEvent,
        agent: AuthenticatedAgentContext?,
        binding: RuntimeChannelBinding?
    ) {
        event.agentInstance =
            agent?.instance.id.rawValue.uuidString
            ?? binding?.agentInstanceID?.rawValue.uuidString
        event.agentDefinition = agent?.instance.definitionID.rawValue
    }

    private struct ParkedHTTPAudit {
        var method: String
        var destination: String
        var address: String?
        var queryPresent: Bool
    }

    /// HTTP audit fields for one park outcome. Mirrors the gate's private
    /// `httpAudit`: method, query-stripped resource, address, query flag.
    private func httpAudit(of action: ProposedAction) -> ParkedHTTPAudit? {
        guard case .http(let http) = action else { return nil }
        return ParkedHTTPAudit(
            method: http.method.rawValue,
            destination: http.destination.auditedResource,
            address: http.destination.address?.presentation,
            queryPresent: http.destination.query != nil)
    }

    /// Queues one finished answer for the watch thread to write. Dropped
    /// when stopping: the file descriptors are closing and nothing remains
    /// to answer (evidence was already recorded).
    private func enqueueCompletion(_ completion: ParkedCompletion) {
        state.withLock { channel in
            guard !channel.stop else { return }
            channel.completions.append(completion)
        }
    }

    /// Live park count. Test seam only.
    var parkedApprovalCountForTesting: Int {
        state.withLock { $0.parked.count }
    }

    /// Queued completion count. Test seam only.
    var queuedCompletionCountForTesting: Int {
        state.withLock { $0.completions.count }
    }

    /// Writes queued waiter answers. Runs only on the pre-existing writer
    /// paths (`acceptBuffered`), so parking adds no file-descriptor races.
    /// Completions for a stopped channel are dropped, never written.
    /// Internal (not private) so tests can drive delivery deterministically.
    func drainCompletions() {
        while true {
            let next: ParkedCompletion? = state.withLock { channel in
                guard !channel.stop, !channel.completions.isEmpty else {
                    channel.completions.removeAll()
                    return nil
                }
                return channel.completions.removeFirst()
            }
            guard let next else { return }
            writeResponse(RuntimeAdmissionDecision(
                binding: state.withLock({ $0.binding }),
                response: next.response,
                event: next.event,
                execute: nil))
        }
    }

    /// Tears down every park: cancels waiters, best-effort cancels the
    /// service-side approvals without blocking, and drops queued answers.
    /// Called from `finish()` while stopping; nothing is answered.
    private func teardownParks() {
        let parks = state.withLock { channel -> [ParkedApproval] in
            let parks = Array(channel.parked.values)
            channel.parked.removeAll()
            channel.parking.removeAll()
            channel.completions.removeAll()
            return parks
        }
        guard !parks.isEmpty else { return }
        let backend = configuration.askBackend
        for park in parks {
            park.waiter?.cancel()
            if let backend {
                let approval = park.approval
                Task { backend.cancelApproval(approval) }
            }
        }
    }

    func finish() {
        let token = state.withLock { channel -> HTTPCancellation? in
            channel.stop = true
            if var binding = channel.binding {
                binding.phase = .finished
                channel.binding = binding
            }
            return channel.httpToken
        }
        // Parked ASKs die with the channel: waiters are cancelled and the
        // service-side approvals are best-effort cancelled. Nothing is
        // answered; the file descriptors close below.
        teardownParks()
        token?.cancel()
        let deadline = Date().addingTimeInterval(
            TimeInterval(HTTPEgressLimits.requestTimeoutMilliseconds) / 1_000 + 2
        )
        while Date() < deadline {
            if state.withLock({ $0.httpToken == nil }) { break }
            usleep(1_000)
        }
        let fds = state.withLock { channel -> (Int32, Int32) in
            channel.buffer.removeAll()
            let pair = (channel.requestRead, channel.responseWrite)
            channel.requestRead = -1
            channel.responseWrite = -1
            return pair
        }
        if fds.0 >= 0 {
            admissionClose(fds.0)
        }
        if fds.1 >= 0 {
            admissionClose(fds.1)
        }
    }

    private func acceptBuffered() -> [RuntimeAdmissionDecision] {
        guard state.withLock({ $0.binding?.phase == .active }) else {
            let hadBytes = state.withLock { channel -> Bool in
                let had = channel.buffer.isEmpty == false
                channel.buffer.removeAll()
                return had
            }
            guard hadBytes else { return [] }
            return [submitLegacy(.failure(.malformed))]
        }
        var decisions: [RuntimeAdmissionDecision] = []
        while state.withLock({ $0.binding?.phase == .active }) {
            guard let taken = state.withLock({ RuntimeAdmissionCodec.takeFrame(from: &$0.buffer) }) else { break }
            let frame: Result<RuntimeActionFrame, RuntimeAdmissionDecodeError>
            switch taken {
            case .failure(let error):
                frame = .failure(error)
            case .success(let body):
                frame = RuntimeAdmissionCodec.decodeRequest(body)
            }
            let decision = submitLegacy(frame)
            decisions.append(decision)
            // A parked ASK defers its answer: the waiter queues the real
            // response below. Writing the superseded pending projection
            // would answer the runtime twice.
            if !decision.responseDeferred {
                writeResponse(decision)
            }
        }
        drainCompletions()
        if state.withLock({ $0.binding?.phase }) != .active {
            state.withLock { $0.buffer.removeAll() }
        }
        return decisions
    }

    private func writeResponse(_ decision: RuntimeAdmissionDecision) {
        let fd = state.withLock { $0.responseWrite }
        guard fd >= 0 else { return }
        guard case .success(let frame) = RuntimeAdmissionCodec.encodeResponse(
            decision.response,
            requestID: decision.event.requestID
        ) else {
            return
        }
        _ = admissionWriteAll(fd, frame)
    }

    /// Resolves a supervisor-side credential injection for one authorized
    /// HTTP action. The event is nil without a broker or for non-HTTP
    /// actions (pre-broker behavior: no consultation, no event). Otherwise
    /// resolves in host memory and returns the names-only audit event for
    /// the caller to record plus the injection for the caller to pass as
    /// an argument to the performing transport: `credentialGranted:<name>`,
    /// `credentialUnwired:<name>` (granted but no delivery reaches a
    /// hook-delivered transport: the grant is dropped fail-closed), or
    /// `credentialWithheld:<reason>`. The value never enters the event.
    /// Consultation runs only for gate-authorized actions, so binding and
    /// replay protection are the gate's, unchanged; the broker never
    /// widens or narrows the action's own allow/deny.
    private func consultCredentialBroker(
        for allowed: AllowedAction,
        base: RuntimeAdmissionEvent
    ) -> (event: RuntimeAdmissionEvent?, injection: BrokeredCredentialInjection?) {
        guard let broker = configuration.credentialBroker,
            case .http(let http) = allowed.action
        else {
            return (nil, nil)
        }
        let outcome: (RuntimeAdmissionAuthorization, String)
        let injection: BrokeredCredentialInjection?
        switch broker.resolve(host: http.destination.host) {
        case .granted(let granted):
            if let deliver = configuration.credentialDelivery {
                deliver(granted)
                outcome = (.allowed, "credentialGranted:\(granted.credentialName)")
                injection = granted
            } else if configuration.http.deliversCredentialAsArgument {
                // Wired by construction: the transport receives the
                // injection as an argument, so no hook is needed.
                outcome = (.allowed, "credentialGranted:\(granted.credentialName)")
                injection = granted
            } else {
                outcome = (.executorFailed, "credentialUnwired:\(granted.credentialName)")
                injection = nil
            }
        case .withheld(let reason):
            outcome = (.denied, "credentialWithheld:\(reason.rawValue)")
            injection = nil
        }
        return (
            RuntimeAdmissionEvent(
                session: base.session,
                requestID: base.requestID,
                fingerprint: base.fingerprint,
                authorization: outcome.0,
                executionAttempted: false,
                result: outcome.1,
                httpMethod: base.httpMethod,
                httpDestination: base.httpDestination,
                httpAddress: base.httpAddress,
                httpQueryPresent: base.httpQueryPresent,
                workspace: base.workspace,
                agentInstance: base.agentInstance,
                agentDefinition: base.agentDefinition
            ),
            injection
        )
    }

    private func perform(
        _ allowed: AllowedAction,
        credential: BrokeredCredentialInjection?
    ) -> AdmissionPerformResult {
        switch allowed.action {
        case .file:
            return .shell(.failure(.compileFailed))
        case .shell:
            switch configuration.executor {
            case .refuse:
                return .shell(.failure(.unavailable))
            case .effect(let body):
                return .shell(body(allowed))
            case .containedCommand:
                return .shell(runAdmittedSeatbeltCommand(allowed: allowed, launch: launch))
            }
        case .http(let http):
            guard let token = beginHTTP() else {
                return .http(.failure(.notOpened(.cancelled)))
            }
            defer { endHTTP() }
            #if os(macOS)
            let leader = launch.sessionLeader
            let shouldStop: @Sendable () -> Bool = {
                token.isCancelled || blockingWorkIsCancelled() || sessionLeaderHasExited(leader)
            }
            #else
            let shouldStop: @Sendable () -> Bool = {
                token.isCancelled || blockingWorkIsCancelled()
            }
            #endif
            switch configuration.http {
            case .refuse:
                return .http(.failure(.notOpened(.unavailable)))
            case .effect(let body):
                return .http(body(http, token, shouldStop))
            case .effectWithCredential(let body):
                return .http(body(http, credential, token, shouldStop))
            case .direct:
                return .http(
                    HTTPDirectExecutor.perform(
                        http,
                        credential: credential,
                        cancellation: token,
                        shouldStop: shouldStop
                    )
                )
            }
        }
    }

    private func beginHTTP() -> HTTPCancellation? {
        state.withLock { channel in
            guard channel.stop == false, channel.httpToken == nil, channel.binding?.phase == .active else {
                return nil
            }
            let token = HTTPCancellation()
            channel.httpToken = token
            return token
        }
    }

    private func endHTTP() {
        state.withLock { $0.httpToken = nil }
    }

    private func inactiveDecision(
        binding: RuntimeChannelBinding?,
        event: RuntimeAdmissionEvent
    ) -> RuntimeAdmissionDecision {
        RuntimeAdmissionDecision(
            binding: binding,
            response: .rejected(.inactiveSession),
            event: RuntimeAdmissionEvent(
                session: event.session,
                requestID: event.requestID,
                fingerprint: event.fingerprint,
                authorization: .rejected,
                executionAttempted: false,
                result: RuntimeAdmissionRejection.inactiveSession.rawValue,
                workspace: event.workspace,
                agentInstance: event.agentInstance,
                agentDefinition: event.agentDefinition
            )
        )
    }
}

private enum AdmissionPerformResult {
    case shell(Result<Int32, RuntimeAdmissionExecutorError>)
    case http(Result<HTTPExecutionReceipt, HTTPEgressFailure>)
}

private func admissionResponse(
    _ performed: AdmissionPerformResult,
    event: inout RuntimeAdmissionEvent
) -> RuntimeAdmissionResponse {
    switch performed {
    case .shell(.success(let status)):
        event.authorization = .allowed
        event.executionAttempted = true
        event.result = "exit:\(status)"
        return .executed(exitStatus: status)
    case .shell(.failure(let error)):
        event.authorization = .executorFailed
        event.executionAttempted = true
        event.result = error.rawValue
        return .executorFailed(error)
    case .http(.success(let receipt)):
        event.authorization = .allowed
        event.executionAttempted = true
        event.result = "http:\(receipt.status)"
        event.httpStatus = receipt.status
        return .http(receipt)
    case .http(.failure(.notOpened(let reason))):
        event.authorization = .executorFailed
        event.executionAttempted = false
        event.result = reason.rawValue
        switch reason {
        case .cancelled:
            return .executorFailed(.cancelled)
        case .unavailable, .forbiddenDestination:
            return .executorFailed(.unavailable)
        }
    case .http(.failure(.opened(let failure))):
        event.authorization = .executorFailed
        event.executionAttempted = true
        event.result = httpFailureName(failure)
        if case .redirect(let status, _) = failure {
            event.httpStatus = status
        }
        return .httpFailed(failure)
    }
}

/// Polled by name lookup while `getaddrinfo` runs on another thread.
///
/// The session loop sets this around normalize. A stuck resolver then cannot
/// keep the contained process group alive after the leader exits.
enum RuntimeAdmissionStop {
    @TaskLocal static var shouldStop: @Sendable () -> Bool = { false }
}

/// Resolves a name without blocking the session reaper.
///
/// `lookup` runs on another thread. This returns when the budget ends or
/// `RuntimeAdmissionStop.shouldStop` is set, so a stuck resolver cannot
/// keep the contained process group alive.
public func resolveAdmittedHTTPHost(
    _ name: String,
    budgetMilliseconds: Int,
    lookup: @escaping @Sendable (String) -> Result<[HTTPIPAddress], HTTPResolutionError>
) -> Result<[HTTPIPAddress], HTTPResolutionError> {
    if RuntimeAdmissionStop.shouldStop() || blockingWorkIsCancelled() {
        return .failure(.failed)
    }
    let flight = AdmittedDNSLookup()
    // A dedicated thread, not the shared queue. The test process and a busy
    // runtime can stall that queue long enough to miss the request budget.
    let worker = Thread {
        flight.store(lookup(name))
    }
    worker.name = "rv.http.resolve"
    worker.start()
    let deadline = monotonicMilliseconds() + Int64(max(budgetMilliseconds, 0))
    while monotonicMilliseconds() < deadline {
        if let result = flight.current() { return result }
        if RuntimeAdmissionStop.shouldStop() || blockingWorkIsCancelled() {
            return .failure(.failed)
        }
        usleep(10_000)
    }
    return .failure(.failed)
}

private final class AdmittedDNSLookup: Sendable {
    private let result = Mutex<Result<[HTTPIPAddress], HTTPResolutionError>?>(nil)

    func store(_ value: Result<[HTTPIPAddress], HTTPResolutionError>) {
        result.withLock { $0 = value }
    }

    func current() -> Result<[HTTPIPAddress], HTTPResolutionError>? {
        result.withLock { $0 }
    }
}

private func monotonicMilliseconds() -> Int64 {
    var time = timespec()
    clock_gettime(CLOCK_MONOTONIC, &time)
    return Int64(time.tv_sec) * 1_000 + Int64(time.tv_nsec) / 1_000_000
}

private func httpFailureName(_ failure: HTTPOpenFailure) -> String {
    switch failure {
    case .redirect:
        return "redirect"
    case .responseTooLarge:
        return "responseTooLarge"
    case .timedOut:
        return "timedOut"
    case .cancelled:
        return "cancelled"
    case .transport:
        return "transport"
    case .malformedResponse:
        return "malformedResponse"
    case .unsupportedTransfer:
        return "unsupportedTransfer"
    case .tooManyHeaders:
        return "tooManyHeaders"
    }
}
