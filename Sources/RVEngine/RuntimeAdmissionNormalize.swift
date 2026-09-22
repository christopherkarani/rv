#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import RVDomain

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
/// produces no HTTP action. This call blocks. Contained launch uses
/// `resolveAdmittedHTTPHost`, which keeps the session reaper running.
public func resolveHTTPHost(_ name: String) -> Result<[HTTPIPAddress], HTTPResolutionError> {
    var hints = addrinfo()
    hints.ai_flags = AI_ADDRCONFIG
    hints.ai_family = AF_UNSPEC
    #if canImport(Darwin)
    hints.ai_socktype = SOCK_STREAM
    hints.ai_protocol = IPPROTO_TCP
    #else
    hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
    hints.ai_protocol = Int32(IPPROTO_TCP)
    #endif
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
