import Foundation
import RVDomain
import RVHistory
import RVHooks
import RVIPC
import RVPolicy
import RVService

public struct RoutedEvaluation: Sendable, Equatable {
    public let result: EvaluationResult
    public let path: EvaluationPath

    public init(result: EvaluationResult, path: EvaluationPath) {
        self.result = result
        self.path = path
    }
}

public struct ServiceClient: Sendable {
    private let transport: (any ServiceTransport)?
    private let door: GatedEvaluate
    private let store: AllowOnceStore
    private let home: HomeDirectory?
    private let clock: @Sendable () -> Date

#if canImport(XPC)
    public init(
        transport: (any ServiceTransport)? = XPCServiceTransport(),
        session: EvaluateSession? = nil,
        store: AllowOnceStore? = nil,
        allowOnceDirectory: URL? = nil,
        home: HomeDirectory? = HomeDirectory.process(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            resolvedTransport: transport,
            session: session,
            store: store,
            allowOnceDirectory: allowOnceDirectory,
            home: home,
            clock: clock
        )
    }
#else
    public init(
        transport: (any ServiceTransport)? = nil,
        session: EvaluateSession? = nil,
        store: AllowOnceStore? = nil,
        allowOnceDirectory: URL? = nil,
        home: HomeDirectory? = HomeDirectory.process(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            resolvedTransport: transport,
            session: session,
            store: store,
            allowOnceDirectory: allowOnceDirectory,
            home: home,
            clock: clock
        )
    }
#endif

    private init(
        resolvedTransport: (any ServiceTransport)?,
        session: EvaluateSession?,
        store: AllowOnceStore?,
        allowOnceDirectory: URL?,
        home: HomeDirectory?,
        clock: @escaping @Sendable () -> Date
    ) {
        self.transport = resolvedTransport
        if let session {
            self.door = GatedEvaluate(session)
        } else {
            self.door = EvaluationWorld.assemble(home: home, snapshots: nil, catalog: nil)
        }
        self.store = Self.resolveStore(store: store, allowOnceDirectory: allowOnceDirectory, home: home)
        self.home = home
        self.clock = clock
    }

    /// Test seam: builds the fallback door from an explicit provider so tests can
    /// observe when the in-process session is constructed.
    package init(
        transport: (any ServiceTransport)?,
        lazySession: @escaping @Sendable () -> EvaluateSession,
        allowOnceDirectory: URL?,
        home: HomeDirectory?,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.door = GatedEvaluate(lazySession: lazySession)
        self.store = Self.resolveStore(store: nil, allowOnceDirectory: allowOnceDirectory, home: home)
        self.home = home
        self.clock = clock
    }

    public static func missingCore(
        transport: (any ServiceTransport)? = nil,
        allowOnceDirectory: URL? = nil
    ) -> ServiceClient {
        let sandbox = isolatedFactoryDirectory()
        return ServiceClient(
            transport: transport,
            session: .missingCore,
            allowOnceDirectory: allowOnceDirectory ?? sandbox,
            home: HomeDirectory(validating: sandbox.path)
        )
    }

    public static func uncompilableCore(
        transport: (any ServiceTransport)? = nil,
        allowOnceDirectory: URL? = nil
    ) -> ServiceClient {
        let sandbox = isolatedFactoryDirectory()
        return ServiceClient(
            transport: transport,
            session: .uncompilableCore,
            allowOnceDirectory: allowOnceDirectory ?? sandbox,
            home: HomeDirectory(validating: sandbox.path)
        )
    }

    /// Diagnostic fallback uses an empty, isolated grant view and cannot spend authority.
    private func diagnosticPeek(command: ShellCommand, cwd: WorkingDirectory?) async -> EvaluationResult {
        // Grants stay isolated: a diagnostic fallback must neither honor
        // nor consume an existing grant. The allowlist loads from the
        // client's own store directory so saved rules still apply.
        let diagnosticDirectory = Self.isolatedFactoryDirectory()
        defer { try? FileManager.default.removeItem(at: diagnosticDirectory) }
        let diagnosticStore = AllowOnceStore(baseDirectory: diagnosticDirectory)
        let allowlistDirectory = store.baseDirectory
        return await LiveEvaluateWorld(
            home: home,
            store: diagnosticStore,
            gated: door,
            clock: clock,
            allowlist: { cwd, now in
                AllowlistStore(baseDirectory: allowlistDirectory)
                    .loadUserSnapshot(workspacePath: cwd.map(\.rawValue), now: now)
            }
        ).peek(command: command, cwd: cwd)
    }

