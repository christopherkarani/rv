import Foundation
import RVHistory

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

    var message: String {
        switch self {
        case .configuration(let error): error.message
        case .unknownSecret(let name): "secret \(name) is not defined in secrets.json"
        case .resolution(let name, let error): "secret \(name): \(error.message)"
        case .gatewayUnavailable: "secret gateway could not start"
        case .environmentValueUnusable(let name):
            "secret \(name) cannot be delivered as an environment variable (not UTF-8 text or over 8 KiB)"
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
    private let lock = NSLock()
    private var fingerprinter: SecretFingerprinter??
    private var byRuntime: [String: [SecretPlaceholder]] = [:]

    init(
        configDirectory: URL,
        resolver: SecretResolver,
        transport: SecretUpstreamTransport = .urlSession,
        workspace: String?
    ) {
        self.configDirectory = configDirectory
        self.resolver = resolver
        self.workspace = workspace
        let directory = configDirectory
        gateway = SecretGateway(transport: transport) { record in
            _ = AuditLog.append(Self.auditEvent(record, workspace: workspace), configDirectory: directory)
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
        var placeholders: [SecretPlaceholder] = []
        var environment: [(name: String, value: String)] = []
        func fail(_ error: SecretLeaseError) -> Result<SecretLease, SecretLeaseError> {
            gateway.revoke(placeholders)
            return .failure(error)
        }
        for name in names {
            guard let definition = configuration.secret(named: name) else { return fail(.unknownSecret(name)) }
            guard definition.stages(forAgent: agent) else { continue }
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
                    upstream: binding.upstream, fingerprint: fingerprint, runtime: nil))
                placeholders.append(placeholder)
                environment.append((name, placeholder.text))
                environment.append((binding.baseURLEnv, baseURL))
            }
            _ = AuditLog.append(
                AuditEvent(
                    time: Date(), kind: .secretUse, decision: .info, subject: name,
                    reason: "staged for launch", workspace: workspace, agent: agent, source: "secret-broker",
                    detail: Self.compact([
                        "event": "staged",
                        "delivery": definition.delivery.kind,
                        "provider": definition.source.kind,
                        "fingerprint": fingerprint,
                    ])),
                configDirectory: configDirectory)
        }
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
        AuditEvent(
            time: Date(),
            kind: .secretUse,
            decision: record.allowed ? .allowed : .denied,
            subject: record.secret ?? "unknown",
            reason: record.reason,
            workspace: workspace,
            runtime: record.runtime,
            source: "secret-gateway",
            detail: compact([
                "event": "request",
                "method": record.method,
                "path": record.path,
                "status": String(record.status),
                "upstream": record.upstreamHost,
                "fingerprint": record.fingerprint,
                "responseBytes": String(record.responseBytes),
            ])
        )
    }

    private static func compact(_ values: [String: String?]) -> [String: String] {
        values.compactMapValues { $0 }
    }
}

extension SecretDelivery {
    var kind: String {
        switch self {
        case .gateway: "gateway"
        case .environment: "environment"
        }
    }
}
