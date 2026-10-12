#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVFileStore

public enum MCPIntegrationStoreError: Error, Sendable, Equatable {
    case unsafeLocation
    case unreadable
    case oversized
    case invalidDocument
    case unsupportedVersion
}

/// Transport preference for a remote MCP server.
///
/// Mirrors Executor `McpRemoteTransport` (`streamable-http` | `sse` | `auto`)
/// from `packages/plugins/mcp/src/sdk/types.ts`. Absent on the wire reads as
/// `.auto`, matching Executor's constructor default.
public enum MCPRemoteTransport: String, Sendable, Equatable {
    case streamableHttp = "streamable-http"
    case sse = "sse"
    case auto = "auto"
}

/// Structured secret reference naming one broker secret.
///
/// # Executor mapping
///
/// Executor header values carry secret references as opaque strings,
/// `secret-public-ref:<id>` (`packages/core/config/src/schema.ts`
/// `SECRET_REF_PREFIX`, produced by `sink.ts` `headerToConfigValue`). RV has
/// no opaque id space: every reference is a structured
/// `SecretRef(provider:item:field:)` triple. The mapping between the two:
///
/// - The RV string form is `secret-public-ref:<provider>/<item>`, split at
///   the FIRST `/` (provider ids never contain `/`; items often do, e.g.
///   `github/token`). The provider must be allowlisted and the item must
///   satisfy `SecretLabels.isValidItem`, else the reference fails closed.
/// - The string form carries no field. Field-bearing references use the
///   object form `{"provider": p, "item": i, "field": f}` only;
///   `executorRef` returns nil when `field` is present.
/// - Executor's `{value, prefix}` object form is NOT accepted: a literal with
///   a prefix is expressible as the literal itself, so RV folds Executor's
///   three header-value forms into two (literal string | secret object).
/// - Canonical encoding always writes the object form, so decode normalizes
///   string forms to objects; `decode(encode(x)) == x` still holds.
public struct MCPSecretSelector: Sendable, Equatable, Encodable {
    /// Executor's reference marker, reused as the RV string-form marker.
    public static let executorRefPrefix = "secret-public-ref:"

    public let provider: String
    public let item: String
    public let field: String?

    public init(provider: String, item: String, field: String? = nil) {
        self.provider = provider
        self.item = item
        self.field = field
    }

    /// The broker ref this selector names, or nil when the provider is
    /// unknown or a label is invalid. `SecretRef` itself only checks the
    /// provider allowlist and item non-emptiness (fields pass through), so
    /// the item/field rules apply here too: hand-built selectors that never
    /// saw store validation still fail closed.
    public var ref: SecretRef? {
        guard SecretLabels.isValidItem(item),
            field.map(SecretLabels.isValidField) ?? true
        else { return nil }
        return try? SecretRef(provider: provider, item: item, field: field)
    }

    /// The Executor string form, or nil when the selector has a field (no
    /// string form) or fails validation.
    public var executorRef: String? {
        guard field == nil,
            SecretRef.allowedProviders.contains(provider),
            SecretLabels.isValidItem(item)
        else { return nil }
        return "\(Self.executorRefPrefix)\(provider)/\(item)"
    }

    /// Parses the Executor string form, or nil when the shape is wrong or
    /// the provider/item fails validation.
    public init?(executorRef value: String) {
        guard let parsed = Self.parseExecutorRef(value),
            SecretRef.allowedProviders.contains(parsed.provider),
            SecretLabels.isValidItem(parsed.item)
        else { return nil }
        self.init(provider: parsed.provider, item: parsed.item, field: nil)
    }

    /// Splits the string form into provider/item without validating either:
    /// shape only. Validation happens in `init?(executorRef:)` and in store
    /// resolution, so both entry points share one shape rule.
    static func parseExecutorRef(_ value: String) -> (provider: String, item: String)? {
        guard value.hasPrefix(executorRefPrefix) else { return nil }
        let rest = value.dropFirst(executorRefPrefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let provider = rest[..<slash]
        let item = rest[rest.index(after: slash)...]
        guard !provider.isEmpty, !item.isEmpty else { return nil }
        return (String(provider), String(item))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictJSONKey.self)
        try container.encode(provider, forKey: StrictJSONKey("provider"))
        try container.encode(item, forKey: StrictJSONKey("item"))
        try container.encodeIfPresent(field, forKey: StrictJSONKey("field"))
    }
}

/// One header (or query-param) value: a literal or a broker secret.
///
/// Literals are operator-visible config, never secret material. Secrets are
/// refs only; resolution happens at invoke time via `MCPSecretSelector.ref`.
///
/// Render contract (X1-J1): literals may hold URL metacharacters (`& = # ?`
/// and friends) by design, so the renderer MUST percent-encode query pairs
/// and MUST emit header values as single field values, never concatenated
/// into a larger string the server would re-split.
public enum MCPHeaderValue: Sendable, Equatable, Encodable {
    case literal(String)
    case secret(MCPSecretSelector, prefix: String?)

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .literal(let value):
            var single = encoder.singleValueContainer()
            try single.encode(value)
        case .secret(let selector, let prefix):
            var container = encoder.container(keyedBy: StrictJSONKey.self)
            try container.encode(selector, forKey: StrictJSONKey("secret"))
            try container.encodeIfPresent(prefix, forKey: StrictJSONKey("prefix"))
        }
    }
}

/// Auth declaration for a remote MCP integration.
///
/// Mirrors Executor `McpAuthConfig` (`none | header | oauth2`) from
/// `packages/core/config/src/schema.ts`. The header variant's `secret` is a
/// `MCPSecretSelector` (never literal credential material); the oauth2
/// variant names the connection holding token material by stable id.
///
/// Credential-shape map: this enum is the STORED declaration (refs and
/// labels only, never secret material). At invoke time the broker resolves
/// it into a `ToolInvocationCredential` (resolved values, one call only);
/// on failure paths the JSON-RPC error taxonomy reports it as an
/// `MCPAuthCredential` (label bundle: kind + label, never values). The three
/// never mix: declarations live in config, resolved values live in memory,
/// labels live in errors and logs.
public enum MCPAuthConfig: Sendable, Equatable, Encodable {
    case none
    case header(headerName: String, secret: MCPSecretSelector, prefix: String?)
    case oauth2(connectionId: String)

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictJSONKey.self)
        switch self {
        case .none:
            try container.encode("none", forKey: StrictJSONKey("kind"))
        case .header(let headerName, let secret, let prefix):
            try container.encode("header", forKey: StrictJSONKey("kind"))
            try container.encode(headerName, forKey: StrictJSONKey("headerName"))
            try container.encode(secret, forKey: StrictJSONKey("secret"))
            try container.encodeIfPresent(prefix, forKey: StrictJSONKey("prefix"))
        case .oauth2(let connectionId):
            try container.encode("oauth2", forKey: StrictJSONKey("kind"))
            try container.encode(connectionId, forKey: StrictJSONKey("connectionId"))
        }
    }
}

