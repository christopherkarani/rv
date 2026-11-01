import Foundation
import RVHistory
import RVPolicy

/// The environment one launch receives for its profile's secrets, plus the
/// placeholders to revoke when the runtime ends.
struct SecretLease: Sendable {
    let placeholders: [SecretPlaceholder]
    let environment: [(name: String, value: String)]

    static let empty = SecretLease(placeholders: [], environment: [])
}

enum SecretLeaseError: Error, Sendable, Equatable {
    case configuration(SecretsConfigurationError)
    case unknownSecret(String)
    case resolution(secret: String, SecretResolutionError)
    case gatewayUnavailable
    case environmentValueUnusable(String)
    case organizationPolicy(String)
    case expired(secret: String, at: Date)
    /// The profile's output is not a usable credential set. Never quotes it.
    case awsCredentialsUnusable(String)
    /// Two secrets in one launch would set the same variable, e.g. two AWS profiles.
    case variableCollision(variable: String, secrets: [String])

    var message: String {
        switch self {
        case .configuration(let error): error.message
        case .unknownSecret(let name): "secret \(name) is not defined in secrets.json"
        case .resolution(let name, let error): "secret \(name): \(error.message)"
        case .gatewayUnavailable: "secret gateway could not start"
        case .environmentValueUnusable(let name):
            "secret \(name) cannot be delivered as an environment variable (not UTF-8 text or over 8 KiB)"
        case .organizationPolicy(let reason): "organization policy: \(reason)"
        case .expired(let name, let date):
            "secret \(name) expired at \(SecretExpiry.text(date)); store a new value and expiry with "
                + "`rv secrets set \(name) --expires DATE`, or update its expires in secrets.json"
        case .awsCredentialsUnusable(let name):
            "secret \(name): \(AWSSigningBinding.unusableCredentials) "
                + "(expected credential_process JSON with AccessKeyId, SecretAccessKey, and a valid Expiration)"
        case .variableCollision(let variable, let secrets):
            "secrets \(secrets.joined(separator: " and ")) would both set \(variable); stage one per launch"
        }
    }
}

/// Per-workspace owner of the secret gateway. Each launch leases fresh
/// placeholders; they die with the runtime.
final class SecretLaunchBroker: @unchecked Sendable {
    static let maximumEnvironmentValueBytes = 8_192
    /// How often AWS credentials are re-read when `refresh` is unset: well
    /// inside the shortest STS session (15 minutes), so the gateway does not
    /// sign with an expired one.
    static let awsRefreshInterval: TimeInterval = 300

    private let configDirectory: URL
    private let resolver: SecretResolver
    private let gateway: SecretGateway
    private let workspace: String?
    private let managed: @Sendable () -> ManagedPolicyState
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var fingerprinter: SecretFingerprinter??
    private var byRuntime: [String: [SecretPlaceholder]] = [:]

    init(
        configDirectory: URL,
        resolver: SecretResolver,
        transport: SecretUpstreamTransport = .urlSession,
        peers: GatewayPeerCheck = .runtime,
        workspace: String?,
        managed: (@Sendable () -> ManagedPolicyState)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configDirectory = configDirectory
        self.resolver = resolver
        self.workspace = workspace
        self.managed = managed ?? { ManagedPolicyLocation.installed.load(serialsIn: configDirectory) }
        self.now = now
        let directory = configDirectory
        gateway = SecretGateway(
            transport: transport,
            peers: peers,
            audit: { record in
                let landed = AuditLog.append(Self.auditEvent(record, workspace: workspace), configDirectory: directory)
                if let finding = Self.misuseEvent(record, workspace: workspace) {
                    _ = AuditLog.append(finding, configDirectory: directory)
                }
                return landed
            },
            now: now)
    }

    static func production(workspace: String?) -> SecretLaunchBroker? {
        guard let home = ProcessInfo.processInfo.environment["HOME"],
            home.hasPrefix("/"), home.contains("\0") == false
        else { return nil }
        let directory = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("rv", isDirectory: true)
        return SecretLaunchBroker(
            configDirectory: directory, resolver: .live(home: home), workspace: workspace)
    }

    deinit {
        gateway.stop()
    }

    var gatewayPort: Int? { gateway.port }