    /// Diagnostic evaluation: an inProcess result is never execution authorization.
    public func evaluate(command: ShellCommand, cwd: WorkingDirectory? = nil) async -> RoutedEvaluation {
        func inProcessRoute() async -> RoutedEvaluation {
            RoutedEvaluation(result: await diagnosticPeek(command: command, cwd: cwd), path: .inProcess)
        }
        guard let transport else {
            return await inProcessRoute()
        }
        do {
            let reply = try await send(
                EvaluateCall(
                    params: EvaluateParams(
                        request: GatedEvaluate.makeRequest(command: command, home: home),
                        cwd: cwd,
                        clientSemver: ProtocolVersion.serviceSemver
                    )
                ),
                using: transport,
                timeoutMs: transport.oneShotEvaluateTimeoutMs
            )
            switch EvaluationRoute.path(for: .reply(
                clientSemver: ProtocolVersion.serviceSemver,
                advertisedServiceSemver: reply.serviceSemver
            )) {
            case .service:
                return RoutedEvaluation(result: reply.result, path: .service)
            case .inProcess:
                transport.invalidate()
                return await inProcessRoute()
            }
        } catch {
            switch error {
            case .identityMismatch, .unexpectedResult, .service:
                transport.invalidate()
            case .transport, .codec:
                break
            }
            return await inProcessRoute()
        }
    }

    /// Diagnostic convenience only; product execution paths use authenticated hookEvaluate.
    public func evaluateResult(command: ShellCommand, cwd: WorkingDirectory? = nil) async -> EvaluationResult {
        await evaluate(command: command, cwd: cwd).result
    }

    /// Closed set of ways an IPC call can fail.
    private enum IPCCallError: Error {
        case transport(ServiceTransportFailure)
        /// The request did not encode or the reply did not decode.
        case codec(any Error)
        case identityMismatch
        case unexpectedResult
        case service(IPCError)
    }

    private func send<C: IPCCall>(
        _ call: C,
        using transport: any ServiceTransport,
        timeoutMs: Int? = nil,
        hookConsult: Bool = false
    ) async throws(IPCCallError) -> C.Reply {
        let request = IPCRequest(method: call.method)
        let body: Data
        do {
            body = try IPCJSON.encode(request)
        } catch {
            throw .codec(error)
        }
        let data: Data
        do {
            if hookConsult {
                data = try await transport.sendHookConsult(
                    body, timeoutMs: timeoutMs ?? transport.oneShotEvaluateTimeoutMs)
            } else if let timeoutMs {
                data = try await transport.send(body, timeoutMs: timeoutMs)
            } else {
                data = try await transport.send(body)
            }
        } catch {
            throw .transport(error)
        }
        let response: IPCResponse
        do {
            response = try IPCJSON.decode(IPCResponse.self, from: data)
        } catch {
            throw .codec(error)
        }
        guard response.id == request.id, response.protocolName == request.protocolName else {
            throw IPCCallError.identityMismatch
        }
        if case .error(let error) = response.result {
            throw IPCCallError.service(error)
        }
        guard let reply = C.extract(response.result) else {
            throw IPCCallError.unexpectedResult
        }
        return reply
    }

    public enum ServiceCommandError: Error, Sendable, Equatable {
        case noTransport
        case service(String)
        case transport(String)
    }

    @available(*, deprecated, renamed: "ServiceCommandError")
    public typealias OperatorCommandError = ServiceCommandError

    /// Untrusted launch proposal. Returns the correlation-only operation ID;
    /// authority arrives only via the host bridge and operator review.
    public func proposeLaunch(_ params: ProposeLaunchParams) async -> Result<
        ProposeLaunchReply, ServiceCommandError
    > {
        guard let transport else {
            return .failure(.noTransport)
        }
        do {
            let reply = try await send(
                ProposeLaunchCall(params: params), using: transport)
            return .success(reply)
        } catch {
            return .failure(mapCallError(error))
        }
    }

    public func proposalStatus(operationID: UUID) async -> Result<
        ProposalStatusReply, ServiceCommandError
    > {
        guard let transport else {
            return .failure(.noTransport)
        }
        do {
            let reply = try await send(
                ProposalStatusCall(params: ProposalStatusParams(operationID: operationID)),
                using: transport)
            return .success(reply)
        } catch {
            return .failure(mapCallError(error))
        }
    }