/// A remote (streamable-HTTP/SSE) MCP integration.
///
/// `remoteTransport` and `auth` are non-optional with Executor-matching
/// defaults (`.auto` / `.none`); absent on the wire reads as the default
/// and the canonical encoding omits defaulted members.
public struct MCPRemoteIntegration: Sendable, Equatable, Encodable {
    public let name: String
    public let endpoint: String
    public let remoteTransport: MCPRemoteTransport
    public let namespace: String?
    public let queryParams: [String: MCPHeaderValue]?
    public let headers: [String: MCPHeaderValue]?
    public let auth: MCPAuthConfig

    /// Validated construction: every value faces the store's
    /// `validateRemote` rules, so invalid models are unrepresentable outside
    /// this file. Throws `.invalidDocument` (labels only) on any violation.
    public init(
        name: String,
        endpoint: String,
        remoteTransport: MCPRemoteTransport = .auto,
        namespace: String? = nil,
        queryParams: [String: MCPHeaderValue]? = nil,
        headers: [String: MCPHeaderValue]? = nil,
        auth: MCPAuthConfig = .none
    ) throws(MCPIntegrationStoreError) {
        self.init(
            unchecked: name, endpoint: endpoint, remoteTransport: remoteTransport,
            namespace: namespace, queryParams: queryParams, headers: headers, auth: auth
        )
        if MCPIntegrationStore.validateRemote(self) != nil {
            throw MCPIntegrationStoreError.invalidDocument
        }
    }

    /// Unchecked construction for the store's decode path (which validates
    /// through `validateRemote` for per-field reasons) and for tests that
    /// need invalid models: the sink's defense-in-depth round-trip guard is
    /// reachable only with one. Production callers use the throwing init.
    init(
        unchecked name: String,
        endpoint: String,
        remoteTransport: MCPRemoteTransport = .auto,
        namespace: String? = nil,
        queryParams: [String: MCPHeaderValue]? = nil,
        headers: [String: MCPHeaderValue]? = nil,
        auth: MCPAuthConfig = .none
    ) {
        self.name = name
        self.endpoint = endpoint
        self.remoteTransport = remoteTransport
        self.namespace = namespace
        self.queryParams = queryParams
        self.headers = headers
        self.auth = auth
    }

    /// Explicit namespace, or the derived one when absent.
    public var resolvedNamespace: String {
        namespace ?? MCPIntegrationStore.deriveNamespace(name: name, endpoint: endpoint, command: nil)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictJSONKey.self)
        try container.encode("mcp-remote", forKey: StrictJSONKey("kind"))
        try container.encode(name, forKey: StrictJSONKey("name"))
        try container.encode(endpoint, forKey: StrictJSONKey("endpoint"))
        if remoteTransport != .auto {
            try container.encode(remoteTransport.rawValue, forKey: StrictJSONKey("remoteTransport"))
        }
        try container.encodeIfPresent(namespace, forKey: StrictJSONKey("namespace"))
        try container.encodeIfPresent(queryParams, forKey: StrictJSONKey("queryParams"))
        try container.encodeIfPresent(headers, forKey: StrictJSONKey("headers"))
        if auth != .none {
            try container.encode(auth, forKey: StrictJSONKey("auth"))
        }
    }
}

/// A stdio-spawned MCP integration.
///
/// `env` carries static literals only: any value wearing the secret-ref
/// marker fails closed, since refs are meaningless to `execve` and would
/// leak the marker into the child environment. Secret-bearing stdio env is
/// a render-time concern, not a stored one.
///
/// Spawn contract (X1-J1): `args` are `exec` argv elements — never joined
/// into a shell string — and `cwd` is a `chdir` target, never `cd` through
/// a shell. Only `command` is shell-metachar-free by construction; the rest
/// stays shell-free by spawn construction.
public struct MCPStdioIntegration: Sendable, Equatable, Encodable {
    public let name: String
    public let command: String
    public let args: [String]?
    public let env: [String: String]?
    public let cwd: String?
    public let namespace: String?

    /// Validated construction: every value faces the store's
    /// `validateStdio` rules, so invalid models are unrepresentable outside
    /// this file. Throws `.invalidDocument` (labels only) on any violation.
    public init(
        name: String,
        command: String,
        args: [String]? = nil,
        env: [String: String]? = nil,
        cwd: String? = nil,
        namespace: String? = nil
    ) throws(MCPIntegrationStoreError) {
        self.init(
            unchecked: name, command: command, args: args,
            env: env, cwd: cwd, namespace: namespace
        )
        if MCPIntegrationStore.validateStdio(self) != nil {
            throw MCPIntegrationStoreError.invalidDocument
        }
    }

    /// Unchecked construction for the store's decode path (which validates
    /// through `validateStdio` for per-field reasons) and for tests that
    /// need invalid models. Production callers use the throwing init.
    init(
        unchecked name: String,
        command: String,
        args: [String]? = nil,
        env: [String: String]? = nil,
        cwd: String? = nil,
        namespace: String? = nil
    ) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.cwd = cwd
        self.namespace = namespace
    }

    /// Explicit namespace, or the derived one when absent.
    public var resolvedNamespace: String {
        namespace ?? MCPIntegrationStore.deriveNamespace(name: name, endpoint: nil, command: command)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictJSONKey.self)
        try container.encode("mcp-stdio", forKey: StrictJSONKey("kind"))
        try container.encode(name, forKey: StrictJSONKey("name"))
        try container.encode(command, forKey: StrictJSONKey("command"))
        try container.encodeIfPresent(args, forKey: StrictJSONKey("args"))
        try container.encodeIfPresent(env, forKey: StrictJSONKey("env"))
        try container.encodeIfPresent(cwd, forKey: StrictJSONKey("cwd"))
        try container.encodeIfPresent(namespace, forKey: StrictJSONKey("namespace"))
    }
}

