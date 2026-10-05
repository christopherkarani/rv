/// Approval-transport capability per coding host. ROUTING ONLY.
///
/// A capability row answers "where can the human approve?" — never "is this
/// approved?". The table is static code, not caller input: a spoofed
/// `HookHost` selects a different row, and every row fails closed because
/// no row manufactures ALLOW.
///
/// Step 8B ground truth (all 9 hosts): no host offers a trustworthy native
/// approval (a same-user process can replay any host attestation), and no
/// host can block for a human (hook budgets are seconds; RV's own IPC
/// budget is 700ms). Every host therefore routes human-required operations
/// to RVOperatorUI (or TTY allow-once) plus agent retry.
public struct HostApprovalCapability: Sendable, Equatable {
    /// Where a human approves an ASK for this host.
    public let route: HostApprovalRoute

    /// Whether the host's own Ask UI is authoritative. Always false:
    /// host attestations are unauthenticated same-user bytes.
    public let nativeAskAuthoritative: Bool

    /// Whether the hook invocation can stay blocked until a human
    /// decides. Always false: hook budgets are seconds.
    public let canBlockForHuman: Bool

    public static func capability(for host: HookHost) -> HostApprovalCapability {
        switch host {
        case .pi, .opencode, .claude, .openclaw, .hermes,
             .grok, .codex, .cursor, .antigravity:
            return HostApprovalCapability(
                route: .rvOperatorUI,
                nativeAskAuthoritative: false,
                canBlockForHuman: false
            )
        }
    }
}

/// Approval surface for a host ASK.
public enum HostApprovalRoute: Sendable, Equatable {
    /// RV records a pending row; the human allows once in RVOperatorUI
    /// (or redeems a TTY code); the agent retries the exact action.
    case rvOperatorUI
}
