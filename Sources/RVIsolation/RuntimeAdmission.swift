#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import Synchronization

/// In-memory admission evidence. A failed record is not represented: appending
/// here cannot fail, and the shell records the final outcome before it returns.
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
            appendAdmissionEvent(event, to: file)
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
    /// Dial the pinned public address from RV, with no proxy and no cookies.
    case direct
}

public struct RuntimeAdmissionConfiguration: Sendable {
    public var normalize:
        @Sendable (RuntimeAdmissionSubject, RuntimeRequestedAction) -> Result<
            ProposedAction, RuntimeAdmissionEvaluationError
        >
    public var executor: RuntimeAdmissionExecutor
    public var http: RuntimeHTTPExecutor
    public var approval:
        @Sendable (PendingAuthorization) -> Result<ApprovalDecision, AgentApprovalError>?
    public var policy: @Sendable (RuntimeSession) -> EffectiveActionPolicy
    public var evidence: RuntimeAdmissionEvidence

    public init(
        normalize: @escaping @Sendable (RuntimeAdmissionSubject, RuntimeRequestedAction) -> Result<
            ProposedAction, RuntimeAdmissionEvaluationError
        >,
        executor: RuntimeAdmissionExecutor,
        http: RuntimeHTTPExecutor = .refuse,
        approval: @escaping @Sendable (PendingAuthorization) -> Result<
            ApprovalDecision, AgentApprovalError
        >?,
        policy: @escaping @Sendable (RuntimeSession) -> EffectiveActionPolicy,
        evidence: RuntimeAdmissionEvidence
    ) {
        self.normalize = normalize
        self.executor = executor
        self.http = http
        self.approval = approval
        self.policy = policy
        self.evidence = evidence
    }

    public static var failClosed: RuntimeAdmissionConfiguration {
        RuntimeAdmissionConfiguration(
            normalize: { _, _ in .failure(.failed) },
            executor: .refuse,
            http: .refuse,
            approval: { _ in nil },
            policy: { _ in .empty },
            evidence: RuntimeAdmissionEvidence()
        )
    }
}

/// Plan and profile RV already compiled for this launch.
struct AdmittedLaunchContext: Sendable, Equatable {
    var plan: ContainedPlan
    var profileSource: String
    var workspacePath: String
    /// Process that owns this runtime. `-1` when the caller is not a session.
    /// An admitted command stops if this process has exited.
    var sessionLeader: pid_t = -1
    /// Workspace egress proxy port, when the owning runtime has one.
    var egressProxyPort: Int? = nil
}

/// One runtime's admission state.
///
/// The request pipe is the channel. `RuntimeSessionID` is only the name the
/// claim must match. `close()` makes later bytes, including a copied
/// capability, unable to execute.
final class RuntimeAdmissionSession: Sendable {
    private let state: Mutex<ChannelState>
    private let configuration: RuntimeAdmissionConfiguration
    private let subject: RuntimeAdmissionSubject
    private let launch: AdmittedLaunchContext

    private struct ChannelState: Sendable {
        var binding: RuntimeChannelBinding?
        var buffer = Data()
        var requestRead: Int32
        var responseWrite: Int32
        var httpToken: HTTPCancellation?
        var stop = false
    }

    init(
        binding: RuntimeChannelBinding,
        configuration: RuntimeAdmissionConfiguration,
        launch: AdmittedLaunchContext,
        requestRead: Int32,
        responseWrite: Int32
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

    @discardableResult
    func submit(
        _ frame: Result<RuntimeActionFrame, RuntimeAdmissionDecodeError>
    ) -> RuntimeAdmissionDecision {
        var binding = state.withLock { $0.binding }
        let leader = launch.sessionLeader
        let decision = RuntimeAdmissionGate.submit(
            binding: &binding,
            frame: frame,
            policy: configuration.policy(subject.session),
            approvalFor: configuration.approval,
            propose: { [configuration, subject] accepted in
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
            channel.binding = binding
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
        let performed = perform(allowed)
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

    func finish() {
        let token = state.withLock { channel -> HTTPCancellation? in
            channel.stop = true
            if var binding = channel.binding {
                binding.phase = .finished
                channel.binding = binding
            }
            return channel.httpToken
        }
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
            return [submit(.failure(.malformed))]
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
            let decision = submit(frame)
            decisions.append(decision)
            writeResponse(decision)
        }
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

    private func perform(_ allowed: AllowedAction) -> AdmissionPerformResult {
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
            case .direct:
                return .http(
                    HTTPDirectExecutor.perform(
                        http,
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
                workspace: event.workspace
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