/// One MCP integration: remote or stdio.
///
/// The wire discriminator is a single `kind` (`mcp-remote` | `mcp-stdio`),
/// folding Executor's `kind: "mcp"` + `transport` pair into one key. This is
/// the type downstream X1-J1 consumes; it stays minimal (validated config
/// only, no discovery state) but complete (every field J1 renders).
public enum MCPIntegrationConfig: Sendable, Equatable, Encodable {
    case remote(MCPRemoteIntegration)
    case stdio(MCPStdioIntegration)

    /// Display name. Always non-empty after store validation.
    public var name: String {
        switch self {
        case .remote(let remote): return remote.name
        case .stdio(let stdio): return stdio.name
        }
    }

    /// Explicit namespace, or nil when derivation applies.
    public var explicitNamespace: String? {
        switch self {
        case .remote(let remote): return remote.namespace
        case .stdio(let stdio): return stdio.namespace
        }
    }

    /// Identity key: explicit namespace, else derived. Unique per document.
    public var resolvedNamespace: String {
        switch self {
        case .remote(let remote): return remote.resolvedNamespace
        case .stdio(let stdio): return stdio.resolvedNamespace
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .remote(let remote): try remote.encode(to: encoder)
        case .stdio(let stdio): try stdio.encode(to: encoder)
        }
    }
}

/// Validated integrations loaded from `mcp-integrations.json`.
public struct MCPIntegrationSet: Sendable, Equatable {
    public let integrations: [MCPIntegrationConfig]

    public init(integrations: [MCPIntegrationConfig]) {
        self.integrations = integrations
    }

    public static let empty = MCPIntegrationSet(integrations: [])

    /// Integration with this resolved namespace, or nil.
    public func integration(namespace: String) -> MCPIntegrationConfig? {
        integrations.first { $0.resolvedNamespace == namespace }
    }
}

/// Loads trusted operator MCP integrations from `mcp-integrations.json`.
///
/// Integrations come ONLY from this operator config file, under the same
/// owner-only, no-symlink, 64KB discipline as the sibling stores
/// (`OwnerOnlyFile.loadBytes`). The document is versioned (`{"version": 1,
/// "integrations": [...]}`) with closed key sets at every level: unknown
/// fields fail closed, so a security-critical field RV does not understand
/// (or secret material smuggled under any name) can never slip through.
/// Every failure mode fails closed.
///
/// This is a v1-only store with no legacy documents to migrate, so unlike
/// the sibling stores it performs no one-shot migration rewrite.
public enum MCPIntegrationStore {
    public static let maximumBytes = 65_536
    public static let maximumIntegrations = 32
    /// Per-map cap: `headers` and `queryParams` each hold at most this many.
    public static let maximumHeaders = 32
    public static let maximumArgs = 64
    public static let maximumEnv = 32
    public static let fileName = "mcp-integrations.json"

    public static func load(from configDirectory: URL) -> Result<MCPIntegrationSet, MCPIntegrationStoreError> {
        switch OwnerOnlyFile.loadBytes(
            fileName: fileName, from: configDirectory, maximumBytes: maximumBytes
        ) {
        case .success(let data):
            return decode(data)
        case .failure(let error):
            return mapLoadFailure(error)
        }
    }

    /// Maps a file-read failure onto the store outcome. Split out (rather
    /// than inlined like the siblings) so every arm is directly testable:
    /// `.unreadable` has no filesystem trigger, only a unit one.
    static func mapLoadFailure(_ error: OwnerOnlyFileError) -> Result<MCPIntegrationSet, MCPIntegrationStoreError> {
        switch error {
        case .missing:
            return .success(.empty)
        case .inaccessible, .unsafeLocation:
            return .failure(.unsafeLocation)
        case .unreadable:
            return .failure(.unreadable)
        case .oversized:
            return .failure(.oversized)
        }
    }

    public static func decode(_ data: Data) -> Result<MCPIntegrationSet, MCPIntegrationStoreError> {
        guard data.count <= maximumBytes else { return .failure(.oversized) }
        guard let document = try? JSONDecoder().decode(MCPIntegrationDocumentDTO.self, from: data) else {
            return .failure(.invalidDocument)
        }
        guard document.version == 1 else { return .failure(.unsupportedVersion) }
        guard document.integrations.count <= maximumIntegrations else { return .failure(.invalidDocument) }
        var seen = Set<String>()
        var integrations: [MCPIntegrationConfig] = []
        for dto in document.integrations {
            guard let config = resolve(dto) else { return .failure(.invalidDocument) }
            let namespace = config.resolvedNamespace
            guard seen.insert(namespace).inserted else { return .failure(.invalidDocument) }
            integrations.append(config)
        }
        return .success(MCPIntegrationSet(integrations: integrations))
    }

    /// Canonical bytes for `set`: compact JSON, sorted keys, unescaped
    /// slashes, defaults omitted. Fails `.oversized` when the encoding
    /// exceeds the read cap
    /// (per-field caps bound each member, not the total, so a single
    /// maxed-out integration can overflow). The encode step itself cannot
    /// fail for this schema, so its impossible failure shares the oversized
    /// block rather than owning dead code.
    public static func encode(_ set: MCPIntegrationSet) -> Result<Data, MCPIntegrationStoreError> {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let bytes = try? encoder.encode(MCPIntegrationDocument(version: 1, integrations: set.integrations)),
            bytes.count <= maximumBytes
        else { return .failure(.oversized) }
        return .success(bytes)
    }

