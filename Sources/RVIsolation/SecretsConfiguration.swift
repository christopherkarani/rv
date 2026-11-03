#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain

/// Where a secret's real value lives. rv reads it host-side and never stores it.
public enum SecretSource: Sendable, Equatable {
    case keychain(service: String, account: String)
    case hostEnvironment(variable: String)
    /// `op://vault/item/field`, read with the 1Password CLI.
    case onePassword(reference: String)
    /// Vault KV. `address` defaults to `VAULT_ADDR`; the token comes from
    /// `VAULT_TOKEN` or `~/.vault-token`.
    case vault(path: String, field: String, address: URL?)
    /// AWS Secrets Manager via the AWS CLI. `field` picks a key from a JSON secret.
    case awsSecretsManager(secretID: String, field: String?, region: String?)
    /// Infisical via `infisical secrets get`. `environment` is the Infisical env slug.
    case infisical(name: String, project: String?, environment: String?, path: String?)
    /// Bitwarden Secrets Manager via `bws secret get`. `id` is the secret UUID.
    case bitwarden(id: String)
    /// Google Secret Manager via `gcloud secrets versions access`.
    case gcp(secret: String, project: String?, version: String)
    /// Azure Key Vault via `az keyvault secret show`.
    case azure(vault: String, name: String, version: String?)
    /// An AWS CLI profile's credential set, read with
    /// `aws configure export-credentials`. Only `awsSigV4` delivery spends it.
    case awsProfile(profile: String)

    public var kind: String {
        switch self {
        case .keychain: "keychain"
        case .hostEnvironment: "hostEnvironment"
        case .onePassword: "onePassword"
        case .vault: "vault"
        case .awsSecretsManager: "awsSecretsManager"
        case .infisical: "infisical"
        case .bitwarden: "bitwarden"
        case .gcp: "gcp"
        case .azure: "azure"
        case .awsProfile: "awsProfile"
        }
    }
}

/// The agent talks to `http://127.0.0.1:<port>/s/<NAME>` (exported in
/// `baseURLEnv`) carrying a placeholder; rv swaps in the real value and
/// forwards only to `upstream`.
public struct SecretGatewayBinding: Sendable, Equatable {
    public var upstream: URL
    public var baseURLEnv: String
    public var placeholderPrefix: String
    /// Where the placeholder may be swapped; anywhere else is refused.
    public var surfaces: Set<GatewaySurface>
    /// Methods and paths the secret may be used for. Empty allows any.
    public var allow: [GatewayAllowance]
    /// Methods and paths that need a human's approval per request. Empty needs none.
    public var approve: [GatewayAllowance]

    public init(
        upstream: URL, baseURLEnv: String, placeholderPrefix: String = "",
        surfaces: Set<GatewaySurface> = GatewaySurface.defaults, allow: [GatewayAllowance] = [],
        approve: [GatewayAllowance] = []
    ) {
        self.upstream = upstream
        self.baseURLEnv = baseURLEnv
        self.placeholderPrefix = placeholderPrefix
        self.surfaces = surfaces
        self.allow = allow
        self.approve = approve
    }

    /// `allow` with presets expanded.
    public var rules: [GatewayAccessRule] { allow.flatMap(\.rules) }
    /// `approve` with presets expanded.
    public var approvalRules: [GatewayAccessRule] { approve.flatMap(\.rules) }
}

/// AWS SDKs in the cage sign with a placeholder key id against
/// `http://127.0.0.1:<port>/s/<NAME>` (exported in `endpointEnv`); rv drops
/// that signature and re-signs with the real credentials for `upstream`.
public struct AWSSigningBinding: Sendable, Equatable {
    /// Variables rv stages itself for an AWS-signed secret.
    public static let stagedVariables: Set<String> = ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_REGION"]

    /// Signing names whose calls return new credentials (AssumeRole,
    /// CreateAccessKey, GetCredentials, GetAuthorizationToken, ...). The agent
    /// would receive credentials the gateway never scrubs, so no binding may
    /// sign for them.
    public static let credentialMintingServices: Set<String> = [
        "sts", "iam", "sso", "sso-oauth", "awsssoportal", "awsssooidc", "signin", "cognito-identity", "cognito-idp",
        "s3express", "ecr", "ecr-public", "codeartifact",
    ]