    /// Step 8B.1 TTY attestation: plants the reviewed grant in daemon memory.
    /// Only the pinned genuine CLI passes the daemon's `.cli` role check;
    /// every other caller fails closed there. No transport (or a refused
    /// attestation) means NO grant: the caller must fail closed, never
    /// fall back to file state.
    public func attestTTYRedemption(_ params: AttestTTYRedemptionParams) async -> Result<
        AttestTTYRedemptionReply, ServiceCommandError
    > {
        guard let transport else {
            return .failure(.noTransport)
        }
        do {
            let reply = try await send(
                AttestTTYRedemptionCall(params: params),
                using: transport,
                timeoutMs: transport.oneShotEvaluateTimeoutMs
            )
            return .success(reply)
        } catch {
            return .failure(mapCallError(error))
        }
    }

    private func mapCallError(_ error: IPCCallError) -> ServiceCommandError {
        switch error {
        case .identityMismatch:
            return .transport("identityMismatch")
        case .unexpectedResult:
            return .transport("unexpectedResult")
        case .service(let ipcError):
            return .service(String(describing: ipcError))
        case .transport(let failure):
            return .transport(String(describing: failure))
        case .codec(let underlying):
            return .transport(String(describing: underlying))
        }
    }

    /// Whole hook consult budget: two Hello exchanges (3000 ms each, covers
    /// a launchd cold spawn) plus hookEvaluate (8000 ms; rvd enforces its
    /// own shorter deadline). Mirrors the C client's per-exchange budgets.
    static let hookEvaluateTimeoutMs = 14_000

    /// `hookEvaluate` with the daemon-miss posture read from `RV_HOOK_WHEN_DOWN`.
    public func hookEvaluate(host: HookHost, stdin: String) async -> HookWire {
        await hookEvaluate(
            host: host,
            stdin: stdin,
            whenDown: HookWhenDown(environmentValue: CLIProcess.environment()[HookWhenDown.environmentKey])
        )
    }

    /// Authority-bearing hooks never retry through the local evaluation door,
    /// and the request is never resent. A daemon miss is classified and
    /// rendered per `whenDown` (`HookDaemonFallback`).
    public func hookEvaluate(host: HookHost, stdin: String, whenDown: HookWhenDown) async -> HookWire {
        func unavailable(_ failure: HookDaemonFailure) -> HookWire {
            HookDaemonFallback.wire(host: host, failure: failure, mode: whenDown)
        }
        guard let transport else {
            return unavailable(.unreachable)
        }
        do {
            let reply = try await send(
                HookEvaluateCall(
                    params: HookEvaluateParams(
                        host: host,
                        stdin: stdin,
                        clientSemver: ProtocolVersion.serviceSemver
                    )
                ),
                using: transport,
                timeoutMs: Self.hookEvaluateTimeoutMs,
                hookConsult: true
            )
            switch EvaluationRoute.path(for: .reply(
                clientSemver: ProtocolVersion.serviceSemver,
                advertisedServiceSemver: reply.serviceSemver
            )) {
            case .service:
                return HookWire(stdout: reply.stdout, exitCode: reply.exitCode, stderr: reply.stderr)
            case .inProcess:
                transport.invalidate()
                return unavailable(.protocol)
            }
        } catch {
            switch error {
            case .transport(let failure):
                if failure == .malformedReply {
                    transport.invalidate()
                }
                return unavailable(HookDaemonFallback.classify(failure))
            case .codec, .identityMismatch, .unexpectedResult, .service:
                // No trustworthy verdict (malformed reply): never softened.
                transport.invalidate()
                return unavailable(.protocol)
            }
        }
    }

    /// Client for `rv doctor` / `rv service status`: hook-consult probes pin
    /// the `rvd` beside the hook `rv` (`~/.local/bin/rvd`), exactly as hooks
    /// do, regardless of where this `rv-cli` runs from.
    static func probing(home: HomeDirectory?) -> ServiceClient {
#if canImport(XPC)
        let hookRvd = home.map { OwnedPaths(home: $0).localRvd }
        return ServiceClient(transport: XPCServiceTransport(hookSiblingDaemonPath: hookRvd), home: home)
#else
        return ServiceClient(home: home)
#endif
    }

