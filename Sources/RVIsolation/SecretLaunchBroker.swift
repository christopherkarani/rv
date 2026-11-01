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

    var message: String {
        switch self {
        case .configuration(let error): error.message
        case .unknownSecret(let name): "secret \(name) is not defined in secrets.json"
        case .resolution(let name, let error): "secret \(name): \(error.message)"
        case .gatewayUnavailable: "secret gateway could not start"
        case .environmentValueUnusable(let name):
            "secret \(name) cannot be delivered as an environment variable (not UTF-8 text or over 8 KiB)"
        case .organizationPolicy(let reason): "organization policy: \(reason)"
        }
    }
}

/// Per-workspace owner of the secret gateway. Each launch leases fresh
/// placeholders; they die with the runtime.
final class SecretLaunchBroker: @unchecked Sendable {
    static let maximumEnvironmentValueBytes = 8_192

    private let configDirectory: URL
    private let resolver: SecretResolver
    private let gateway: SecretGateway
    private let workspace: String?
    private let managed: @Sendable () -> ManagedPolicyState
    private let lock = NSLock()
    private var fingerprinter: SecretFingerprinter??
    private var byRuntime: [String: [SecretPlaceholder]] = [:]

    init(
        configDirectory: URL,
        resolver: SecretResolver,
        transport: SecretUpstreamTransport = .urlSession,
        workspace: String?,
        managed: (@Sendable () -> ManagedPolicyState)? = nil
    ) {
        self.configDirectory = configDirectory
        self.resolver = resolver
        self.workspace = workspace
        self.managed = managed ?? { ManagedPolicyLocation.installed.load(serialsIn: configDirectory) }
        let directory = configDirectory
        gateway = SecretGateway(transport: transport) { record in
            let landed = AuditLog.append(Self.auditEvent(record, workspace: workspace), configDirectory: directory)
            if let finding = Self.misuseEvent(record, workspace: workspace) {
                _ = AuditLog.append(finding, configDirectory: directory)
            }
            return landed
        }
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
            definitions.append(definition)
        }
        var placeholders: [SecretPlaceholder] = []
        var environment: [(name: String, value: String)] = []
        var staged: [AuditEvent] = []
        func fail(_ error: SecretLeaseError) -> Result<SecretLease, SecretLeaseError> {
            gateway.revoke(placeholders)
            return .failure(error)
        }
        for definition in definitions {
            let name = definition.name
            let value: SecretValue
            switch resolver.resolve(definition.source) {
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
                    surfaces: binding.surfaces, rules: binding.rules))
                placeholders.append(placeholder)
                environment.append((name, placeholder.text))
                environment.append((binding.baseURLEnv, baseURL))
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
            case .error: .failed
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