    /// Signing names of services that also take their action as a query
    /// parameter on `GET /`, so a method or path rule cannot tell a read from
    /// a write (`GET /?Action=TerminateInstances`).
    public static let queryProtocolServices: Set<String> = [
        "ec2", "sqs", "sns", "rds", "elasticloadbalancing", "autoscaling", "cloudformation", "elasticache", "redshift",
        "ses", "sdb", "cloudsearch", "importexport", "monitoring",
    ]

    public var upstream: URL
    public var region: String
    /// The SigV4 signing name: `s3`, `bedrock`, `ec2`, ...
    public var service: String
    /// `AWS_ENDPOINT_URL` or a per-service `AWS_ENDPOINT_URL_<SERVICE>`.
    public var endpointEnv: String
    /// Methods and paths the secret may be used for. Empty allows any.
    public var allow: [GatewayAllowance]
    /// Methods and paths that need a human's approval per request. Empty needs none.
    public var approve: [GatewayAllowance]

    public init(
        upstream: URL, region: String, service: String, endpointEnv: String, allow: [GatewayAllowance] = [],
        approve: [GatewayAllowance] = []
    ) {
        self.upstream = upstream
        self.region = region
        self.service = service
        self.endpointEnv = endpointEnv
        self.allow = allow
        self.approve = approve
    }

    /// `allow` with presets expanded.
    public var rules: [GatewayAccessRule] { allow.flatMap(\.rules) }
    /// `approve` with presets expanded.
    public var approvalRules: [GatewayAccessRule] { approve.flatMap(\.rules) }

    /// S3 signs the path as sent and accepts unsigned payloads.
    var isS3: Bool { service == "s3" }
}

public enum SecretDelivery: Sendable, Equatable {
    case gateway(SecretGatewayBinding)
    /// Real value in the cage environment. Explicit opt-in; weaker.
    case environment
    /// AWS SigV4 re-signing by the gateway. Requires an `awsProfile` source.
    case awsSigV4(AWSSigningBinding)
}

public struct SecretDefinition: Sendable, Equatable {
    public var name: String
    public var description: String?
    /// Agent tags this secret stages for. Nil stages for every launch whose
    /// profile lists it, including hook-less shells.
    public var agents: [String]?
    public var source: SecretSource
    public var delivery: SecretDelivery
    /// Varlock `@type`, when the secret was imported from a schema. Not a value.
    public var type: String?
    /// From this instant the value is not delivered: launches fail and the gateway refuses.
    public var expires: Date?
    /// Gateway only: re-resolve from the provider this often while a runtime lives.
    public var refresh: SecretRefreshInterval?

    public init(
        name: String,
        description: String? = nil,
        agents: [String]? = nil,
        source: SecretSource,
        delivery: SecretDelivery,
        type: String? = nil,
        expires: Date? = nil,
        refresh: SecretRefreshInterval? = nil
    ) {
        self.name = name
        self.description = description
        self.agents = agents
        self.source = source
        self.delivery = delivery
        self.type = type
        self.expires = expires
        self.refresh = refresh
    }

    func stages(forAgent agent: String?) -> Bool {
        guard let agents else { return true }
        guard let agent else { return false }
        return agents.contains(agent)
    }
}

public struct SecretsConfiguration: Sendable, Equatable {
    public static let fileName = "secrets.json"
    public static let maximumBytes = 256 * 1024
    public static let maximumSecrets = 64

    public var secrets: [SecretDefinition]

    public init(secrets: [SecretDefinition] = []) {
        self.secrets = secrets
    }

    public static let empty = SecretsConfiguration()

    public func secret(named name: String) -> SecretDefinition? {
        secrets.first { $0.name == name }
    }
}

public enum SecretsConfigurationError: Error, Sendable, Equatable {
    case unreadable
    case unsafeFile(String)
    case oversized
    case invalid(String)

