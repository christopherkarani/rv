import Foundation

/// MCP connection records, credential inputs, invocation credentials, and the
/// credential failure taxonomy. Pure values and pure functions; no IO.
/// Oracles: executor `connection.ts` (record, origins, input map),
/// `plugin.ts` `ToolInvocationCredential`, `errors.ts` credential errors,
/// `auth-tool-failure.ts` (reconnect guidance), `executor.ts`
/// (`normalizeConnectionInputs`, `grantedScopesFromRow`,
/// `credentialFailureReason`), `oauth-helpers.ts` (RFC 6749 codes),
/// `oauth-service.ts` (scope compare), `health-check.ts` (health vocabulary),
/// `connection-name-identifier.ts` (name charset + normalization).

// MARK: - Connection record

/// One saved MCP credential, born wired to exactly one integration.
/// `owner` reuses `PolicyOwner` so connection scope and policy scope share one
/// vocabulary; `provider` names the backend that resolves the value, never the
/// value itself. Secret material is never stored here.
public struct MCPConnection: Sendable, Equatable, Hashable, Codable {
    /// Scope deciding who may use this connection. Reuses the policy owner.
    public let owner: PolicyOwner
    /// Connection name, unique under (owner, integration).
    public let name: String
    /// The one integration this credential is for.
    public let integration: String
    /// Which of the integration's auth methods this credential applies through.
    public let template: String
    /// Which backend resolves the value.
    public let provider: String
    /// Optional human label (which account). Agent-visible, not load-bearing.
    public let identityLabel: String?
    /// User-curated description of what this connection is for.
    public let description: String?
    /// When an OAuth access token expires; nil for static credentials.
    public let expiresAt: Date?
    /// The OAuth app slug that minted this connection; nil for static creds.
    public let oauthClient: String?
    /// Owner of `oauthClient`; nil for static creds. Stored at mint so refresh
    /// loads the client by an explicit (slug, owner).
    public let oauthClientOwner: PolicyOwner?
    /// Granted scope set as echoed by the token endpoint (space-delimited).
    public let oauthScope: String?
    /// Requested scopes the provider did not grant, excluding
    /// identity/refresh scopes. Informational only.
    public let missingOAuthScopes: [String]
    /// Last health-check verdict. Nil means never checked.
    public let lastHealth: MCPConnectionHealth?

    /// UTF-8 byte caps. Identifiers are ASCII-closed so bytes equal characters.
    public static let maxNameBytes = 128
    public static let maxSlugBytes = 128
    public static let maxVariableBytes = 128
    public static let maxLabelBytes = 256
    public static let maxHealthIdentityBytes = 256
    public static let maxDescriptionBytes = 1024
    public static let maxExternalIDBytes = 512
    public static let maxScopeTokenBytes = 512
    public static let maxHealthDetailBytes = 2048
    public static let maxOAuthScopeBytes = 4096

    /// Sentinel template for integrations that require no credential (executor
    /// `NO_AUTH_TEMPLATE`). No-auth-ness is a property of the RESOLVED auth
    /// method (`kind == "none"`), not of this slug: an apiKey method whose
    /// template happens to be named "none" is still credentialed (executor
    /// `connections.test.ts`: "preserves credentials for an API-key method
    /// with a colliding no-auth slug"). Callers resolve the method first and
    /// pass the verdict to `routeConnectionInputs` as `isNoAuthTemplate`.
    public static let noAuthTemplate = "none"

    /// Validates names/identifiers (closed charsets, byte caps) and labels
    /// (byte caps, no control/format characters). Errors carry field labels
    /// and caps only, never the rejected text.
    ///
    /// OAuth linkage invariant: `oauthClient` set marks an OAuth connection,
    /// which is expected to carry its token-endpoint scope echo in
    /// `oauthScope`; static connections (`oauthClient` nil) normally carry
    /// none. The invariant is advisory at construction — legacy persisted
    /// rows with an OAuth client but no scope still decode — and enforced at
    /// evaluation: `evaluateScopeGap` fails open on nil coverage for static
    /// connections and fails closed for OAuth ones.
    public init(
        owner: PolicyOwner,
        name: String,
        integration: String,
        template: String,
        provider: String,
        identityLabel: String? = nil,
        description: String? = nil,
        expiresAt: Date? = nil,
        oauthClient: String? = nil,
        oauthClientOwner: PolicyOwner? = nil,
        oauthScope: String? = nil,
        missingOAuthScopes: [String] = [],
        lastHealth: MCPConnectionHealth? = nil
    ) throws {
        try requireConnectionIdentifier(name, field: .name, maxBytes: Self.maxNameBytes)
        try requireConnectionSlug(integration, field: .integration, maxBytes: Self.maxSlugBytes)
        try requireConnectionSlug(template, field: .template, maxBytes: Self.maxSlugBytes)
        try requireConnectionSlug(provider, field: .provider, maxBytes: Self.maxSlugBytes)
        if let identityLabel {
            try OperatorText.requireDisplayText(identityLabel, field: .identityLabel, maxBytes: Self.maxLabelBytes)
        }
        if let description {
            try OperatorText.requireDisplayText(description, field: .description, maxBytes: Self.maxDescriptionBytes)
        }
        if let oauthClient {
            try requireConnectionSlug(oauthClient, field: .oauthClient, maxBytes: Self.maxSlugBytes)
        }
        if let oauthScope {
            try requireOAuthScope(oauthScope)
        }
        for scope in missingOAuthScopes {
            try requireScopeToken(scope, field: .missingOAuthScope, maxBytes: Self.maxScopeTokenBytes)
        }
        self.owner = owner
        self.name = name
        self.integration = integration
        self.template = template
        self.provider = provider
        self.identityLabel = identityLabel
        self.description = description
        self.expiresAt = expiresAt
        self.oauthClient = oauthClient
        self.oauthClientOwner = oauthClientOwner
        self.oauthScope = oauthScope
        self.missingOAuthScopes = missingOAuthScopes
        self.lastHealth = lastHealth
    }

