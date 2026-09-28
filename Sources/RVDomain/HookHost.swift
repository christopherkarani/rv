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
    /// Cursor hooks.json wire, not a host protocol.
    case cursor

    /// Setup/doctor slots. Claude is settings-merge, not an exclusive owned file.
    public static let setupSlotOrder: [HookHost] = [
        .grok, .pi, .opencode, .claude, .openclaw, .hermes, .codex, .cursor,
    ]
}

/// Agent-tag validation for the launch hook wire. The wire carries the
/// launch's agent name: when it names a `HookHost`, hook protocol applies,
/// otherwise it is staging-only (credential `agents` selection with no
/// hook participation). The 32-byte cap mirrors the control codec's hook
/// budget so client-side rejection matches the server exactly.
public enum AgentTagValidator {
    public static func isValid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 32 && value.utf8.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }
}
