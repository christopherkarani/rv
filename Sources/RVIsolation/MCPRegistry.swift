import RVDomain

/// Minimal routing record for one tool address.
///
/// Execution is owned by T8 (ScopedInvoker): this record carries routing only —
/// address, static-tier flag, and plugin default — and never an invoke closure,
/// transport handle, or credential. No execution signature is defined here by design.
public struct MCPHandlerRecord: Sendable, Equatable, Hashable, Codable {
    /// Validated address this record serves.
    public let address: MCPToolAddress
    /// True when the address is pinned in the static-fqid tier and bypasses pattern matching.
    public let isStaticFqid: Bool
    /// Per-handler fallback suggested by the owning plugin. Composition with the
    /// store-level plugin default is owned by T8 (ScopedInvoker); the registry only stores it.
    public let pluginDefault: PolicyAction

    /// Assembles one routing record.
    public init(address: MCPToolAddress, isStaticFqid: Bool, pluginDefault: PolicyAction) {
        self.address = address
        self.isStaticFqid = isStaticFqid
        self.pluginDefault = pluginDefault
    }
}

/// Immutable address-to-handler map. Routing only; never executes.
///
/// T8 seam: `ScopedInvoker` looks the handler up here, then enforces its own
/// policy-validate-approve-credential-invoke ordering over its own transports.
/// Nothing in this file validates arguments, elicits approval, resolves credentials,
/// or invokes tools. All registrations are fixed at init; there is no mutation API.
public struct MCPRegistry: Sendable {
    private let handlers: [MCPToolAddress: MCPHandlerRecord]

    /// Builds an immutable registry. Later records win on duplicate addresses.
    public init(handlers: [MCPHandlerRecord] = []) {
        self.handlers = Dictionary(
            handlers.map { ($0.address, $0) },
            uniquingKeysWith: { _, last in last }
        )
    }

    /// Returns the record for one validated address, or nil when unregistered.
    public func handler(for address: MCPToolAddress) -> MCPHandlerRecord? {
        handlers[address]
    }

    /// Number of distinct registered addresses.
    public var count: Int {
        handlers.count
    }
}