    /// Decodes by re-running the validating init, so persisted payloads face
    /// the same closed charsets and byte caps as fresh input. Absent
    /// `missingOAuthScopes` defaults to `[]`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            owner: try container.decode(PolicyOwner.self, forKey: .owner),
            name: try container.decode(String.self, forKey: .name),
            integration: try container.decode(String.self, forKey: .integration),
            template: try container.decode(String.self, forKey: .template),
            provider: try container.decode(String.self, forKey: .provider),
            identityLabel: try container.decodeIfPresent(String.self, forKey: .identityLabel),
            description: try container.decodeIfPresent(String.self, forKey: .description),
            expiresAt: try container.decodeIfPresent(Date.self, forKey: .expiresAt),
            oauthClient: try container.decodeIfPresent(String.self, forKey: .oauthClient),
            oauthClientOwner: try container.decodeIfPresent(PolicyOwner.self, forKey: .oauthClientOwner),
            oauthScope: try container.decodeIfPresent(String.self, forKey: .oauthScope),
            missingOAuthScopes: try container.decodeIfPresent([String].self, forKey: .missingOAuthScopes) ?? [],
            lastHealth: try container.decodeIfPresent(MCPConnectionHealth.self, forKey: .lastHealth)
        )
    }

    /// Callable handle `tools.<integration>.<owner>.<name>`. Append `.<tool>`
    /// to reach one of its tools.
    public var addressLiteral: String {
        "tools.\(integration).\(owner.rawValue).\(name)"
    }

    /// Builds the callable address of one of this connection's tools.
    public func toolAddress(forTool tool: String) throws -> MCPToolAddress {
        try MCPToolAddress(
            integration: integration,
            owner: owner.rawValue,
            connection: name,
            tool: tool
        )
    }
}

/// Record field labels for validation errors. Labels only, never values.
public enum MCPConnectionField: String, Sendable, Equatable, Hashable {
    case name
    case integration
    case template
    case provider
    case identityLabel
    case description
    case oauthClient
    case oauthScope
    case missingOAuthScope
    case variable
    case externalProvider
    case externalID
    case healthIdentity
    case healthDetail
}

/// Record/input validation failures. Never echoes the rejected text.
public enum MCPConnectionError: Error, Sendable, Equatable {
    /// A required name, identifier, or token was empty.
    case emptyField(MCPConnectionField)
    /// A field exceeds its UTF-8 byte cap.
    case tooLong(field: MCPConnectionField, maxBytes: Int)
    /// A field holds characters outside its closed charset.
    case invalidCharacters(field: MCPConnectionField)
}

/// Dotted connection handle: `<integration>.<owner>.<name>` (for example
/// `github.user.main`). The dotted form is unambiguous because every part is
/// dot-free per the connection charsets (integration is a slug, name is an
/// identifier, owner is `user`/`org`), so `description` round-trips through
/// `parse` exactly. Parts face the same closed charsets and byte caps as the
/// record; shape failures throw `MCPConnectionIDError`, charset failures the
/// record's `MCPConnectionError`. Labels only, never values.
public struct MCPConnectionID: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// Integration slug (dot-free).
    public let integration: String
    /// Connection owner.
    public let owner: PolicyOwner
    /// Connection name (dot-free).
    public let name: String

    /// Validates parts against the record charsets: integration as a slug,
    /// name as an identifier, owner typed. Errors never echo the rejected text.
    public init(integration: String, owner: PolicyOwner, name: String) throws {
        try requireConnectionSlug(integration, field: .integration, maxBytes: MCPConnection.maxSlugBytes)
        try requireConnectionIdentifier(name, field: .name, maxBytes: MCPConnection.maxNameBytes)
        self.integration = integration
        self.owner = owner
        self.name = name
    }

    /// Parses a dotted handle; exactly three non-empty dot-separated parts
    /// with a `user`/`org` middle. Dotted parts cannot occur: the split that
    /// finds them is the split that rejects them.
    public static func parse(_ raw: String) throws -> MCPConnectionID {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts.allSatisfy({ $0.isEmpty == false }) else {
            throw MCPConnectionIDError.malformed
        }
        guard let owner = PolicyOwner(rawValue: parts[1]) else {
            throw MCPConnectionIDError.unknownOwner
        }
        return try MCPConnectionID(integration: parts[0], owner: owner, name: parts[2])
    }

    /// Canonical dotted handle: `<integration>.<owner>.<name>`.
    public var description: String {
        "\(integration).\(owner.rawValue).\(name)"
    }
}

/// Dotted-handle shape failures. Never echoes the rejected text.
public enum MCPConnectionIDError: Error, Sendable, Equatable {
    /// Not exactly three non-empty dot-separated parts.
    case malformed
    /// The middle part is not `user` or `org`.
    case unknownOwner
}

// MARK: - Name normalization

/// Normalizes free-form text into a JS-callable connection identifier.
/// Exact port of executor `connectionIdentifier`: already-normalized input
/// (`^[a-z][A-Za-z0-9]*$`) passes through untouched so the transform is
/// idempotent; otherwise the lowercased input's ASCII `[a-z0-9]+` runs become
/// camelCase words (everything else is dropped), empty results fall back to
/// `fallback`, and a leading digit is prefixed with `fallback`.
///
/// The result is NOT byte-capped (the executor has no cap): callers still run
/// it through `MCPConnection.init`, which throws `tooLong` for over-long
/// results. `fallback` itself is used raw, exactly as in the executor.
public func normalizeConnectionName(_ input: String, fallback: String = "connection") -> String {
    if isIdempotentConnectionName(input) {
        return input
    }
    var words: [String] = []
    var current = ""
    for scalar in input.lowercased().unicodeScalars {
        let asciiAlphanumeric = (scalar.value >= 0x61 && scalar.value <= 0x7A)
            || (scalar.value >= 0x30 && scalar.value <= 0x39)
        if asciiAlphanumeric {
            current.append(Character(scalar))
        } else if current.isEmpty == false {
            words.append(current)
            current = ""
        }
    }
    if current.isEmpty == false {
        words.append(current)
    }
    let base: String
    if let firstWord = words.first {
        base = firstWord + words.dropFirst().map { String($0.prefix(1)).uppercased() + String($0.dropFirst()) }.joined()
    } else {
        base = fallback
    }
    if let first = base.unicodeScalars.first, isIdentifierStart(first) {
        return base
    }
    let head = base.unicodeScalars.first.map { String($0).uppercased() } ?? ""
    return fallback + head + String(base.unicodeScalars.dropFirst())
}

