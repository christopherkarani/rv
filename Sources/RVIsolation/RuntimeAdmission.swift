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
public final class RuntimeAdmissionEvidence: @unchecked Sendable {
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
    var plan: IsolationPlan
    var profileSource: String
    var workspacePath: String
    /// Process that owns this runtime. `-1` when the caller is not a session.
    /// An admitted command stops if this process has exited.
    var sessionLeader: pid_t = -1
}

/// One runtime's admission state.
///
/// The request pipe is the channel. `RuntimeSessionID` is only the name the
/// claim must match. `close()` makes later bytes, including a copied
/// capability, unable to execute.
final class RuntimeAdmissionSession {
    private var binding: RuntimeChannelBinding?
    private let configuration: RuntimeAdmissionConfiguration
    private let subject: RuntimeAdmissionSubject
    private let launch: AdmittedLaunchContext
    private var buffer = Data()
    private var requestRead: Int32
    private var responseWrite: Int32
    private let flight = Mutex(HTTPFlight())

    init(
        binding: RuntimeChannelBinding,
        configuration: RuntimeAdmissionConfiguration,
        launch: AdmittedLaunchContext,
        requestRead: Int32,
        responseWrite: Int32
    ) {
        self.binding = binding
        self.configuration = configuration
        self.subject = RuntimeAdmissionSubject(
            session: binding.session,
            policyWorkspace: subjectWorkspace(launch: launch, session: binding.session)
        )
        self.launch = launch
        self.requestRead = requestRead
        self.responseWrite = responseWrite
    }

    func sendGrant() {
        guard let binding, responseWrite >= 0 else { return }
        guard case .success(let frame) = RuntimeAdmissionCodec.encodeGrant(
            capability: binding.capability,
            session: binding.session.id.rawValue
        ) else {
            return
        }
        _ = admissionWriteAll(responseWrite, frame)
    }

    /// Reads whatever is currently available. A finished session drops bytes.
    func service() {
        guard binding?.phase == .active else {
            buffer.removeAll()
            return
        }
        if requestRead >= 0 {
            buffer.append(admissionReadAvailable(requestRead))
        }
        _ = acceptBuffered()
    }

    /// Test entry for bytes that did not come from the granted pipe.
    @discardableResult
    func accept(_ data: Data) -> [RuntimeAdmissionDecision] {
        buffer.append(data)
        return acceptBuffered()
    }

    @discardableResult
    func submit(
        _ frame: Result<RuntimeActionFrame, RuntimeAdmissionDecodeError>
    ) -> RuntimeAdmissionDecision {
        var binding = self.binding
        let decision = RuntimeAdmissionGate.submit(
            binding: &binding,
            frame: frame,
            policy: configuration.policy(subject.session),
            approvalFor: configuration.approval,
            propose: { [configuration, subject] accepted in
                configuration.normalize(subject, accepted.action)
            }
        )
        flight.withLock { state in
            if state.stop {
                binding?.phase = .finished
            }
            self.binding = binding
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
        let token = flight.withLock { state -> HTTPCancellation? in
            state.stop = true
            if var binding {
                binding.phase = .finished
                self.binding = binding
            }
            return state.token
        }
        token?.cancel()
        let deadline = Date().addingTimeInterval(
            TimeInterval(HTTPEgressLimits.requestTimeoutMilliseconds) / 1_000 + 2
        )
        while Date() < deadline {
            if flight.withLock({ $0.token == nil }) { break }
            usleep(1_000)
        }
        buffer.removeAll()
        if requestRead >= 0 {
            admissionClose(requestRead)
            requestRead = -1
        }
        if responseWrite >= 0 {
            admissionClose(responseWrite)
            responseWrite = -1
        }
    }

    private func acceptBuffered() -> [RuntimeAdmissionDecision] {
        guard binding?.phase == .active else {
            let hadBytes = buffer.isEmpty == false
            buffer.removeAll()
            guard hadBytes else { return [] }
            return [submit(.failure(.malformed))]
        }
        var decisions: [RuntimeAdmissionDecision] = []
        while binding?.phase == .active {
            guard let taken = RuntimeAdmissionCodec.takeFrame(from: &buffer) else { break }
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
        if binding?.phase != .active {
            buffer.removeAll()
        }
        return decisions
    }

    private func writeResponse(_ decision: RuntimeAdmissionDecision) {
        guard responseWrite >= 0 else { return }
        guard case .success(let frame) = RuntimeAdmissionCodec.encodeResponse(
            decision.response,
            requestID: decision.event.requestID
        ) else {
            return
        }
        _ = admissionWriteAll(responseWrite, frame)
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
                token.isCancelled || Task.isCancelled || sessionLeaderHasExited(leader)
            }
            #else
            let shouldStop: @Sendable () -> Bool = {
                token.isCancelled || Task.isCancelled
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
        flight.withLock { state in
            guard state.stop == false, state.token == nil, binding?.phase == .active else {
                return nil
            }
            let token = HTTPCancellation()
            state.token = token
            return token
        }
    }

    private func endHTTP() {
        flight.withLock { $0.token = nil }
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
                result: RuntimeAdmissionRejection.inactiveSession.rawValue
            )
        )
    }
}

private struct HTTPFlight: Sendable {
    var token: HTTPCancellation?
    var stop = false
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

private func subjectWorkspace(
    launch: AdmittedLaunchContext,
    session: RuntimeSession
) -> WorkingDirectory {
    launch.plan.workspace ?? session.workspace
}