    public var message: String {
        switch self {
        case .unreadable: "secrets.json could not be read"
        case .unsafeFile(let why): "secrets.json is not safe to use: \(why)"
        case .oversized: "secrets.json is larger than 256 KiB"
        case .invalid(let why): "secrets.json is invalid: \(why)"
        }
    }
}

extension SecretsConfiguration {
    public static func fileURL(configDirectory: URL) -> URL {
        configDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// The environment variable grammar secret names and exported variables use.
    public static func isVariableName(_ name: String) -> Bool {
        SecretsDecoding.variable(name)
    }

    /// A missing file is an empty configuration. Anything else that is not a
    /// regular, owner-owned, non-group/world-writable file is refused.
    public static func load(configDirectory: URL) -> Result<SecretsConfiguration, SecretsConfigurationError> {
        switch OwnerOnlyFile.read(fileURL(configDirectory: configDirectory), maximumBytes: maximumBytes) {
        case .success(let data?): return decode(data)
        case .success(nil): return .success(.empty)
        case .failure(.unsafe(let reason)): return .failure(.unsafeFile(reason))
        case .failure(.oversized): return .failure(.oversized)
        case .failure(.unreadable): return .failure(.unreadable)
        }
    }

    public static func decode(_ data: Data) -> Result<SecretsConfiguration, SecretsConfigurationError> {
        guard data.count <= maximumBytes else { return .failure(.oversized) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.invalid("not a JSON object"))
        }
        do {
            try SecretsDecoding.onlyKeys(root, ["version", "secrets"], at: "document")
            guard root["version"] as? Int == 1 else { throw SecretsDecoding.Failure("version must be 1") }
            guard let entries = root["secrets"] as? [Any] else {
                throw SecretsDecoding.Failure("secrets must be an array")
            }
            guard entries.count <= maximumSecrets else {
                throw SecretsDecoding.Failure("at most \(maximumSecrets) secrets")
            }
            var names = Set<String>()
            var exported = Set<String>()
            var secrets: [SecretDefinition] = []
            for (index, entry) in entries.enumerated() {
                let secret = try SecretsDecoding.secret(entry, index: index)
                guard names.insert(secret.name).inserted else {
                    throw SecretsDecoding.Failure("duplicate secret \(secret.name)")
                }
                for variable in secret.exportedVariables {
                    guard exported.insert(variable).inserted else {
                        throw SecretsDecoding.Failure("\(variable) is exported by more than one secret")
                    }
                }
                secrets.append(secret)
            }
            return .success(SecretsConfiguration(secrets: secrets))
        } catch let failure as SecretsDecoding.Failure {
            return .failure(.invalid(failure.reason))
        } catch {
            return .failure(.invalid("unreadable entry"))
        }
    }
}

extension SecretDefinition {
    /// Environment names this secret sets in the cage.
    package var exportedVariables: [String] {
        switch delivery {
        case .gateway(let binding): [name, binding.baseURLEnv]
        case .environment: [name]
        // The AWS_* credential variables are shared by every AWS secret, so
        // two in one launch are refused when leased, not here.
        case .awsSigV4(let binding): [binding.endpointEnv]
        }
    }

    /// Every variable a launch staging this secret sets.
    var stagedVariables: [String] {
        guard case .awsSigV4 = delivery else { return exportedVariables }
        return exportedVariables + AWSSigningBinding.stagedVariables.sorted()
    }
}

enum SecretsDecoding {
    struct Failure: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    static let reservedVariables: Set<String> = [
        "PATH", "HOME", "TMPDIR", "TEMP", "TMP", "LANG", "LC_ALL", "TERM", "CLICOLOR", "SHELL", "USER",
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "no_proxy", "all_proxy",
        "PWD", "OLDPWD", "SHLVL",
    ]

    static func onlyKeys(_ object: [String: Any], _ allowed: Set<String>, at place: String) throws {
        if let unknown = object.keys.first(where: { allowed.contains($0) == false }) {
            throw Failure("unknown key \(DisplayedText.field(unknown)) in \(place)")
        }
    }