/// True for names already in the normalizer's output shape
/// (`^[a-z][A-Za-z0-9]*$`). Note this is narrower than `isConnectionIdentifier`:
/// `$`/`_` starts and uppercase starts are retokenized, not passed through.
private func isIdempotentConnectionName(_ input: String) -> Bool {
    guard let first = input.unicodeScalars.first, first.value >= 0x61, first.value <= 0x7A else {
        return false
    }
    return input.unicodeScalars.dropFirst().allSatisfy { scalar in
        (scalar.value >= 0x30 && scalar.value <= 0x39)
            || (scalar.value >= 0x41 && scalar.value <= 0x5A)
            || (scalar.value >= 0x61 && scalar.value <= 0x7A)
    }
}

// MARK: - Value origins + multi-input map

/// Where a single credential input comes from. `value` is pasted raw and
/// written to the default provider; `from` references an external provider by
/// opaque id. Routing is stored, values resolve on demand.
public enum ConnectionInputOrigin: Sendable, Equatable, Hashable {
    /// Pasted secret material. Secret bytes; never logged or echoed.
    case value(String)
    /// External reference: provider key plus the provider's opaque item id.
    case from(provider: String, id: String)
}

/// The value origin(s) for a new credential. `value`/`from` are sugar for the
/// single `token` input; `values` is pasted multi-input; `inputs` is the
/// canonical per-variable origin map (mixes pasted + external). All inputs of
/// one connection share one provider.
public enum ConnectionValueInput: Sendable, Equatable {
    /// Sugar for the single `token` input, pasted.
    case value(String)
    /// Sugar for the single `token` input, external.
    case from(provider: String, id: String)
    /// Pasted per-variable map.
    case values([String: String])
    /// Canonical per-variable origin map.
    case inputs([String: ConnectionInputOrigin])

    /// The canonical credential variable for a single-secret connection.
    public static let primaryVariable = "token"
}

/// One named credential input after normalization.
public struct NamedConnectionInput: Sendable, Equatable, Hashable {
    /// Template variable this input fills.
    public let variable: String
    /// Where the variable's value comes from.
    public let origin: ConnectionInputOrigin

    /// Assembles one named input. Use `normalizeConnectionInput` for validated
    /// construction from the sugar forms.
    public init(variable: String, origin: ConnectionInputOrigin) {
        self.variable = variable
        self.origin = origin
    }
}

/// Flattens any `ConnectionValueInput` form into a uniform, variable-sorted
/// list of named origins. Validates variable names and external references;
/// pasted values pass through untouched (secret material, broker-capped).
public func normalizeConnectionInput(_ input: ConnectionValueInput) throws -> [NamedConnectionInput] {
    switch input {
    case .value(let pasted):
        return [NamedConnectionInput(variable: ConnectionValueInput.primaryVariable, origin: .value(pasted))]
    case .from(let provider, let id):
        let origin = try validatedOrigin(.from(provider: provider, id: id))
        return [NamedConnectionInput(variable: ConnectionValueInput.primaryVariable, origin: origin)]
    case .values(let map):
        return try map.sorted(by: { $0.key < $1.key }).map { entry in
            try NamedConnectionInput(variable: validatedVariable(entry.key), origin: .value(entry.value))
        }
    case .inputs(let map):
        return try map.sorted(by: { $0.key < $1.key }).map { entry in
            try NamedConnectionInput(variable: validatedVariable(entry.key), origin: validatedOrigin(entry.value))
        }
    }
}

/// Single-provider routing decision for a connection's normalized inputs.
public struct ConnectionInputRouting: Sendable, Equatable {
    /// External provider shared by every input, or nil when all inputs are
    /// pasted (default store).
    public let provider: String?
    /// Variables in the normalized (sorted) order.
    public let variables: [String]

    /// Assembles a routing decision.
    public init(provider: String?, variables: [String]) {
        self.provider = provider
        self.variables = variables
    }
}

/// Input-map structural failures. Labels only; never pasted values.
public enum ConnectionInputsError: Error, Sendable, Equatable {
    /// A credentialed connection supplied zero inputs.
    case noCredentialInputs
    /// A no-auth connection supplied live credential inputs.
    case inputsOnNoAuthTemplate
    /// Pasted and external-provider inputs were mixed.
    case mixedOrigins
    /// External inputs named more than one provider.
    case multipleProviders

    /// Caller-safe detail, verbatim from the executor's
    /// `InvalidConnectionInputError` strings ("safe to show to the caller").
    public var message: String {
        switch self {
        case .noCredentialInputs:
            return "A connection must supply at least one credential input."
        case .inputsOnNoAuthTemplate:
            return "A no-auth connection cannot accept credential inputs."
        case .mixedOrigins:
            return "A connection cannot mix pasted and external-provider inputs."
        case .multipleProviders:
            return "A connection's inputs must all use the same external provider."
        }
    }
}