    /// Resolves `names` for one launch. Secrets whose `agents` filter
    /// excludes `agent` are skipped, mirroring keychain entries. Any other
    /// failure stages nothing.
    func lease(names: [String], agent: String?) -> Result<SecretLease, SecretLeaseError> {
        guard names.isEmpty == false else { return .success(.empty) }
        let configuration: SecretsConfiguration
        switch SecretsConfiguration.load(configDirectory: configDirectory) {
        case .failure(let error): return .failure(.configuration(error))
        case .success(let loaded): configuration = loaded
        }
        let organization: ManagedPolicy?
        switch managed() {
        case .invalid(let reason): return .failure(.organizationPolicy("invalid, so secrets are not staged: \(reason)"))
        case .none: organization = nil
        case .active(let bundle): organization = bundle.policy
        }
        var definitions: [SecretDefinition] = []
        for name in names {
            guard let definition = configuration.secret(named: name) else { return .failure(.unknownSecret(name)) }
            guard definition.stages(forAgent: agent) else { continue }
            if let reason = SecretOrganizationRules.violation(definition, policy: organization) {
                return .failure(.organizationPolicy(reason))
            }
            // Like an unresolvable secret, an expired one fails the launch rather than being dropped.
            if let expires = definition.expires, now() >= expires {
                return .failure(.expired(secret: name, at: expires))
            }
            definitions.append(definition)
        }
        var stagedBy: [String: String] = [:]
        for definition in definitions {
            for variable in definition.stagedVariables {
                if let other = stagedBy.updateValue(definition.name, forKey: variable) {
                    return .failure(.variableCollision(variable: variable, secrets: [other, definition.name]))
                }
            }
        }
        var placeholders: [SecretPlaceholder] = []
        var environment: [(name: String, value: String)] = []
        var staged: [AuditEvent] = []
        func fail(_ error: SecretLeaseError) -> Result<SecretLease, SecretLeaseError> {
            gateway.revoke(placeholders)
            return .failure(error)
        }
        let prefetched = resolver.prefetch(definitions.map(\.source))
        for (index, definition) in definitions.enumerated() {
            let name = definition.name
            // Read before the value, so a write in between shows up as a change.
            // Only gateway entries can rotate.
            let marker = definition.delivery == .environment ? nil : resolver.version(definition.source)
            let value: SecretValue
            switch prefetched[index] ?? resolver.resolve(definition.source) {
            case .failure(let error): return fail(.resolution(secret: name, error))
            case .success(let resolved): value = resolved
            }
            let fingerprint = fingerprint(value)
            switch definition.delivery {
            case .environment:
                guard let text = value.text, text.utf8.count <= Self.maximumEnvironmentValueBytes else {
                    return fail(.environmentValueUnusable(name))
                }
                environment.append((name, text))
            case .gateway(let binding):
                guard case .success = gateway.start(), let baseURL = gateway.baseURL(secret: name) else {
                    return fail(.gatewayUnavailable)
                }
                let placeholder = SecretPlaceholder.mint(prefix: binding.placeholderPrefix)
                gateway.register(placeholder, entry: SecretGateway.Entry(
                    secret: name, prefix: binding.placeholderPrefix, value: value,
                    upstream: binding.upstream, fingerprint: fingerprint, runtime: nil,
                    surfaces: binding.surfaces, rules: binding.rules, expires: definition.expires,
                    refresh: refreshPolicy(definition, marker: marker)))
                placeholders.append(placeholder)
                environment.append((name, placeholder.text))
                environment.append((binding.baseURLEnv, baseURL))
            case .awsSigV4(let binding):
                guard let credentials = AWSCredentialSet(value) else { return fail(.awsCredentialsUnusable(name)) }
                let expires = [definition.expires, credentials.expires].compactMap { $0 }.min()
                if let expires, now() >= expires { return fail(.expired(secret: name, at: expires)) }
                guard case .success = gateway.start(), let baseURL = gateway.baseURL(secret: name) else {
                    return fail(.gatewayUnavailable)
                }
                // The SDK signs with these; the gateway discards that signature.
                let placeholder = SecretPlaceholder.mint(prefix: "")
                gateway.register(placeholder, entry: SecretGateway.Entry(
                    secret: name, prefix: "", value: value, upstream: binding.upstream, fingerprint: fingerprint,
                    runtime: nil, surfaces: [], rules: binding.rules, expires: expires,
                    refresh: refreshPolicy(definition, marker: marker), signing: binding))
                placeholders.append(placeholder)
                environment.append(("AWS_ACCESS_KEY_ID", placeholder.text))
                environment.append(("AWS_SECRET_ACCESS_KEY", Self.throwawaySecret()))
                environment.append(("AWS_REGION", binding.region))
                environment.append((binding.endpointEnv, baseURL))
            }
            staged.append(AuditEvent(
                time: Date(), kind: .secretUse, decision: .info, subject: name,
                reason: "staged for launch", workspace: workspace, agent: agent, source: "secret-broker",
                detail: Self.compact([
                    "event": "staged",
                    "delivery": definition.delivery.kind,
                    "provider": definition.source.kind,
                    "fingerprint": fingerprint,
                ])))
        }
        for event in staged { _ = AuditLog.append(event, configDirectory: configDirectory) }
        return .success(SecretLease(placeholders: placeholders, environment: environment))
    }