    static func secret(_ value: Any, index: Int) throws -> SecretDefinition {
        let place = "secrets[\(index)]"
        guard let object = value as? [String: Any] else { throw Failure("\(place) must be an object") }
        try onlyKeys(
            object, ["name", "description", "agents", "source", "delivery", "type", "expires", "refresh"], at: place)
        guard let name = object["name"] as? String, variable(name), reservedVariables.contains(name) == false else {
            throw Failure("\(place).name must be an environment variable name")
        }
        var description: String?
        if let raw = object["description"] {
            guard let text = raw as? String, label(text, max: 256) else {
                throw Failure("\(name).description must be short text")
            }
            description = text
        }
        var agents: [String]?
        if let raw = object["agents"] {
            guard let list = raw as? [String], list.count <= 8, list.allSatisfy(AgentTagValidator.isValid),
                Set(list).count == list.count
            else { throw Failure("\(name).agents must be up to 8 distinct agent tags") }
            agents = list.isEmpty ? nil : list
        }
        var typeName: String?
        if let raw = object["type"] {
            guard let text = raw as? String, label(text, max: 128) else {
                throw Failure("\(name).type must be short text")
            }
            typeName = text
        }
        let source = try self.source(object["source"], secret: name)
        let delivery = try self.delivery(object["delivery"], secret: name)
        // A profile's value is a credential set, not a token, and signing needs one.
        switch (source, delivery) {
        case (.awsProfile, .awsSigV4): break
        case (.awsProfile, _): throw Failure("\(name).source.awsProfile needs awsSigV4 delivery")
        case (_, .awsSigV4): throw Failure("\(name).delivery.awsSigV4 needs an awsProfile source")
        default: break
        }
        var expires: Date?
        if let raw = object["expires"] {
            guard let text = raw as? String, let date = SecretExpiry.parse(text) else {
                throw Failure(
                    "\(name).expires must be an ISO-8601 date (2026-12-31) or date-time with a zone (2026-12-31T18:00:00Z)")
            }
            expires = date
        }
        var refresh: SecretRefreshInterval?
        if let raw = object["refresh"] {
            guard let text = raw as? String, let interval = SecretRefreshInterval(text) else {
                throw Failure("\(name).refresh must be a whole number of s, m, h, or d from 1m to 30d, such as 15m")
            }
            if case .environment = delivery {
                throw Failure(
                    "\(name).refresh applies to gateway delivery; a value in the environment cannot change after launch")
            }
            refresh = interval
        }
        return SecretDefinition(
            name: name, description: description, agents: agents, source: source, delivery: delivery, type: typeName,
            expires: expires, refresh: refresh)
    }

    static func single(_ value: Any?, secret: String, field: String) throws -> (String, [String: Any]) {
        guard let object = value as? [String: Any], object.count == 1,
            let (kind, body) = object.first, let fields = body as? [String: Any]
        else { throw Failure("\(secret).\(field) must name exactly one kind") }
        return (kind, fields)
    }