    /// Hook-door liveness over the same consult transport hooks use: a
    /// read-only snapshot, never an evaluation. Retried so a freshly
    /// bootstrapped daemon still starting does not read as down.
    func verifyHookService(attempts: Int = 3, retryDelayNanoseconds: UInt64 = 1_000_000_000) async -> Bool {
        guard let transport else { return false }
        let tries = max(1, attempts)
        for attempt in 0..<tries {
            do {
                _ = try await send(
                    DoctorSnapshotCall(),
                    using: transport,
                    timeoutMs: transport.oneShotEvaluateTimeoutMs,
                    hookConsult: true
                )
                return true
            } catch {
                if attempt + 1 < tries, retryDelayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
                }
            }
        }
        return false
    }

    public func status() async -> ServiceStatusReport {
        ServiceHealth.inspect(await diagnostics()).statusReport
    }

    /// Probes rvd over the hook-consult session: the same daemon-identity
    /// rule hooks apply (admin manifest when installed, else the sibling
    /// `rvd` pin), so a healthy manifest-free install reads as running.
    func diagnostics() async -> ServiceDiagnosticResult {
        let localCorePacksReady = door.corePacksReady
        switch await route() {
        case .xpc(let transport, let serviceSemver):
            do {
                let snapshot = try await send(DoctorSnapshotCall(), using: transport, hookConsult: true)
                return .xpc(
                    snapshot: snapshot,
                    localCorePacksReady: localCorePacksReady
                )
            } catch {
                let cause: ServiceFallbackCause
                switch error {
                case .identityMismatch, .codec:
                    cause = .requestFailed(.invalidResponse)
                case .unexpectedResult:
                    cause = .requestFailed(.unexpectedResponse)
                case .service(.protocolSkew):
                    cause = .skew(.protocolMismatch)
                case .service(let serviceError):
                    cause = .requestFailed(.service(serviceError))
                case .transport(let failure):
                    cause = .requestFailed(Self.diagnosticFailure(from: failure))
                }
                return localDiagnostic(
                    cause: cause,
                    corePacksReady: localCorePacksReady,
                    serviceSemver: serviceSemver
                )
            }
        case .down:
            return localDiagnostic(cause: .down, corePacksReady: localCorePacksReady)
        case .skew(let reason, let serviceSemver):
            return localDiagnostic(
                cause: .skew(reason),
                corePacksReady: localCorePacksReady,
                serviceSemver: serviceSemver
            )
        case .failed(let failure):
            return localDiagnostic(
                cause: .requestFailed(failure),
                corePacksReady: localCorePacksReady
            )
        }
    }

    private func localDiagnostic(
        cause: ServiceFallbackCause,
        corePacksReady: Bool,
        serviceSemver: String? = nil
    ) -> ServiceDiagnosticResult {
        .local(
            ServiceFallbackDiagnostic(
                cause: cause,
                corePacksReady: corePacksReady,
                serviceSemver: serviceSemver
            )
        )
    }

    private static func diagnosticFailure(from failure: ServiceTransportFailure) -> ServiceDiagnosticFailure {
        failure == .untrusted ? .daemonRejected : .transport(failure)
    }

    private enum Route {
        case xpc(any ServiceTransport, serviceSemver: String)
        case down
        case skew(ServiceSkewReason, serviceSemver: String)
        case failed(ServiceDiagnosticFailure)
    }

    private func route() async -> Route {
        guard let transport else { return .down }
        do {
            let ack = try await transport.helloHookConsult(clientSemver: ProtocolVersion.serviceSemver)
            if let reason = skewReason(ack) {
                transport.invalidate()
                return .skew(reason, serviceSemver: ack.serviceSemver)
            }
            return .xpc(transport, serviceSemver: ack.serviceSemver)
        } catch {
            switch error {
            case .timeout, .unreachable:
                return .down
            case .untrusted, .malformedReply:
                return .failed(Self.diagnosticFailure(from: error))
            }
        }
    }

    private func skewReason(_ ack: HelloAckView) -> ServiceSkewReason? {
        if ack.protocolName != ProtocolVersion.name {
            return .protocolMismatch
        }
        if ProtocolVersion.isMajorSkew(
            clientSemver: ProtocolVersion.serviceSemver,
            serviceSemver: ack.serviceSemver
        ) {
            return .majorVersionMismatch
        }
        switch ack.status {
        case .ok:
            return nil
        case .skew(.corePacksUnavailable):
            return .corePacksUnavailable
        case .skew(.majorVersion):
            return .majorVersionMismatch
        case .skew(.protocolSkew):
            return .rejected
        }
    }

    private static func resolveStore(
        store: AllowOnceStore?,
        allowOnceDirectory: URL?,
        home: HomeDirectory?
    ) -> AllowOnceStore {
        if let store {
            return store
        }
        if let allowOnceDirectory {
            return AllowOnceStore(baseDirectory: allowOnceDirectory)
        }
        if let home {
            return AllowOnceStore.makeLive(home: home)
        }
        return AllowOnceStore(baseDirectory: Self.isolatedFactoryDirectory())
    }

    private static func isolatedFactoryDirectory() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-client-allow-once-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
