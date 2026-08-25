public enum HookHost: String, Codable, Hashable, Sendable, CaseIterable {
    case grok
    /// Pi adapter wire, not a host protocol.
    case pi
    /// OpenCode adapter wire, not a host protocol.
    case opencode
    /// Claude Code settings-merge host.
    case claude

    /// Exclusive owned-file setup/doctor slots. Claude settings merge is CL-T4.
    public static let setupSlotOrder: [HookHost] = [.grok, .pi, .opencode]
}