    static func source(_ value: Any?, secret: String) throws -> SecretSource {
        let (kind, fields) = try single(value, secret: secret, field: "source")
        let place = "\(secret).source.\(kind)"
        switch kind {
        case "keychain":
            try onlyKeys(fields, ["service", "account"], at: place)
            guard let service = fields["service"] as? String, label(service, max: 256),
                let account = fields["account"] as? String, label(account, max: 256)
            else { throw Failure("\(place) needs service and account") }
            return .keychain(service: service, account: account)
        case "hostEnvironment":
            try onlyKeys(fields, ["variable"], at: place)
            guard let variable = fields["variable"] as? String, self.variable(variable) else {
                throw Failure("\(place).variable must be an environment variable name")
            }
            return .hostEnvironment(variable: variable)
        case "onePassword":
            try onlyKeys(fields, ["reference"], at: place)
            guard let reference = fields["reference"] as? String, reference.hasPrefix("op://"),
                label(reference, max: 512), reference.contains(" ") == false
            else { throw Failure("\(place).reference must be an op:// reference") }
            return .onePassword(reference: reference)
        case "vault":
            try onlyKeys(fields, ["path", "field", "address"], at: place)
            guard let path = fields["path"] as? String, vaultPath(path),
                let field = fields["field"] as? String, label(field, max: 128)
            else { throw Failure("\(place) needs a KV path and field") }
            var address: URL?
            if let raw = fields["address"] {
                guard let text = raw as? String, let url = httpsOrigin(text) else {
                    throw Failure("\(place).address must be an https URL")
                }
                address = url
            }
            return .vault(path: path, field: field, address: address)
        case "awsSecretsManager":
            try onlyKeys(fields, ["secretID", "field", "region"], at: place)
            guard let secretID = fields["secretID"] as? String, label(secretID, max: 512),
                secretID.hasPrefix("-") == false
            else { throw Failure("\(place).secretID is required") }
            var field: String?
            if let raw = fields["field"] {
                guard let text = raw as? String, label(text, max: 128) else { throw Failure("\(place).field is invalid") }
                field = text
            }
            var region: String?
            if let raw = fields["region"] {
                guard let text = raw as? String, regionName(text) else { throw Failure("\(place).region is invalid") }
                region = text
            }
            return .awsSecretsManager(secretID: secretID, field: field, region: region)
        case "infisical":
            try onlyKeys(fields, ["name", "project", "environment", "path"], at: place)
            guard let secretName = fields["name"] as? String, cliToken(secretName) else {
                throw Failure("\(place).name is required")
            }
            let project = try optionalToken(fields["project"], "\(place).project")
            let environment = try optionalToken(fields["environment"], "\(place).environment")
            let path = try optionalToken(fields["path"], "\(place).path")
            return .infisical(name: secretName, project: project, environment: environment, path: path)
        case "bitwarden":
            try onlyKeys(fields, ["id"], at: place)
            guard let id = fields["id"] as? String, uuid(id) else {
                throw Failure("\(place).id must be a UUID")
            }
            return .bitwarden(id: id.lowercased())
        case "gcp":
            try onlyKeys(fields, ["secret", "project", "version"], at: place)
            guard let secretName = fields["secret"] as? String, cliToken(secretName) else {
                throw Failure("\(place).secret is required")
            }
            let project = try optionalToken(fields["project"], "\(place).project")
            let version = (fields["version"] as? String) ?? "latest"
            guard cliToken(version) else { throw Failure("\(place).version is invalid") }
            return .gcp(secret: secretName, project: project, version: version)
        case "azure":
            try onlyKeys(fields, ["vault", "name", "version"], at: place)
            guard let vault = fields["vault"] as? String, cliToken(vault),
                let secretName = fields["name"] as? String, cliToken(secretName)
            else { throw Failure("\(place) needs vault and name") }
            let version = try optionalToken(fields["version"], "\(place).version")
            return .azure(vault: vault, name: secretName, version: version)
        case "awsProfile":
            try onlyKeys(fields, ["profile"], at: place)
            guard let profile = fields["profile"] as? String, profile.utf8.count <= 64, profile.hasPrefix("-") == false,
                profile.isEmpty == false, profile.utf8.allSatisfy({ placeholderByte($0) || $0 == 46 })
            else { throw Failure("\(place).profile must be an AWS profile name: letters, digits, ., _ or -") }
            return .awsProfile(profile: profile)
        default:
            throw Failure("\(secret).source kind \(DisplayedText.field(kind)) is not supported")
        }
    }

