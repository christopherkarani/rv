public enum HookHost: String, Codable, Hashable, Sendable, CaseIterable {
    case grok
    /// Pi adapter wire, not a host protocol.
    case pi
    /// OpenCode adapter wire, not a host protocol.
    case opencode
}