    /// Derives a namespace when none is explicit. Mirrors Executor
    /// `deriveMcpNamespace` (`packages/plugins/mcp/src/sdk/manifest.ts`)
    /// exactly: non-blank name wins, else the endpoint hostname, else the
    /// command basename, else `"mcp"`; each candidate is slugified and an
    /// empty slug falls back to `"mcp"`.
    public static func deriveNamespace(name: String, endpoint: String?, command: String?) -> String {
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let slug = slugifyNamespace(name)
            return slug.isEmpty ? "mcp" : slug
        }
        if let endpoint, !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let host = hostnameOf(endpoint: endpoint)
        {
            let slug = slugifyNamespace(host)
            return slug.isEmpty ? "mcp" : slug
        }
        if let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let slug = slugifyNamespace(basenameOf(command: command))
            return slug.isEmpty ? "mcp" : slug
        }
        return "mcp"
    }

    /// Executor `slugify`: lowercase, every non-`[a-z0-9]` run becomes one
    /// `_`, leading/trailing separators dropped (emitted only before an
    /// alnum keep, so nothing dangles).
    private static func slugifyNamespace(_ value: String) -> String {
        var out = ""
        var pendingSeparator = false
        for scalar in value.lowercased().unicodeScalars {
            let code = scalar.value
            if (code >= 97 && code <= 122) || (code >= 48 && code <= 57) {
                if pendingSeparator {
                    out.append("_")
                }
                pendingSeparator = false
                out.append(Character(scalar))
            } else {
                pendingSeparator = !out.isEmpty
            }
        }
        return out
    }

    /// Executor `hostnameOf`: the URL host, or nil when the endpoint has
    /// none (unparseable or schemaless). Trimmed before parsing: the WHATWG
    /// URL parser Executor uses strips surrounding whitespace, while
    /// `URLComponents` does not, so an untrimmed parse would diverge.
    private static func hostnameOf(endpoint: String) -> String? {
        URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines))?.host
    }

    /// Executor `basenameOf`: trims, then takes the text after the last `/`
    /// or `\`. Empty segments count (unlike the default split), so a
    /// trailing separator yields the empty basename.
    private static func basenameOf(command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" })
        return String(parts[parts.index(before: parts.endIndex)])
    }

    /// Per-integration diagnostics for `data`: one `(index, reason)` per
    /// problem, document-level problems at index `-1`. Empty means `decode`
    /// succeeds. Reasons are field labels (`"endpoint"`,
    /// `"auth.connectionId"`, `"duplicateNamespace"`), never values.
    public static func validate(_ data: Data) -> [(index: Int, reason: String)] {
        guard data.count <= maximumBytes else { return [(index: -1, reason: "oversized")] }
        guard let document = try? JSONDecoder().decode(MCPIntegrationDocumentDTO.self, from: data) else {
            return [(index: -1, reason: "invalidDocument")]
        }
        guard document.version == 1 else { return [(index: -1, reason: "unsupportedVersion")] }
        guard document.integrations.count <= maximumIntegrations else {
            return [(index: -1, reason: "tooManyIntegrations")]
        }
        var seen = Set<String>()
        var problems: [(index: Int, reason: String)] = []
        for (index, dto) in document.integrations.enumerated() {
            switch resolveResult(dto) {
            case .valid(let config):
                if seen.insert(config.resolvedNamespace).inserted == false {
                    problems.append((index: index, reason: "duplicateNamespace"))
                }
            case .invalid(let reason):
                problems.append((index: index, reason: reason))
            }
        }
        return problems
    }

    private static func resolve(_ dto: IntegrationDTO) -> MCPIntegrationConfig? {
        resolveResult(dto).value
    }

    private static func resolveResult(_ dto: IntegrationDTO) -> ResolveOutcome<MCPIntegrationConfig> {
        switch dto {
        case .remote(let remote):
            return resolveRemoteResult(remote).map(MCPIntegrationConfig.remote)
        case .stdio(let stdio):
            return resolveStdioResult(stdio).map(MCPIntegrationConfig.stdio)
        }
    }

    private static func resolveRemoteResult(_ dto: RemoteDTO) -> ResolveOutcome<MCPRemoteIntegration> {
        let transport: MCPRemoteTransport
        if let raw = dto.remoteTransport {
            guard let parsed = MCPRemoteTransport(rawValue: raw) else { return .invalid(reason: "remoteTransport") }
            transport = parsed
        } else {
            transport = .auto
        }
        let candidate = MCPRemoteIntegration(
            unchecked: dto.name, endpoint: dto.endpoint, remoteTransport: transport,
            namespace: dto.namespace,
            queryParams: dto.queryParams.map(convertHeaderMap),
            headers: dto.headers.map(convertHeaderMap),
            auth: convertAuth(dto.auth)
        )
        if let reason = validateRemote(candidate) {
            return .invalid(reason: reason)
        }
        return .valid(candidate)
    }

    private static func resolveStdioResult(_ dto: StdioDTO) -> ResolveOutcome<MCPStdioIntegration> {
        let candidate = MCPStdioIntegration(
            unchecked: dto.name, command: dto.command, args: dto.args,
            env: dto.env, cwd: dto.cwd, namespace: dto.namespace
        )
        if let reason = validateStdio(candidate) {
            return .invalid(reason: reason)
        }
        return .valid(candidate)
    }

    /// Total DTO-to-model converters: every DTO shape maps to a model, and
    /// `validateRemote` judges the result. The only failable conversion is
    /// the transport raw string, handled at the resolve site above.
    private static func convertHeaderMap(_ dto: [String: HeaderValueDTO]) -> [String: MCPHeaderValue] {
        Dictionary(
            uniqueKeysWithValues: dto.map { (key, value) in (key, convertHeaderValue(value)) }
        )
    }

    private static func convertHeaderValue(_ dto: HeaderValueDTO) -> MCPHeaderValue {
        switch dto {
        case .literal(let value):
            return .literal(value)
        case .secret(let selector, let prefix):
            return .secret(convertSelector(selector), prefix: prefix)
        }
    }

    /// Absent auth reads as `.none`, matching Executor's optional `auth`.
    private static func convertAuth(_ dto: AuthDTO?) -> MCPAuthConfig {
        guard let dto else { return MCPAuthConfig.none }
        switch dto {
        case .none:
            return MCPAuthConfig.none
        case .header(let headerName, let secret, let prefix):
            return .header(headerName: headerName, secret: convertSelector(secret), prefix: prefix)
        case .oauth2(let connectionId):
            return .oauth2(connectionId: connectionId)
        }
    }

    private static func convertSelector(_ dto: SecretSelectorDTO) -> MCPSecretSelector {
        MCPSecretSelector(provider: dto.provider, item: dto.item, field: dto.field)
    }

    /// The single value-rule choke point for remote integrations: the
    /// throwing init, `decode`, and `validate` all judge through here. Nil
    /// means valid, otherwise the failing field label (never the value).
    static func validateRemote(_ remote: MCPRemoteIntegration) -> String? {
        guard boundedText(remote.name, maxBytes: 256) else { return "name" }
        guard validEndpoint(remote.endpoint) else { return "endpoint" }
        if let namespace = remote.namespace {
            guard identifier(namespace) else { return "namespace" }
        }
        if let reason = validateHeaderMap(remote.queryParams, keyRule: queryKey, field: "queryParams") {
            return reason
        }
        if let reason = validateHeaderMap(remote.headers, keyRule: httpToken, field: "headers") {
            return reason
        }
        return validateAuth(remote.auth)
    }

    /// The single value-rule choke point for stdio integrations: the
    /// throwing init, `decode`, and `validate` all judge through here. Nil
    /// means valid, otherwise the failing field label (never the value).
    static func validateStdio(_ stdio: MCPStdioIntegration) -> String? {
        guard boundedText(stdio.name, maxBytes: 256) else { return "name" }
        guard absolutePath(stdio.command) else { return "command" }
        guard shellSafe(stdio.command) else { return "command.shell" }
        if let args = stdio.args {
            guard args.count <= maximumArgs else { return "args" }
            guard args.allSatisfy({ boundedText($0, maxBytes: 1024) }) else { return "args.value" }
        }
        if let env = stdio.env {
            guard env.count <= maximumEnv else { return "env" }
            for (key, value) in env {
                guard environmentName(key) else { return "env.name" }
                guard boundedText(value, maxBytes: 1024) else { return "env.value" }
                guard !value.hasPrefix(MCPSecretSelector.executorRefPrefix) else { return "env.secretRef" }
            }
        }
        if let cwd = stdio.cwd {
            guard absolutePath(cwd) else { return "cwd" }
        }
        if let namespace = stdio.namespace {
            guard identifier(namespace) else { return "namespace" }
        }
        return nil
    }

    private static func validateHeaderMap(
        _ map: [String: MCPHeaderValue]?, keyRule: (String) -> Bool, field: String
    ) -> String? {
        guard let map else { return nil }
        guard map.count <= maximumHeaders else { return field }
        for (key, value) in map {
            guard keyRule(key) else { return "\(field).key" }
            guard validateHeaderValue(value) else { return "\(field).value" }
        }
        return nil
    }

    private static func validateHeaderValue(_ value: MCPHeaderValue) -> Bool {
        switch value {
        case .literal(let text):
            return boundedText(text, maxBytes: 1024)
        case .secret(let selector, let prefix):
            return validateSelector(selector)
                && (prefix.map({ boundedText($0, maxBytes: 128) }) ?? true)
        }
    }

    private static func validateAuth(_ auth: MCPAuthConfig) -> String? {
        switch auth {
        case .none:
            return nil
        case .header(let headerName, let secret, let prefix):
            guard httpToken(headerName) else { return "auth.headerName" }
            guard validateSelector(secret) else { return "auth.secret" }
            guard prefix.map({ boundedText($0, maxBytes: 128) }) ?? true else { return "auth.prefix" }
            return nil
        case .oauth2(let connectionId):
            // References must resolve: the id parses as a dotted connection
            // handle (`<integration>.<owner>.<name>`), so every accepted id
            // names a real connection row. Dotted EXPLICIT namespaces stay
            // allowed (file-identity keys; the join is enforced at
            // registration, not here).
            guard (try? MCPConnectionID.parse(connectionId)) != nil else {
                return "auth.connectionId"
            }
            return nil
        }
    }

    private static func validateSelector(_ selector: MCPSecretSelector) -> Bool {
        SecretRef.allowedProviders.contains(selector.provider)
            && SecretLabels.isValidItem(selector.item)
            && (selector.field.map(SecretLabels.isValidField) ?? true)
    }

    /// Non-empty bounded operator text. Shared by names, literals, args,
    /// values, and prefixes; each caller passes its cap. Delegates the
    /// character rule to `OperatorText`: controls (NUL/CR/LF included — a
    /// bare vertical tab or form feed would split an HTTP field value at
    /// some servers), invisible format characters (zero-width joiners,
    /// directional marks), and line/paragraph separators all fail closed.
    /// (RVDomain offers no `isClean` spelling; the negated detector below
    /// is that predicate.)
    private static func boundedText(_ value: String, maxBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maxBytes
            && OperatorText.containsDisallowedTextScalar(value) == false
    }

    /// No C0/C1 controls or DEL. UTF-8 text at U+00A0 and above passes.
    private static func controlFree(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 32 && scalar.value != 127 && (scalar.value < 128 || scalar.value > 159)
        }
    }

    /// Endpoint safety: absolute http(s) URL with a host, no whitespace or
    /// control bytes, no embedded userinfo (credentials are refs, never
    /// smuggled into the URL), and no query or fragment (query pairs belong
    /// in `queryParams`, where the renderer percent-encodes them).
    private static func validEndpoint(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 2048, urlSafe(value) else { return false }
        guard let components = URLComponents(string: value),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty,
            components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil
        else { return false }
        return true
    }

    /// No Unicode whitespace, no C0/C1 controls, no DEL. UTF-8 bytes at or
    /// above 160 (non-ASCII text) pass; IDN hosts stay the dialer's problem.
    private static func urlSafe(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            !scalar.properties.isWhitespace && scalar.value >= 32 && scalar.value != 127
                && (scalar.value < 128 || scalar.value > 159)
        }
    }

    /// HTTP token (RFC 9110 tchar): header names that can actually be sent.
    private static func httpToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy(isTokenByte)
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
            || byte == 33 || byte == 35 || byte == 36 || byte == 37 || byte == 38 || byte == 39
            || byte == 42 || byte == 43 || byte == 45 || byte == 46 || byte == 94 || byte == 95
            || byte == 96 || byte == 124 || byte == 126
    }

    /// Query keys: printable, none of the query-string metacharacters
    /// (`& = # ?`) or whitespace, so rendering cannot break the query.
    private static func queryKey(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy { byte in
            byte > 32 && byte != 127 && byte != 38 && byte != 61 && byte != 35 && byte != 63
        }
    }

    /// Short portable identifiers (namespaces, connection ids), matching
    /// the sibling stores' charset.
    private static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func environmentName(_ value: String) -> Bool {
        guard let first = value.utf8.first,
            (first >= 65 && first <= 90) || (first >= 97 && first <= 122) || first == 95,
            value.utf8.count <= 64 else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                || ($0 >= 48 && $0 <= 57) || $0 == 95
        }
    }

    private static func absolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && value != "/" && value.utf8.count <= 1_024 && pathPartsSafe(value)
    }

    /// No shell metacharacters: the command is executed, so any byte a shell
    /// would interpret (substitution, quoting, redirection, globbing,
    /// history, comments) fails closed. Spaces stay legal. Args and cwd are
    /// NOT subject to this rule: args are `exec` argv elements and cwd is a
    /// `chdir` target, so both stay shell-free by spawn construction (see
    /// `MCPStdioIntegration`), and user paths legitimately hold parens.
    private static func shellSafe(_ value: String) -> Bool {
        !value.utf8.contains(where: { isShellMetabyte($0) })
    }

    /// `; | & $ ` " ' \ < > ( ) * ? ~ # ! { } [ ] ^`.
    private static func isShellMetabyte(_ byte: UInt8) -> Bool {
        byte == 59 || byte == 124 || byte == 38 || byte == 36 || byte == 96
            || byte == 34 || byte == 39 || byte == 92 || byte == 60 || byte == 62
            || byte == 40 || byte == 41 || byte == 42 || byte == 63 || byte == 126
            || byte == 35 || byte == 33 || byte == 123 || byte == 125 || byte == 91
            || byte == 93 || byte == 94
    }

    /// Absolute-only parts check: no control bytes, no empty/`.`/`..`
    /// segments. Unlike the sibling helper there is no relative caller, so
    /// the leading empty segment drops unconditionally.
    private static func pathPartsSafe(_ value: String) -> Bool {
        controlFree(value)
            && value.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

/// One resolve outcome: the model, or the failing field label (never the
/// value). A `Result` cannot carry a `String` failure, hence the enum.
private enum ResolveOutcome<Value> {
    case valid(Value)
    case invalid(reason: String)

    var value: Value? {
        if case .valid(let value) = self { return value }
        return nil
    }

    func map<Next>(_ transform: (Value) -> Next) -> ResolveOutcome<Next> {
        switch self {
        case .valid(let value): return .valid(transform(value))
        case .invalid(let reason): return .invalid(reason: reason)
        }
    }
}

/// Sink operation, for error reporting. Mirrors Executor `ConfigFileSink`
/// `upsertIntegration` / `removeIntegration`.
public enum MCPIntegrationSinkOperation: String, Sendable, Equatable {
    case upsert
    case remove
}

/// Minimal filesystem surface the sink needs. The live implementation uses
/// owner-only POSIX IO; tests inject fakes that fail on command, which is
/// what makes the never-fails property directly testable.
public protocol MCPIntegrationSinkIO: Sendable {
    func readSet(directory: URL) -> Result<MCPIntegrationSet, MCPIntegrationStoreError>
    func writeSet(_ set: MCPIntegrationSet, directory: URL) -> Result<Void, MCPIntegrationStoreError>
}

/// Best-effort write-back of integration changes to `mcp-integrations.json`.
///
/// Mirrors Executor `ConfigFileSink` (`packages/core/config/src/sink.ts`):
/// upsert dedups by resolved namespace (Executor's `addIntegrationToConfig`
/// removes same-namespace entries before appending; RV keys on the resolved
/// namespace because the file forbids duplicate resolved namespaces,
/// derived ones included), remove drops every entry with the namespace, and
/// every error is reported to `onError` and swallowed — a failed file write
/// never fails the caller, and the next successful mutation reconciles.
///
/// Two fail-safe rules beyond the Executor mirror: an existing file that
/// fails validation is never clobbered (the mutation reports and leaves the
/// bytes untouched), and remove on a missing file or a missed namespace
/// writes nothing and reports nothing.
public struct MCPIntegrationFileSink<IO: MCPIntegrationSinkIO>: Sendable {
    public let directory: URL
    public let io: IO
    public let onError: @Sendable (MCPIntegrationSinkOperation, MCPIntegrationStoreError) -> Void

    public init(
        directory: URL,
        io: IO,
        onError: @escaping @Sendable (MCPIntegrationSinkOperation, MCPIntegrationStoreError) -> Void
    ) {
        self.directory = directory
        self.io = io
        self.onError = onError
    }

    /// Default reporter: one stderr line, mirroring Executor's
    /// `console.warn` sink default and the sibling migration logs.
    public static func defaultOnError(
        _ operation: MCPIntegrationSinkOperation, _ error: MCPIntegrationStoreError
    ) {
        FileHandle.standardError.write(
            Data("rv: mcp-integration-sink \(operation.rawValue) failed: \(error)\n".utf8)
        )
    }

    public func upsert(_ integration: MCPIntegrationConfig) {
        let existing: MCPIntegrationSet
        switch io.readSet(directory: directory) {
        case .success(let set):
            existing = set
        case .failure(let error):
            onError(.upsert, error)
            return
        }
        switch MCPIntegrationFileSinkTransform.upsert(integration, into: existing) {
        case .success(let updated):
            if case .failure(let error) = io.writeSet(updated, directory: directory) {
                onError(.upsert, error)
            }
        case .failure(let error):
            onError(.upsert, error)
        }
    }

    public func removeIntegration(namespace: String) {
        let existing: MCPIntegrationSet
        switch io.readSet(directory: directory) {
        case .success(let set):
            existing = set
        case .failure(let error):
            onError(.remove, error)
            return
        }
        let updated = MCPIntegrationFileSinkTransform.remove(namespace: namespace, from: existing)
        guard let updated else { return }
        if case .failure(let error) = io.writeSet(updated, directory: directory) {
            onError(.remove, error)
        }
    }
}

extension MCPIntegrationFileSink where IO == MCPIntegrationLiveIO {
    /// Live sink over the real filesystem.
    public static func live(
        directory: URL,
        onError: @escaping @Sendable (MCPIntegrationSinkOperation, MCPIntegrationStoreError) -> Void
    ) -> MCPIntegrationFileSink<MCPIntegrationLiveIO> {
        MCPIntegrationFileSink(directory: directory, io: MCPIntegrationLiveIO(), onError: onError)
    }

    /// Live sink with the default stderr reporter. A separate overload
    /// rather than a default argument, so the reporter reference is an
    /// ordinary covered line instead of an uncoverable default thunk.
    public static func live(directory: URL) -> MCPIntegrationFileSink<MCPIntegrationLiveIO> {
        MCPIntegrationFileSink(directory: directory, io: MCPIntegrationLiveIO(), onError: Self.defaultOnError)
    }
}

/// Pure document transforms behind the sink. Taking and returning validated
/// sets (not bytes) keeps every rule unit-testable without fixtures.
enum MCPIntegrationFileSinkTransform {
    static func upsert(
        _ integration: MCPIntegrationConfig, into existing: MCPIntegrationSet
    ) -> Result<MCPIntegrationSet, MCPIntegrationStoreError> {
        var integrations = existing.integrations
        let namespace = integration.resolvedNamespace
        integrations.removeAll { $0.resolvedNamespace == namespace }
        integrations.append(integration)
        guard integrations.count <= MCPIntegrationStore.maximumIntegrations else {
            return .failure(.invalidDocument)
        }
        let updated = MCPIntegrationSet(integrations: integrations)
        // Round-trip guard: the sink must never write bytes that fail to
        // load. Hand-built models can carry values decode rejects, and a
        // poisoned file would stick, since invalid files are never clobbered.
        let bytes: Data
        switch MCPIntegrationStore.encode(updated) {
        case .success(let encoded):
            bytes = encoded
        case .failure(let error):
            return .failure(error)
        }
        guard case .success = MCPIntegrationStore.decode(bytes) else {
            return .failure(.invalidDocument)
        }
        return .success(updated)
    }

    /// The updated set, or nil when nothing matched and no write is due.
    /// Infallible: filtering cannot fail, so there is no `Result` wrapper
    /// and no dead failure arm at the call site.
    static func remove(namespace: String, from existing: MCPIntegrationSet) -> MCPIntegrationSet? {
        let kept = existing.integrations.filter { $0.resolvedNamespace != namespace }
        guard kept.count != existing.integrations.count else { return nil }
        return MCPIntegrationSet(integrations: kept)
    }
}

/// Live sink IO: reads through the store, writes atomically under the
/// owner-only discipline (trusted directory, 0600 temp file, rename over).
public struct MCPIntegrationLiveIO: MCPIntegrationSinkIO {
    public init() {}

    public func readSet(directory: URL) -> Result<MCPIntegrationSet, MCPIntegrationStoreError> {
        MCPIntegrationStore.load(from: directory)
    }

    public func writeSet(_ set: MCPIntegrationSet, directory: URL) -> Result<Void, MCPIntegrationStoreError> {
        switch MCPIntegrationStore.encode(set) {
        case .success(let bytes):
            return Self.writeAtomically(bytes, directory: directory)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Writes `bytes` over the live file, or fails without touching it.
    /// Every failure reports `.unsafeLocation`: the location could not be
    /// written safely, whatever the underlying cause.
    static func writeAtomically(_ bytes: Data, directory: URL) -> Result<Void, MCPIntegrationStoreError> {
        let dirFd = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard dirFd >= 0 else { return .failure(.unsafeLocation) }
        defer { close(dirFd) }
        guard directoryIsTrusted(dirFd) else { return .failure(.unsafeLocation) }
        guard replaceFile(bytes: bytes, dirFd: dirFd) else { return .failure(.unsafeLocation) }
        return .success(())
    }

    /// Owner-owned directory without group/other write, mirroring the read
    /// discipline. An attacker-writable directory could swap our temp file
    /// mid-write, so it fails closed before any staging.
    static func directoryIsTrusted(_ fd: Int32) -> Bool {
        var status = stat()
        guard fstat(fd, &status) == 0 else { return false }
        guard status.st_uid == getuid() else { return false }
        guard (status.st_mode & 0o022) == 0 else { return false }
        return true
    }

    static func replaceFile(bytes: Data, dirFd: Int32) -> Bool {
        guard let staged = stage(bytes: bytes, dirFd: dirFd) else { return false }
        defer { close(staged.fd) }
        return OwnerOnlyFileWrite.commit(
            staged: staged, as: MCPIntegrationStore.fileName, inDirectory: dirFd
        )
    }

    /// Stages `bytes` into a 0600 temp via the shared sidecar. Deliberate
    /// divergences from the migration rewrite, preserved: single-attempt
    /// (`.once`, one attempt, no `EEXIST` retry) and no dev/ino recheck —
    /// a failed staging reports and the sink reconciles on its next
    /// mutation instead of retrying here.
    static func stage(bytes: Data, dirFd: Int32) -> StagedFile? {
        OwnerOnlyFileWrite.stage(
            bytes: bytes, fileName: MCPIntegrationStore.fileName, tag: "sink",
            inDirectory: dirFd, policy: .once, attempts: 1
        )
    }

    /// One write attempt, via the shared sidecar's `.once` policy.
    static func writeOnce(_ bytes: Data, to fd: Int32) -> Bool {
        OwnerOnlyFileWrite.writeBytes(bytes, to: fd, policy: .once)
    }

    typealias StagedFile = OwnerOnlyFileWrite.StagedFile
}

/// Canonical encoded document. Hand-written like every `encode(to:)` in
/// this file, so no synthesized coder can hide an untested path.
private struct MCPIntegrationDocument: Encodable {
    let version: Int
    let integrations: [MCPIntegrationConfig]

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictJSONKey.self)
        try container.encode(version, forKey: StrictJSONKey("version"))
        try container.encode(integrations, forKey: StrictJSONKey("integrations"))
    }
}

/// Versioned operator document with closed key sets, mirroring the sibling
/// stores. Decoding is structural only; `MCPIntegrationStore.resolve`
/// validates every value after.
private struct MCPIntegrationDocumentDTO: Decodable {
    let version: Int
    let integrations: [IntegrationDTO]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(container, allowed: ["version", "integrations"])
        version = try container.decode(Int.self, forKey: StrictJSONKey("version"))
        integrations = try container.decode([IntegrationDTO].self, forKey: StrictJSONKey("integrations"))
    }
}