    static func delivery(_ value: Any?, secret: String) throws -> SecretDelivery {
        let (kind, fields) = try single(value, secret: secret, field: "delivery")
        let place = "\(secret).delivery.\(kind)"
        switch kind {
        case "environment":
            try onlyKeys(fields, [], at: place)
            return .environment
        case "gateway":
            try onlyKeys(
                fields, ["upstream", "baseURLEnv", "placeholderPrefix", "surfaces", "allow", "approve"], at: place)
            guard let text = fields["upstream"] as? String, let upstream = httpsUpstream(text) else {
                throw Failure("\(place).upstream must be an https URL without credentials, query, or fragment")
            }
            guard let baseURLEnv = fields["baseURLEnv"] as? String, variable(baseURLEnv),
                reservedVariables.contains(baseURLEnv) == false, baseURLEnv != secret
            else { throw Failure("\(place).baseURLEnv must be a distinct environment variable name") }
            let prefix = fields["placeholderPrefix"] as? String ?? ""
            guard prefix.utf8.count <= 32, prefix.utf8.allSatisfy(placeholderByte) else {
                throw Failure("\(place).placeholderPrefix must be up to 32 letters, digits, _ or -")
            }
            let surfaces = try self.surfaces(fields["surfaces"], at: "\(place).surfaces")
            let allow = try self.allow(fields["allow"], at: "\(place).allow")
            let approve = try self.allow(fields["approve"], at: "\(place).approve")
            return .gateway(SecretGatewayBinding(
                upstream: upstream, baseURLEnv: baseURLEnv, placeholderPrefix: prefix, surfaces: surfaces,
                allow: allow, approve: approve))
        case "awsSigV4":
            try onlyKeys(fields, ["upstream", "region", "service", "endpointEnv", "allow", "approve"], at: place)
            guard let text = fields["upstream"] as? String, let upstream = httpsUpstream(text) else {
                throw Failure("\(place).upstream must be an https URL without credentials, query, or fragment")
            }
            // Both are credential-scope parts: `/` or spaces would forge another scope.
            guard let region = fields["region"] as? String, regionName(region) else {
                throw Failure("\(place).region must be an AWS region such as us-east-1")
            }
            guard let service = fields["service"] as? String, regionName(service) else {
                throw Failure("\(place).service must be the SigV4 signing name, such as s3 or bedrock")
            }
            guard let endpointEnv = fields["endpointEnv"] as? String, variable(endpointEnv),
                reservedVariables.contains(endpointEnv) == false,
                AWSSigningBinding.stagedVariables.contains(endpointEnv) == false, endpointEnv != secret
            else {
                throw Failure("\(place).endpointEnv must be a distinct variable such as AWS_ENDPOINT_URL_S3")
            }
            guard AWSSigningBinding.credentialMintingServices.contains(service) == false else {
                throw Failure("\(place).service \(service) mints credentials, which would reach the agent unscrubbed")
            }
            let allow = try self.allow(fields["allow"], at: "\(place).allow")
            if AWSSigningBinding.queryProtocolServices.contains(service), allow.contains(.preset(.readOnly)) {
                throw Failure(
                    "\(place).allow read-only cannot limit \(service): it takes its action as a query parameter on GET; "
                        + "scope the profile's IAM policy instead")
            }
            let approve = try self.allow(fields["approve"], at: "\(place).approve")
            return .awsSigV4(AWSSigningBinding(
                upstream: upstream, region: region, service: service, endpointEnv: endpointEnv, allow: allow,
                approve: approve))
        default:
            throw Failure("\(secret).delivery kind \(DisplayedText.field(kind)) is not supported")
        }
    }

    /// Absent means the default. Present must be a non-empty list of
    /// distinct known names, so a typo never widens or silently narrows.
    static func surfaces(_ value: Any?, at place: String) throws -> Set<GatewaySurface> {
        guard let value else { return GatewaySurface.defaults }
        let names = GatewaySurface.allCases.map(\.rawValue).joined(separator: ", ")
        guard let list = value as? [String], list.isEmpty == false, Set(list).count == list.count else {
            throw Failure("\(place) must list distinct surfaces from \(names)")
        }
        let surfaces = list.compactMap(GatewaySurface.init(rawValue:))
        guard surfaces.count == list.count else { throw Failure("\(place) must list distinct surfaces from \(names)") }
        return Set(surfaces)
    }