    func bind(_ lease: SecretLease, runtime: String) {
        guard lease.placeholders.isEmpty == false else { return }
        gateway.bind(lease.placeholders, runtime: runtime)
        lock.lock()
        byRuntime[runtime, default: []].append(contentsOf: lease.placeholders)
        lock.unlock()
    }

    /// Called once the runtime is spawned and before it runs: from then on
    /// only that runtime's processes may spend the lease.
    func bind(_ lease: SecretLease, processGroup: ProcessGroupFact) {
        guard lease.placeholders.isEmpty == false else { return }
        gateway.bind(lease.placeholders, processGroup: processGroup)
    }

    func revoke(_ lease: SecretLease) {
        gateway.revoke(lease.placeholders)
    }

    func revoke(runtime: String) {
        lock.lock()
        let placeholders = byRuntime.removeValue(forKey: runtime) ?? []
        lock.unlock()
        gateway.revoke(placeholders)
    }

    func stop() {
        lock.lock()
        byRuntime.removeAll()
        lock.unlock()
        gateway.stop()
    }

    var liveCount: Int { gateway.liveCount }

    /// Keychain sources are probed for changes; a `refresh` interval re-reads any source.
    private func refreshPolicy(_ launched: SecretDefinition, marker: String?) -> SecretRefreshPolicy? {
        var probe: (@Sendable () -> String?)?
        if case .keychain = launched.source {
            let resolver = resolver
            probe = { resolver.version(launched.source) }
        }
        var interval = launched.refresh?.timeInterval
        // Session credentials expire, so an AWS profile is always re-read.
        if case .awsSigV4 = launched.delivery { interval = interval ?? Self.awsRefreshInterval }
        guard interval != nil || probe != nil else { return nil }
        return SecretRefreshPolicy(interval: interval, marker: marker, probe: probe) {
            [weak self] in
            guard let self else { return .failure(.providerUnavailable("the workspace secret broker has stopped")) }
            return self.reresolve(launched)
        }
    }

    /// The definition on file now, if it still names the launch source and
    /// delivery. A different one would hand a running placeholder a value
    /// it was never bound to; that needs a new session.
    private func reresolve(_ launched: SecretDefinition) -> Result<SecretRefreshed, SecretResolutionError> {
        let name = launched.name
        guard case .success(let configuration) = SecretsConfiguration.load(configDirectory: configDirectory) else {
            return .failure(.failed("secrets.json could not be read"))
        }
        guard let current = configuration.secret(named: name) else {
            return .failure(.notFound("\(name) is no longer defined in secrets.json"))
        }
        guard current.source == launched.source, current.delivery == launched.delivery else {
            return .failure(.failed("\(name) now has a different source or delivery; start a new session to use it"))
        }
        switch managed() {
        case .invalid(let reason):
            return .failure(.failed("organization policy is invalid: \(reason)"))
        case .active(let bundle):
            if let reason = SecretOrganizationRules.violation(current, policy: bundle.policy) {
                return .failure(.failed("organization policy: \(reason)"))
            }
        case .none:
            break
        }
        return resolver.resolve(current.source).flatMap { value in
            var expires = current.expires
            if case .awsSigV4 = current.delivery {
                guard let credentials = AWSCredentialSet(value) else {
                    return .failure(.invalidValue(AWSSigningBinding.unusableCredentials))
                }
                expires = [expires, credentials.expires].compactMap { $0 }.min()
            }
            return .success(SecretRefreshed(value: value, fingerprint: fingerprint(value), expires: expires))
        }
    }