/// Resolves normalized inputs to one provider plus a variable list. A
/// credentialed connection must supply at least one input; a no-auth
/// connection accepts none (all-empty pasted placeholders are dropped for
/// legacy clients); mixing pasted + external, or two external providers, is
/// rejected because the row carries one provider. Variables and external
/// references are revalidated, so hand-built (non-normalized) inputs fail
/// closed instead of smuggling unexpected keys into the routing decision.
public func routeConnectionInputs(
    _ inputs: [NamedConnectionInput],
    isNoAuthTemplate: Bool
) throws -> ConnectionInputRouting {
    let validated = try inputs.map {
        try NamedConnectionInput(variable: validatedVariable($0.variable), origin: validatedOrigin($0.origin))
    }
    if isNoAuthTemplate {
        guard validated.allSatisfy({ $0.origin.isEmptyPastedValue }) else {
            throw ConnectionInputsError.inputsOnNoAuthTemplate
        }
        return ConnectionInputRouting(provider: nil, variables: [])
    }
    guard validated.isEmpty == false else {
        throw ConnectionInputsError.noCredentialInputs
    }
    var externalProviders: [String] = []
    var hasPasted = false
    for input in validated {
        switch input.origin {
        case .value:
            hasPasted = true
        case .from(let provider, _):
            externalProviders.append(provider)
        }
    }
    let distinct = Set(externalProviders)
    guard hasPasted == false || externalProviders.isEmpty else {
        throw ConnectionInputsError.mixedOrigins
    }
    guard distinct.count <= 1 else {
        throw ConnectionInputsError.multipleProviders
    }
    return ConnectionInputRouting(provider: distinct.first, variables: validated.map(\.variable))
}

/// Maps normalized inputs to resolved values (`variable → value`). Pasted
/// inputs resolve inline; external inputs resolve through `lookup`, which
/// returns nil for unresolvable items. Nil entries are preserved (never
/// dropped), mirroring the executor's `string | null` map. Variables and
/// external references are revalidated, so hand-built (non-normalized) inputs
/// fail closed instead of smuggling unexpected keys into template rendering.
/// Named `...InputValues` (not `...Values`) to avoid confusion with the
/// invoker's ref-resolving `resolveConnectionValues` at the X1-S seam.
public func resolveConnectionInputValues(
    _ inputs: [NamedConnectionInput],
    lookup: (ConnectionExternalRef) -> SecretValue?
) throws -> [String: SecretValue?] {
    var resolved: [String: SecretValue?] = [:]
    for input in inputs {
        let variable = try validatedVariable(input.variable)
        switch input.origin {
        case .value(let pasted):
            resolved.updateValue(.text(pasted), forKey: variable)
        case .from(let provider, let id):
            let ref = try ConnectionExternalRef(provider: provider, id: id)
            resolved.updateValue(lookup(ref), forKey: variable)
        }
    }
    return resolved
}

/// Validated external credential reference: provider key plus the provider's
/// opaque item id, which core never parses.
public struct ConnectionExternalRef: Sendable, Equatable, Hashable {
    /// External provider key.
    public let provider: String
    /// The provider's opaque handle for the stored value.
    public let id: String

    /// Validates the provider slug and the opaque id (non-empty, capped, no
    /// control/format characters). Errors carry labels only.
    public init(provider: String, id: String) throws {
        try requireConnectionSlug(provider, field: .externalProvider, maxBytes: MCPConnection.maxSlugBytes)
        try requireExternalID(id)
        self.provider = provider
        self.id = id
    }

    /// Bridges to the RV secret broker shape. Throws `SecretsError.invalidRef`
    /// when the provider sits outside the broker allowlist.
    public func secretRef() throws -> SecretRef {
        try SecretRef(provider: provider, item: id)
    }
}

extension ConnectionInputOrigin {
    /// True only for pasted inputs holding an empty placeholder.
    fileprivate var isEmptyPastedValue: Bool {
        if case .value(let pasted) = self {
            return pasted.isEmpty
        }
        return false
    }
}

private func validatedVariable(_ variable: String) throws -> String {
    try requireConnectionIdentifier(variable, field: .variable, maxBytes: MCPConnection.maxVariableBytes)
    return variable
}

private func validatedOrigin(_ origin: ConnectionInputOrigin) throws -> ConnectionInputOrigin {
    switch origin {
    case .value:
        return origin
    case .from(let provider, let id):
        try requireConnectionSlug(provider, field: .externalProvider, maxBytes: MCPConnection.maxSlugBytes)
        try requireExternalID(id)
        return origin
    }
}

// MARK: - Invocation credential

/// Resolved credential handed to invoke so the caller renders auth onto the
/// request. `value` is always `values[token]`; `grantedScopes` is absent for
/// non-OAuth connections (fail open on nil there) and for OAuth grants that
/// echoed nothing (fail closed there — see `evaluateScopeGap`).
public struct ToolInvocationCredential: Sendable, Equatable {
    /// Connection owner.
    public let owner: PolicyOwner
    /// Integration slug.
    public let integration: String
    /// Connection name.
    public let connection: String
    /// Auth template slug the values apply through.
    public let template: String
    /// Every resolved input (`variable → value`). Nil entries are
    /// unresolvable external items, preserved, never dropped.
    public let values: [String: SecretValue?]
    /// The integration's stored config, for template rendering.
    public let config: [String: String]
    /// OAuth scopes the grant actually covers. Nil means unknown: fail open.
    public let grantedScopes: [String]?

    /// Assembles a resolved credential from already-validated parts.
    public init(
        owner: PolicyOwner,
        integration: String,
        connection: String,
        template: String,
        values: [String: SecretValue?],
        config: [String: String] = [:],
        grantedScopes: [String]? = nil
    ) {
        self.owner = owner
        self.integration = integration
        self.connection = connection
        self.template = template
        self.values = values
        self.config = config
        self.grantedScopes = grantedScopes
    }

    /// The primary (`token`) resolved value. Nil when the connection carries
    /// no `token` variable or its item is unresolvable.
    public var value: SecretValue? {
        values[ConnectionValueInput.primaryVariable] ?? nil
    }
}

/// Parses a connection row's `oauthScope` (space-delimited, as echoed by the
/// token endpoint) into the credential's `grantedScopes`. Nil when the row
/// carries none; `evaluateScopeGap` fails open on nil for static connections
/// and fails closed for OAuth ones.
public func grantedScopes(fromOAuthScope scope: String?) -> [String]? {
    guard let scope else {
        return nil
    }
    let parsed = scope.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard parsed.isEmpty == false else {
        return nil
    }
    return parsed
}