    /// Absent allows everything. Present must be non-empty, so `[]` cannot
    /// be mistaken for "allow nothing".
    static func allow(_ value: Any?, at place: String) throws -> [GatewayAllowance] {
        guard let value else { return [] }
        guard let list = value as? [Any], list.isEmpty == false, list.count <= GatewayAllowance.maximumEntries else {
            throw Failure("\(place) must list 1 to \(GatewayAllowance.maximumEntries) presets or rules")
        }
        let presets = GatewayAccessPreset.allCases.map(\.rawValue).joined(separator: ", ")
        return try list.enumerated().map { index, entry in
            let at = "\(place)[\(index)]"
            if let name = entry as? String {
                guard let preset = GatewayAccessPreset(rawValue: name) else {
                    throw Failure("\(at) preset \(DisplayedText.field(name)) is unknown; use \(presets)")
                }
                return .preset(preset)
            }
            guard let object = entry as? [String: Any] else {
                throw Failure("\(at) must be a preset name or {methods, path}")
            }
            try onlyKeys(object, ["methods", "path"], at: at)
            let methods: Set<String>?
            switch object["methods"] {
            case let star as String where star == "*":
                methods = nil
            case let names as [String] where Set(names).count == names.count:
                methods = Set(names)
            default:
                throw Failure("\(at).methods must be \"*\" or a list of distinct upper-case HTTP methods")
            }
            guard let path = object["path"] as? String else {
                throw Failure("\(at).path must be a /-rooted glob")
            }
            guard let rule = GatewayAccessRule(methods: methods, path: path) else {
                if let methods, methods.isEmpty || methods.count > GatewayAccessRule.maximumMethods
                    || methods.allSatisfy(GatewayAccessRule.isMethod) == false
                {
                    throw Failure("\(at).methods must be \"*\" or a list of distinct upper-case HTTP methods")
                }
                throw Failure(
                    "\(at).path must be a /-rooted glob without . or .. segments, //, %, ?, #, ;, or \\, "
                        + "and at most two **")
            }
            return .rule(rule)
        }
    }

    static func variable(_ value: String) -> Bool {
        guard let first = value.utf8.first, value.utf8.count <= 64,
            (first >= 65 && first <= 90) || (first >= 97 && first <= 122) || first == 95
        else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95
        }
    }

    /// A CLI argument: no leading dash, no whitespace, no NUL.
    static func cliToken(_ value: String) -> Bool {
        value.isEmpty == false && value.utf8.count <= 256 && value.hasPrefix("-") == false
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII && scalar.value > 32 && scalar != "\"" && scalar != "'" && scalar != "\\"
            }
    }

    static func optionalToken(_ value: Any?, _ place: String) throws -> String? {
        guard let value else { return nil }
        guard let text = value as? String, cliToken(text) else { throw Failure("\(place) is invalid") }
        return text
    }

    static func uuid(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        let lengths = [8, 4, 4, 4, 12]
        guard parts.count == 5, zip(parts, lengths).allSatisfy({ $0.count == $1 }) else { return false }
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        return parts.joined().unicodeScalars.allSatisfy { hex.contains($0) }
    }

    static func label(_ value: String, max: Int) -> Bool {
        value.isEmpty == false && value.utf8.count <= max
            && value.unicodeScalars.allSatisfy { scalar in
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator: false
                default: true
                }
            }
    }

    static func placeholderByte(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
            || byte == 95 || byte == 45
    }

    static func vaultPath(_ value: String) -> Bool {
        value.isEmpty == false && value.utf8.count <= 512 && value.hasPrefix("/") == false
            && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                $0.isEmpty == false && $0 != "." && $0 != ".."
                    && $0.utf8.allSatisfy { placeholderByte($0) || $0 == 46 }
            }
    }

    static func regionName(_ value: String) -> Bool {
        value.isEmpty == false && value.utf8.count <= 32
            && value.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 }
    }

    static func httpsUpstream(_ text: String) -> URL? {
        guard let components = URLComponents(string: text), components.scheme?.lowercased() == "https",
            let host = components.host, host.isEmpty == false,
            components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil,
            text.utf8.count <= 512, text.contains("\\") == false
        else { return nil }
        var normalized = components
        normalized.scheme = "https"
        normalized.host = host.lowercased()
        if normalized.path.hasSuffix("/") { normalized.path.removeLast() }
        return normalized.url
    }

    static func httpsOrigin(_ text: String) -> URL? {
        guard let url = httpsUpstream(text), URLComponents(url: url, resolvingAgainstBaseURL: false)?.path.isEmpty == true
        else { return nil }
        return url
    }
}