    /// A random stand-in for `AWS_SECRET_ACCESS_KEY`: SDKs need one to sign,
    /// and the signature it makes is discarded.
    static func throwawaySecret() -> String {
        var generator = SystemRandomNumberGenerator()
        return "rv-unused-" + (0..<20).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }
            .joined()
    }

    private func fingerprint(_ value: SecretValue) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if fingerprinter == nil {
            fingerprinter = .some(SecretFingerprinter.load(configDirectory: configDirectory))
        }
        return (fingerprinter ?? nil)?.fingerprint(value)
    }

    static func auditEvent(_ record: SecretUseRecord, workspace: String?) -> AuditEvent {
        let decision: AuditDecision =
            switch record.activity {
            case .brokered: .allowed
            case .blocked, .refused: .denied
            case .error, .refreshFailed: .failed
            case .refreshed: .info
            }
        if record.activity == .refreshed || record.activity == .refreshFailed {
            return AuditEvent(
                time: Date(), kind: .secretUse, decision: decision, subject: record.secret ?? "unknown",
                reason: record.reason, workspace: workspace, runtime: record.runtime, source: "secret-gateway",
                detail: compact([
                    "event": "refresh",
                    "activity": record.activity.rawValue,
                    "upstream": record.upstreamHost,
                    "fingerprint": record.fingerprint,
                ]))
        }
        return AuditEvent(
            time: Date(),
            kind: .secretUse,
            decision: decision,
            subject: record.secret ?? "unknown",
            reason: record.reason,
            workspace: workspace,
            runtime: record.runtime,
            source: "secret-gateway",
            detail: compact([
                "event": record.stage == .forward ? "forward" : "request",
                "activity": record.activity.rawValue,
                "refusal": record.refusal,
                "method": record.method,
                "path": record.path,
                "surfaces": record.surfaces.isEmpty ? nil : record.surfaces.joined(separator: ","),
                "status": record.stage == .forward ? nil : String(record.status),
                "upstreamStatus": record.upstreamStatus.map(String.init),
                "upstream": record.upstreamHost,
                "fingerprint": record.fingerprint,
                "responseBytes": record.stage == .forward ? nil : String(record.responseBytes),
                "durationMs": record.stage == .forward ? nil : String(record.durationMilliseconds),
            ])
        )
    }

    /// A high-severity finding for a request the secret's own policy refused.
    /// Names the secret, refusal, method, and redacted path; never a value,
    /// placeholder, or query string.
    static func misuseEvent(_ record: SecretUseRecord, workspace: String?) -> AuditEvent? {
        guard record.activity == .blocked, let refusal = record.refusal else { return nil }
        return AuditEvent(
            time: Date(),
            kind: .secretMisuse,
            decision: .denied,
            subject: record.secret ?? "unknown",
            reason: record.reason,
            workspace: workspace,
            runtime: record.runtime,
            source: "secret-gateway",
            detail: ["refusal": refusal, "method": record.method, "path": record.path, "severity": "high"]
        )
    }

    private static func compact(_ values: [String: String?]) -> [String: String] {
        values.compactMapValues { $0 }
    }
}

extension SecretDelivery {
    public var kind: String {
        switch self {
        case .gateway: "gateway"
        case .environment: "environment"
        case .awsSigV4: "awsSigV4"
        }
    }
}

/// What a managed policy forbids for one secret definition.
public enum SecretOrganizationRules {
    public static func violation(_ definition: SecretDefinition, policy: ManagedPolicy?) -> String? {
        guard let policy else { return nil }
        if policy.allowsSecretSource(definition.source.kind) == false {
            return "\(definition.name) uses a \(definition.source.kind) source, which is not allowed"
        }
        if case .environment = definition.delivery, policy.secrets.allowEnvironmentDelivery == false {
            return "\(definition.name) is delivered as an environment variable, which is not allowed; use the gateway"
        }
        return nil
    }
}