// MARK: - Credential failure taxonomy

/// RFC 6749 §5.2 closed error-code set. Recovered from non-conform bodies only
/// against this set; conform envelopes may carry extension codes (e.g. RFC
/// 8693 `invalid_target`), which stay in the open `oauthErrorCode` string.
public enum OAuthTokenErrorCode: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case invalidRequest = "invalid_request"
    case invalidClient = "invalid_client"
    case invalidGrant = "invalid_grant"
    case unauthorizedClient = "unauthorized_client"
    case unsupportedGrantType = "unsupported_grant_type"
    case invalidScope = "invalid_scope"
}

/// A connection's value could not be resolved: the provider returned nothing,
/// or an OAuth token refresh failed. Labels only; never values. Throwable so
/// resolution paths surface it directly (executor `CredentialResolutionError`
/// is in the `ExecuteError` failure channel).
public struct MCPCredentialFailure: Error, Sendable, Equatable {
    /// Connection owner label.
    public let owner: PolicyOwner
    /// Integration label.
    public let integration: String
    /// Connection label.
    public let connection: String
    /// Label-only detail. Built by the factories below, never from values.
    public let message: String
    /// True when the stored grant is permanently invalid and the user must
    /// sign in again (`invalid_grant` and friends).
    public let reauthRequired: Bool
    /// The authorization server's RFC 6749 §5.2 error code, when the failure
    /// came from a token-endpoint refusal. Typed structurally so telemetry
    /// and classification read it without parsing the message.
    public let oauthErrorCode: String?
    /// True when an enterprise identity provider declined under administrator
    /// policy. Signing in again cannot help, and the client must NOT offer
    /// the ordinary OAuth flow as an alternative route around the policy.
    public let blockedByAdmin: Bool
    /// True when no usable credential material EXISTS on our side: nothing
    /// was sent upstream and no server refused anything.
    public let credentialMissing: Bool

    /// Assembles a failure from validated labels and a label-only message.
    public init(
        owner: PolicyOwner,
        integration: String,
        connection: String,
        message: String,
        reauthRequired: Bool = false,
        oauthErrorCode: String? = nil,
        blockedByAdmin: Bool = false,
        credentialMissing: Bool = false
    ) {
        self.owner = owner
        self.integration = integration
        self.connection = connection
        self.message = message
        self.reauthRequired = reauthRequired
        self.oauthErrorCode = oauthErrorCode
        self.blockedByAdmin = blockedByAdmin
        self.credentialMissing = credentialMissing
    }

    /// Stored grant is permanently invalid; the user must sign in again.
    public static func reauthRequired(
        owner: PolicyOwner,
        integration: String,
        connection: String,
        oauthErrorCode: String? = nil
    ) -> MCPCredentialFailure {
        MCPCredentialFailure(
            owner: owner,
            integration: integration,
            connection: connection,
            message: "Connection '\(connection)' for integration '\(integration)' needs re-authentication\(tokenCodeSuffix(oauthErrorCode)).",
            reauthRequired: true,
            oauthErrorCode: oauthErrorCode
        )
    }

    /// No usable credential material exists on our side.
    public static func credentialMissing(
        owner: PolicyOwner,
        integration: String,
        connection: String
    ) -> MCPCredentialFailure {
        MCPCredentialFailure(
            owner: owner,
            integration: integration,
            connection: connection,
            message: "Connection '\(connection)' for integration '\(integration)' has no usable credential material.",
            credentialMissing: true
        )
    }

    /// An enterprise identity provider declined under administrator policy.
    public static func blockedByAdmin(
        owner: PolicyOwner,
        integration: String,
        connection: String,
        oauthErrorCode: String? = nil
    ) -> MCPCredentialFailure {
        MCPCredentialFailure(
            owner: owner,
            integration: integration,
            connection: connection,
            message: "Connection '\(connection)' for integration '\(integration)' was declined by administrator policy; signing in again cannot help\(tokenCodeSuffix(oauthErrorCode)).",
            reauthRequired: true,
            oauthErrorCode: oauthErrorCode,
            blockedByAdmin: true
        )
    }

    /// The authorization server refused the stored credential without proving
    /// the grant dead (e.g. `invalid_client`: rotated app secret, fleet-wide).
    public static func refreshRejected(
        owner: PolicyOwner,
        integration: String,
        connection: String,
        oauthErrorCode: String? = nil
    ) -> MCPCredentialFailure {
        MCPCredentialFailure(
            owner: owner,
            integration: integration,
            connection: connection,
            message: "The authorization server refused the stored credential for connection '\(connection)' (integration '\(integration)')\(tokenCodeSuffix(oauthErrorCode)).",
            oauthErrorCode: oauthErrorCode
        )
    }

    /// Only `invalid_grant` proves the grant dead: the token is gone and the
    /// user must sign in again. Every other code (or none) leaves the grant
    /// standing. This mirrors only the §5.2-code branch of the executor
    /// redemption classifier (a 4xx verdict where the code alone decides, so a
    /// fleet-wide `invalid_client` is never mistaken for one dead grant). The
    /// classifier's transport-shape branches — an unusable token inside a
    /// success response, a codeless permanent rejection — need the HTTP shape
    /// and are decided downstream where that shape is visible.
    public static func grantDeadForTokenError(code: OAuthTokenErrorCode?) -> Bool {
        code == .invalidGrant
    }

    /// The §5.2 code parsed against the closed set. Nil for absent codes and
    /// for extension codes, which stay readable on `oauthErrorCode`.
    public var rfc6749Code: OAuthTokenErrorCode? {
        oauthErrorCode.flatMap(OAuthTokenErrorCode.init(rawValue:))
    }

