/// Audit mode for one proxy's allowlist (OpenShell `enforcement: audit`).
///
/// A request that only the allowlist's host test would refuse is let
/// through, after `record` has durably written its would-be block. Every
/// other refusal still denies: the credential, the binary gate, plaintext
/// to the TLS port, the allowlist's port, IP literals and loopback names,
/// SNI binding, and the public-unicast dial filter. When `record` returns
/// false the request is denied `denied-policy`, so an audit pass is never
/// unlogged.
///
/// There is no global or runtime switch: a proxy is built with this only
/// for an owner-signed rule (`sandbox.enforcement: audit` in mcp.json).
public struct EgressAuditMode: Sendable {
    /// Persists one would-be block. True only when it is durable.
    public var record: @Sendable (EgressProxyDenial) -> Bool

    public init(record: @escaping @Sendable (EgressProxyDenial) -> Bool) {
        self.record = record
    }
}
