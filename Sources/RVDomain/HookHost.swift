public enum HookHost: String, Codable, Hashable, Sendable, CaseIterable {
    case grok
    /// Pi adapter wire, not a host protocol.
    case pi
    /// OpenCode adapter wire, not a host protocol.
    case opencode
    /// Claude Code settings-merge host.
    case claude

    /// Setup/doctor slots. Claude is settings-merge, not an exclusive owned file.
    public static let setupSlotOrder: [HookHost] = [.grok, .pi, .opencode, .claude]
}