    /// Classifies the failure from its structural fields, never the message.
    /// Admin policy wins over missing material because neither retrying nor
    /// reconnecting can help; missing material wins over re-auth because no
    /// server refused anything.
    public var kind: CredentialFailureKind {
        if blockedByAdmin {
            return .blockedByAdmin
        }
        if credentialMissing {
            return .credentialMissing
        }
        if reauthRequired {
            return .reauthRequired
        }
        return .refreshRejected
    }

    /// Enumerable failure mechanism for health verdicts and spans, where the
    /// free-text message must not go.
    public var healthReason: MCPHealthCheckReason {
        switch kind {
        case .blockedByAdmin:
            return .blockedByAdmin
        case .credentialMissing:
            return .credentialMissing
        case .reauthRequired, .refreshRejected:
            return .credentialRefreshRejected
        }
    }

    /// Agent recovery guidance. Reconnect prompts never carry retry guidance;
    /// the admin prompt never offers the ordinary sign-in route.
    public var recovery: CredentialRecovery {
        switch kind {
        case .blockedByAdmin:
            return .contactAdmin(prompt: "Connection '\(connection)' for integration '\(integration)' was declined by administrator policy. Ask an administrator to allow it; do not try other sign-in routes to walk around the policy.")
        case .credentialMissing:
            return .reconnect(prompt: "Connection '\(connection)' for integration '\(integration)' has no stored credential. Reconnect '\(connection)' to add one, then try the tool again.")
        case .reauthRequired:
            return .reconnect(prompt: "The grant for connection '\(connection)' (integration '\(integration)') is no longer valid. Reconnect '\(connection)' to sign in again, then try the tool again.")
        case .refreshRejected:
            return .reconnect(prompt: "The authorization server refused the stored credential for connection '\(connection)' (integration '\(integration)'). Reconnect '\(connection)'; if the refusal persists, the integration's app registration needs attention.")
        }
    }

    /// Credential failures never retry into success at this layer.
    public var retryable: Bool {
        false
    }
}

/// Credential failure classes, in classification precedence order.
public enum CredentialFailureKind: Sendable, Equatable {
    /// Stored grant permanently invalid; sign in again.
    case reauthRequired
    /// No usable material exists; nothing was sent upstream.
    case credentialMissing
    /// IdP declined under administrator policy; re-auth cannot help.
    case blockedByAdmin
    /// AS refused the stored credential; grant not proven dead.
    case refreshRejected
}

/// Agent recovery routes. Only the write-incomplete path retries.
public enum CredentialRecovery: Sendable, Equatable {
    /// Reconnect the connection (label-only prompt, never retry guidance).
    case reconnect(prompt: String)
    /// Ask an administrator; never the ordinary sign-in route.
    case contactAdmin(prompt: String)
    /// Retry the connection operation; the committed write did not finish.
    case retry
}

/// A connection references a credential provider key that isn't registered.
public struct MCPCredentialProviderNotRegistered: Error, Sendable, Equatable {
    /// The unregistered provider key label.
    public let provider: String

    /// Assembles the failure from the provider label.
    public init(provider: String) {
        self.provider = provider
    }

    /// Label-only detail.
    public var message: String {
        "Credential provider not registered: \(provider)"
    }
}

/// A committed credential write did not finish. Surfaces as retryable at the
/// HTTP edge; the only credential failure that retries.
public struct MCPCredentialWriteIncomplete: Error, Sendable, Equatable {
    /// Connection owner label.
    public let owner: PolicyOwner
    /// Integration label.
    public let integration: String
    /// Connection label.
    public let connection: String

    /// Assembles the failure from connection labels.
    public init(owner: PolicyOwner, integration: String, connection: String) {
        self.owner = owner
        self.integration = integration
        self.connection = connection
    }

    /// Label-only detail naming the incomplete write.
    public var message: String {
        "Credential write for \(owner.rawValue)/\(integration)/\(connection) is incomplete; retry the connection operation."
    }

    /// Always true: the next attempt may well succeed.
    public var retryable: Bool {
        true
    }

    /// The only credential recovery that retries.
    public var recovery: CredentialRecovery {
        .retry
    }
}

private func tokenCodeSuffix(_ code: String?) -> String {
    guard let code else {
        return ""
    }
    return " (authorization server code: \(code))"
}

// MARK: - OAuth scope tracking

/// Scopes that prove identity or offline access rather than resource access;
/// never "missing" when absent from a grant.
private let informationalOAuthScopes: Set<String> = ["openid", "email", "profile", "offline_access"]

/// Google's fully qualified identity scopes and their short forms.
private let googleScopeAliases: [String: String] = [
    "https://www.googleapis.com/auth/userinfo.email": "email",
    "https://www.googleapis.com/auth/userinfo.profile": "profile",
]

/// True for request-time meta-scopes (Microsoft `/.default`), which the
/// server expands and never echoes, so they can never be "missing".
private func isMetaOAuthScope(_ scope: String) -> Bool {
    scope.lowercased().hasSuffix("/.default")
}

/// Canonicalizes one scope for granted-vs-requested comparison. Aliased
/// identity scopes fold to short form; Microsoft graph scopes strip the
/// resource-URI prefix down to the final path segment.
public func canonicalOAuthScope(_ scope: String) -> String {
    if let aliased = googleScopeAliases[scope] {
        return aliased
    }
    if let leaf = graphScopeLeaf(scope) {
        return leaf
    }
    return scope
}

/// Strips a Microsoft graph resource-URI prefix to the final path segment.
/// Nil for anything that is not an absolute graph URL with a host of
/// graph.microsoft.com/us/de. Case-insensitive on scheme and host; the leaf
/// keeps its original case.
private func graphScopeLeaf(_ scope: String) -> String? {
    let lower = scope.lowercased()
    let withoutScheme: Substring
    if lower.hasPrefix("https://") {
        withoutScheme = scope.dropFirst("https://".count)
    } else if lower.hasPrefix("http://") {
        withoutScheme = scope.dropFirst("http://".count)
    } else {
        return nil
    }
    let parts = withoutScheme.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else {
        return nil
    }
    let host = parts[0].lowercased()
    guard host == "graph.microsoft.com" || host == "graph.microsoft.us" || host == "graph.microsoft.de" else {
        return nil
    }
    return lastPathSegment(withoutScheme)
}