private enum IntegrationDTO: Decodable {
    case remote(RemoteDTO)
    case stdio(StdioDTO)

    init(from decoder: Decoder) throws {
        let probe = try decoder.container(keyedBy: StrictJSONKey.self)
        let kind = try probe.decode(String.self, forKey: StrictJSONKey("kind"))
        switch kind {
        case "mcp-remote":
            self = .remote(try RemoteDTO(from: decoder))
        case "mcp-stdio":
            self = .stdio(try StdioDTO(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: StrictJSONKey("kind"), in: probe,
                debugDescription: "unknown integration kind: \(kind)"
            )
        }
    }
}

private struct RemoteDTO: Decodable {
    let name: String
    let endpoint: String
    let remoteTransport: String?
    let namespace: String?
    let queryParams: [String: HeaderValueDTO]?
    let headers: [String: HeaderValueDTO]?
    let auth: AuthDTO?

    // `kind` is admitted but not re-read: the dispatcher already matched it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(
            container,
            allowed: ["kind", "name", "endpoint", "remoteTransport", "namespace", "queryParams", "headers", "auth"]
        )
        name = try container.decode(String.self, forKey: StrictJSONKey("name"))
        endpoint = try container.decode(String.self, forKey: StrictJSONKey("endpoint"))
        remoteTransport = try container.decodeIfPresent(String.self, forKey: StrictJSONKey("remoteTransport"))
        namespace = try container.decodeIfPresent(String.self, forKey: StrictJSONKey("namespace"))
        queryParams = try container.decodeIfPresent(
            [String: HeaderValueDTO].self, forKey: StrictJSONKey("queryParams")
        )
        headers = try container.decodeIfPresent(
            [String: HeaderValueDTO].self, forKey: StrictJSONKey("headers")
        )
        auth = try container.decodeIfPresent(AuthDTO.self, forKey: StrictJSONKey("auth"))
    }
}

