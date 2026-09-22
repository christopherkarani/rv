#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import Synchronization

/// Normalizes one admitted action against the runtime RV launched.
///
/// Shell text and the raw HTTP URL are the untrusted fields. Workspace and
/// session identity come from `subject`. Unwrap-limited input produces no
/// proposal. HTTP names are resolved here so policy sees the address RV dials.
public func normalizeRuntimeAdmission(
    subject: RuntimeAdmissionSubject,
    action: RuntimeRequestedAction
) -> Result<ProposedAction, RuntimeAdmissionEvaluationError> {
    switch action {
    case .shell(let command):
        return normalizeRuntimeShell(subject: subject, command: command)
    case .http(let method, let url):
        return normalizeRuntimeHTTP(
            subject: subject,
            method: method,
            url: url,
            resolve: resolveHTTPHost
        )
    }
}

/// Resolves one HTTPS name to the addresses `getaddrinfo` returns.
///
/// Literal addresses do not come through here. An empty or failed lookup
/// produces no HTTP action. `getaddrinfo` runs off the session thread. The
/// caller waits at most one request budget and returns earlier when the
/// session has stopped, so the reaper can still kill the process group.
public func resolveHTTPHost(_ name: String) -> Result<[HTTPIPAddress], HTTPResolutionError> {
    resolveHTTPHost(
        name,
        deadline: Date().addingTimeInterval(
            TimeInterval(HTTPEgressLimits.requestTimeoutMilliseconds) / 1_000
        ),
        lookup: blockingResolveHTTPHost
    )
}

func resolveHTTPHost(
    _ name: String,
    deadline: Date,
    lookup: @escaping @Sendable (String) -> Result<[HTTPIPAddress], HTTPResolutionError>
) -> Result<[HTTPIPAddress], HTTPResolutionError> {
    if RuntimeAdmissionStop.shouldStop() || Task.isCancelled {
        return .failure(.failed)
    }
    let flight = DNSLookup()
    DispatchQueue.global(qos: .utility).async {
        flight.store(lookup(name))
    }
    while Date() < deadline {
        if let result = flight.current() { return result }
        if RuntimeAdmissionStop.shouldStop() || Task.isCancelled {
            return .failure(.failed)
        }
        usleep(10_000)
    }
    return .failure(.failed)
}

final class DNSLookup: Sendable {
    private let result = Mutex<Result<[HTTPIPAddress], HTTPResolutionError>?>(nil)

    func store(_ value: Result<[HTTPIPAddress], HTTPResolutionError>) {
        result.withLock { $0 = value }
    }

    func current() -> Result<[HTTPIPAddress], HTTPResolutionError>? {
        result.withLock { $0 }
    }
}

private func blockingResolveHTTPHost(
    _ name: String
) -> Result<[HTTPIPAddress], HTTPResolutionError> {
    var hints = addrinfo()
    hints.ai_flags = AI_ADDRCONFIG
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    hints.ai_protocol = IPPROTO_TCP
    var info: UnsafeMutablePointer<addrinfo>?
    let code = getaddrinfo(name, nil, &hints, &info)
    guard code == 0, let info else { return .failure(.failed) }
    defer { freeaddrinfo(info) }
    var addresses: [HTTPIPAddress] = []
    var cursor: UnsafeMutablePointer<addrinfo>? = info
    while let node = cursor {
        if let address = httpAddress(node.pointee.ai_addr) {
            if addresses.contains(address) == false {
                addresses.append(address)
            }
        }
        cursor = node.pointee.ai_next
    }
    guard addresses.isEmpty == false else { return .failure(.empty) }
    return .success(addresses)
}

private func httpAddress(_ pointer: UnsafePointer<sockaddr>?) -> HTTPIPAddress? {
    guard let pointer else { return nil }
    if pointer.pointee.sa_family == sa_family_t(AF_INET) {
        let bytes = pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { rebound in
            withUnsafeBytes(of: rebound.pointee.sin_addr) { Array($0) }
        }
        return HTTPIPAddress(ipv4: bytes)
    }
    if pointer.pointee.sa_family == sa_family_t(AF_INET6) {
        let bytes = pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { rebound in
            withUnsafeBytes(of: rebound.pointee.sin6_addr) { Array($0) }
        }
        return HTTPIPAddress(ipv6: bytes)
    }
    return nil
}

private func normalizeRuntimeShell(
    subject: RuntimeAdmissionSubject,
    command: ShellCommand
) -> Result<ProposedAction, RuntimeAdmissionEvaluationError> {
    guard let root = RepositoryRoot(validating: subject.policyWorkspace.rawValue) else {
        return .failure(.failed)
    }
    let analysis = analyzeSemantics(
        command,
        gitWorld: .unprobed,
        filesystemWorld: .probed(
            FilesystemAnalysisContext(
                workingDirectory: subject.policyWorkspace,
                repositoryRoot: root
            )
        )
    )
    let fingerprint = ActionFingerprint(
        rawValue: "runtime:\(subject.session.id.rawValue.uuidString):\(subject.policyWorkspace.rawValue):\(command.rawValue)"
    )
    let scope = ActionScope(workingDirectory: subject.policyWorkspace)
    switch analysis.innermost {
    case .unwrapLimited:
        return .failure(.failed)
    case .git(let git):
        return .success(
            .shell(
                ShellAction(
                    fingerprint: fingerprint,
                    scope: scope,
                    supportingCommand: command,
                    analysis: .git(git)
                )
            )
        )
    case .filesystem(let filesystem):
        return .success(
            .shell(
                ShellAction(
                    fingerprint: fingerprint,
                    scope: scope,
                    supportingCommand: command,
                    analysis: .filesystem(filesystem)
                )
            )
        )
    case .wrapper, .unknown:
        return .success(
            .shell(
                ShellAction(
                    fingerprint: fingerprint,
                    effects: ActionEffects(),
                    resources: ActionResources(),
                    scope: scope,
                    supportingCommand: command
                )
            )
        )
    }
}