/// Segment after the final "/" ("" when the path ends in "/"), mirroring
/// executor `slice(lastIndexOf("/") + 1)`.
private func lastPathSegment(_ path: Substring) -> String {
    var leaf = path
    var rest = path
    while let slash = rest.firstIndex(of: "/") {
        rest = rest[rest.index(after: slash)...]
        leaf = rest
    }
    return String(leaf)
}

/// Compares requested scopes against the granted set. Both sides canonicalize;
/// meta-scopes, informational scopes, blanks, and duplicates are skipped, and
/// the result preserves requested order. Mirrors `missingGrantedOAuthScopes`.
/// Case-sensitive (fail closed): `Mail.Read` does not cover `mail.read`.
/// Scope strings are case-sensitive upstream (Microsoft Graph treats those as
/// different scopes), so folding would grant coverage the provider denies.
/// Only the meta-scope suffix (`/.default`) and the graph host compare
/// case-insensitively; the scope leaf keeps its case.
public func missingGrantedScopes(requested: [String], granted: [String]) -> [String] {
    let grantedSet = Set(granted.map { canonicalOAuthScope($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.filter { $0.isEmpty == false })
    var seen = Set<String>()
    var missing: [String] = []
    for raw in requested {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            continue
        }
        guard isMetaOAuthScope(trimmed) == false else {
            continue
        }
        let scope = canonicalOAuthScope(trimmed)
        guard scope.isEmpty == false else {
            continue
        }
        guard informationalOAuthScopes.contains(scope) == false else {
            continue
        }
        guard seen.contains(scope) == false else {
            continue
        }
        seen.insert(scope)
        if grantedSet.contains(scope) == false {
            missing.append(scope)
        }
    }
    return missing
}

/// Granted-vs-declared scope gap with its reconnect prompt. The prompt names
/// the operation, the connection labels, and the missing count only: scope
/// values can encode customer resource names, so they stay structural on
/// `missing` and out of the prose. Never retry guidance: re-authenticating
/// the same grant returns the same error.
public struct OAuthScopeGap: Sendable, Equatable {
    /// Integration label.
    public let integration: String
    /// Connection label.
    public let connection: String
    /// Denied operation label.
    public let operation: String
    /// Canonical missing scopes, in declared order. Structural, not prose.
    public let missing: [String]

    /// Assembles a scope gap.
    public init(integration: String, connection: String, operation: String, missing: [String]) {
        self.integration = integration
        self.connection = connection
        self.operation = operation
        self.missing = missing
    }

    /// A scope gap never retries into success.
    public var retryable: Bool {
        false
    }

    /// Reconnect prompt. Names the operation and labels plus the missing
    /// count; re-authenticating the same grant is called out as futile.
    public var prompt: String {
        "The connection '\(connection)' for '\(integration)' cannot perform '\(operation)': its OAuth grant misses \(missing.count) required scope(s). Re-authenticating the same grant returns the same error. Reconnect '\(connection)' with broader access, or use a connection that already has it."
    }
}

/// Evaluates declared scopes against the granted set. `oauthClient` splits
/// unknown coverage: a nil grant on a non-OAuth connection fails open
/// (unknown coverage, no gap — static credentials carry no scope echo), while
/// a nil grant on an OAuth connection (`oauthClient` set) fails closed (an
/// OAuth grant that echoes nothing covers nothing, so every countable
/// declared scope misses and the gap prompts a reconnect). Full coverage
/// yields no gap; otherwise the returned gap carries the reconnect prompt.
/// An empty declared list yields no gap on either side: nothing required.
public func evaluateScopeGap(
    declared: [String],
    grantedScopes: [String]?,
    oauthClient: String? = nil,
    integration: String,
    connection: String,
    operation: String
) -> OAuthScopeGap? {
    let granted: [String]
    if let grantedScopes {
        granted = grantedScopes
    } else if oauthClient != nil {
        granted = []
    } else {
        return nil
    }
    let missing = missingGrantedScopes(requested: declared, granted: granted)
    guard missing.isEmpty == false else {
        return nil
    }
    return OAuthScopeGap(integration: integration, connection: connection, operation: operation, missing: missing)
}

// MARK: - Health vocabulary

/// The states a connection can be in. `expired` is the one this vocabulary
/// exists for; `misconfigured` is authenticated-but-rejected-on-configuration
/// (fix in the provider console, never reconnect); `unknown` is never
/// checked / no check configured.
public enum MCPConnectionHealthStatus: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case healthy
    case expired
    case misconfigured
    case degraded
    case unknown
}

/// Enumerable mechanism behind a non-healthy verdict. Safe for spans and
/// metrics, where the free-text detail must never go.
public enum MCPHealthCheckReason: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case credentialMissing = "credential_missing"
    case credentialRefreshRejected = "credential_refresh_rejected"
    case blockedByAdmin = "blocked_by_admin"
    case probeTimeout = "probe_timeout"
    case probeFailed = "probe_failed"
    case upstreamStatus = "upstream_status"
    case toolSyncFailed = "tool_sync_failed"
}

/// Outcome of running a health probe. Diagnostic detail is free text for
/// display; `reason` is the enumerable counterpart for telemetry.
public struct MCPConnectionHealth: Sendable, Equatable, Hashable, Codable {
    /// Verdict status.
    public let status: MCPConnectionHealthStatus
    /// HTTP status the probe observed, when the check ran against HTTP.
    public let httpStatus: Int?
    /// Display identity extracted from the probe response, when configured.
    public let identity: String?
    /// When the check ran.
    public let checkedAt: Date
    /// Human-readable diagnostic.
    public let detail: String?
    /// Enumerable failure mechanism for non-healthy verdicts.
    public let reason: MCPHealthCheckReason?