private struct StdioDTO: Decodable {
    let name: String
    let command: String
    let args: [String]?
    let env: [String: String]?
    let cwd: String?
    let namespace: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(
            container, allowed: ["kind", "name", "command", "args", "env", "cwd", "namespace"]
        )
        name = try container.decode(String.self, forKey: StrictJSONKey("name"))
        command = try container.decode(String.self, forKey: StrictJSONKey("command"))
        args = try container.decodeIfPresent([String].self, forKey: StrictJSONKey("args"))
        env = try container.decodeIfPresent([String: String].self, forKey: StrictJSONKey("env"))
        cwd = try container.decodeIfPresent(String.self, forKey: StrictJSONKey("cwd"))
        namespace = try container.decodeIfPresent(String.self, forKey: StrictJSONKey("namespace"))
    }
}

private enum AuthDTO: Decodable {
    case none
    case header(headerName: String, secret: SecretSelectorDTO, prefix: String?)
    case oauth2(connectionId: String)

    init(from decoder: Decoder) throws {
        let probe = try decoder.container(keyedBy: StrictJSONKey.self)
        let kind = try probe.decode(String.self, forKey: StrictJSONKey("kind"))
        switch kind {
        case "none":
            try rejectUnknownKeys(probe, allowed: ["kind"])
            self = .none
        case "header":
            try rejectUnknownKeys(probe, allowed: ["kind", "headerName", "secret", "prefix"])
            self = .header(
                headerName: try probe.decode(String.self, forKey: StrictJSONKey("headerName")),
                secret: try probe.decode(SecretSelectorDTO.self, forKey: StrictJSONKey("secret")),
                prefix: try probe.decodeIfPresent(String.self, forKey: StrictJSONKey("prefix"))
            )
        case "oauth2":
            try rejectUnknownKeys(probe, allowed: ["kind", "connectionId"])
            self = .oauth2(
                connectionId: try probe.decode(String.self, forKey: StrictJSONKey("connectionId"))
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: StrictJSONKey("kind"), in: probe,
                debugDescription: "unknown auth kind: \(kind)"
            )
        }
    }
}

