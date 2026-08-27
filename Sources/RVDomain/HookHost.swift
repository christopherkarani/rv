public enum HookHost: String, Codable, Hashable, Sendable, CaseIterable {
    case grok
    /// Pi adapter wire, not a host protocol.
    case pi
    /// OpenCode adapter wire, not a host protocol.
    case opencode
    /// Claude Code settings-merge host.
    case claude
    /// OpenClaw plugin wire, not a host protocol.
    case openclaw
    /// Hermes plugin wire, not a host protocol.
    case hermes
    /// Codex hooks.json wire, not a host protocol.
    case codex

    /// Setup/doctor slots. Claude is settings-merge, not an exclusive owned file.
    public static let setupSlotOrder: [HookHost] = [
        .grok, .pi, .opencode, .claude, .openclaw, .hermes, .codex,
    ]
}