    /// Assembles a health verdict. Identity and detail are byte-capped and
    /// reject control/format characters.
    public init(
        status: MCPConnectionHealthStatus,
        httpStatus: Int? = nil,
        identity: String? = nil,
        checkedAt: Date,
        detail: String? = nil,
        reason: MCPHealthCheckReason? = nil
    ) throws {
        if let identity {
            try OperatorText.requireDisplayText(identity, field: .healthIdentity, maxBytes: MCPConnection.maxHealthIdentityBytes)
        }
        if let detail {
            try OperatorText.requireDisplayText(detail, field: .healthDetail, maxBytes: MCPConnection.maxHealthDetailBytes)
        }
        self.status = status
        self.httpStatus = httpStatus
        self.identity = identity
        self.checkedAt = checkedAt
        self.detail = detail
        self.reason = reason
    }

    /// Decodes by re-running the validating init, so persisted verdicts face
    /// the same byte caps and charset rules as fresh ones.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            status: try container.decode(MCPConnectionHealthStatus.self, forKey: .status),
            httpStatus: try container.decodeIfPresent(Int.self, forKey: .httpStatus),
            identity: try container.decodeIfPresent(String.self, forKey: .identity),
            checkedAt: try container.decode(Date.self, forKey: .checkedAt),
            detail: try container.decodeIfPresent(String.self, forKey: .detail),
            reason: try container.decodeIfPresent(MCPHealthCheckReason.self, forKey: .reason)
        )
    }
}

// MARK: - Validation

private func requireByteCap(_ value: String, field: MCPConnectionField, maxBytes: Int) throws {
    guard value.utf8.count <= maxBytes else {
        throw MCPConnectionError.tooLong(field: field, maxBytes: maxBytes)
    }
}

/// Connection/variable identifier: `[A-Za-z_$][A-Za-z0-9_$]*`. Mirrors
/// executor `isConnectionIdentifier`.
private func requireConnectionIdentifier(_ value: String, field: MCPConnectionField, maxBytes: Int) throws {
    try requireByteCap(value, field: field, maxBytes: maxBytes)
    guard isConnectionIdentifier(value) else {
        if value.isEmpty {
            throw MCPConnectionError.emptyField(field)
        }
        throw MCPConnectionError.invalidCharacters(field: field)
    }
}

/// True when the value is a connection/variable identifier
/// (`[A-Za-z_$][A-Za-z0-9_$]*`). Non-throwing probe for key-first UI flows;
/// throws-free counterpart of the name/variable validation. Mirrors executor
/// `isConnectionIdentifier`.
public func isConnectionIdentifier(_ value: String) -> Bool {
    guard value.isEmpty == false else {
        return false
    }
    let scalars = Array(value.unicodeScalars)
    guard isIdentifierStart(scalars[0]) else {
        return false
    }
    return scalars.dropFirst().allSatisfy(isIdentifierRest)
}

private func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x41...0x5A, 0x61...0x7A, 0x5F, 0x24:
        return true
    default:
        return false
    }
}

private func isIdentifierRest(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x24:
        return true
    default:
        return false
    }
}

/// Slug: ASCII alphanumeric start, then alphanumerics plus `_-`. Closed
/// RV-side charset for integration, template, provider, and OAuth client ids.
/// Dot-free by construction: slugs feed `addressLiteral` and
/// `MCPToolAddress`, whose grammar gives dots to segment boundaries, so a
/// dotted slug would silently misparse to a different address.
private func requireConnectionSlug(_ value: String, field: MCPConnectionField, maxBytes: Int) throws {
    try requireByteCap(value, field: field, maxBytes: maxBytes)
    guard isConnectionSlug(value) else {
        if value.isEmpty {
            throw MCPConnectionError.emptyField(field)
        }
        throw MCPConnectionError.invalidCharacters(field: field)
    }
}

private func isConnectionSlug(_ value: String) -> Bool {
    guard value.isEmpty == false else {
        return false
    }
    let scalars = Array(value.unicodeScalars)
    guard isSlugStart(scalars[0]) else {
        return false
    }
    return scalars.dropFirst().allSatisfy(isSlugRest)
}

private func isSlugStart(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:
        return true
    default:
        return false
    }
}

private func isSlugRest(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x2D:
        return true
    default:
        return false
    }
}

/// Opaque external item id: non-empty, capped, no control/format characters.
/// Core never parses the id itself. Scalar rule delegated to `OperatorText`.
private func requireExternalID(_ value: String) throws {
    guard value.isEmpty == false else {
        throw MCPConnectionError.emptyField(.externalID)
    }
    try requireByteCap(value, field: .externalID, maxBytes: MCPConnection.maxExternalIDBytes)
    guard OperatorText.containsDisallowedTextScalar(value) == false else {
        throw MCPConnectionError.invalidCharacters(field: .externalID)
    }
}

/// Single scope token: non-empty, capped, no inner whitespace.
private func requireScopeToken(_ value: String, field: MCPConnectionField, maxBytes: Int) throws {
    guard value.isEmpty == false else {
        throw MCPConnectionError.emptyField(field)
    }
    try requireByteCap(value, field: field, maxBytes: maxBytes)
    guard value.contains(where: { $0.isWhitespace }) == false else {
        throw MCPConnectionError.invalidCharacters(field: field)
    }
}

/// Space-delimited granted scope: non-empty, capped whole, each token
/// validated. Empty reads as unknown downstream, so it is rejected here:
/// unknown is spelled nil, never "".
private func requireOAuthScope(_ value: String) throws {
    guard value.isEmpty == false else {
        throw MCPConnectionError.emptyField(.oauthScope)
    }
    try requireByteCap(value, field: .oauthScope, maxBytes: MCPConnection.maxOAuthScopeBytes)
    for token in value.split(whereSeparator: { $0.isWhitespace }) {
        try requireScopeToken(String(token), field: .oauthScope, maxBytes: MCPConnection.maxScopeTokenBytes)
    }
}