/// Header value DTO: a literal string, a `secret-public-ref:` string (no
/// prefix), or `{"secret": <selector>, "prefix"?}`. A malformed ref string
/// throws rather than degrading to a literal: a mistyped ref must fail
/// closed, never silently become the credential it names.
private enum HeaderValueDTO: Decodable {
    case literal(String)
    case secret(SecretSelectorDTO, prefix: String?)

    init(from decoder: Decoder) throws {
        if let string = try? decoder.singleValueContainer().decode(String.self) {
            if string.hasPrefix(MCPSecretSelector.executorRefPrefix) {
                guard let parsed = MCPSecretSelector.parseExecutorRef(string) else {
                    throw DecodingError.dataCorruptedError(
                        in: try decoder.singleValueContainer(),
                        debugDescription: "malformed secret ref"
                    )
                }
                self = .secret(
                    SecretSelectorDTO(provider: parsed.provider, item: parsed.item, field: nil), prefix: nil
                )
            } else {
                self = .literal(string)
            }
        } else {
            let container = try decoder.container(keyedBy: StrictJSONKey.self)
            try rejectUnknownKeys(container, allowed: ["secret", "prefix"])
            let selector = try container.decode(SecretSelectorDTO.self, forKey: StrictJSONKey("secret"))
            let prefix = try container.decodeIfPresent(String.self, forKey: StrictJSONKey("prefix"))
            self = .secret(selector, prefix: prefix)
        }
    }
}

/// Selector DTO: the string form (`secret-public-ref:<provider>/<item>`,
/// field-less) or the object form (`{"provider", "item", "field"?}`).
private struct SecretSelectorDTO: Decodable {
    let provider: String
    let item: String
    let field: String?

    init(provider: String, item: String, field: String?) {
        self.provider = provider
        self.item = item
        self.field = field
    }

    init(from decoder: Decoder) throws {
        if let string = try? decoder.singleValueContainer().decode(String.self) {
            guard let parsed = MCPSecretSelector.parseExecutorRef(string) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "malformed secret ref"
                )
            }
            provider = parsed.provider
            item = parsed.item
            field = nil
        } else {
            let container = try decoder.container(keyedBy: StrictJSONKey.self)
            try rejectUnknownKeys(container, allowed: ["provider", "item", "field"])
            provider = try container.decode(String.self, forKey: StrictJSONKey("provider"))
            item = try container.decode(String.self, forKey: StrictJSONKey("item"))
            field = try container.decodeIfPresent(String.self, forKey: StrictJSONKey("field"))
        }
    }
}
