import Foundation
import RVDomain

/// What an unconfirmed `block` of a host becomes (Q4, Chris, 2026-11-27:
/// "Proposal or 1-hour expiry"). Tightening stays free, but a block that
/// would stop agents working must never lock an agent out:
///
/// - the owner, confirmed at a terminal, sets `block` for good;
/// - a block of a host that is not the asking agent's own applies for one
///   hour (`GuardWindow.temporaryBlockLimit`) and then ends on its own, the
///   stored mode untouched underneath;
/// - a block of the asking agent's own host, of a host rv cannot tell apart
///   from it (no agent marker at all), or of a host that is `off` (unwired:
///   blocking it means wiring hooks back in, which an expiry cannot undo
///   exactly) is a proposal: nothing changes until the owner types it.
///
/// Pure: the shell (`HostModeRun.setMode`) reads the facts and writes the
/// result.
public enum HostTighten {
    /// Why a block waits for the owner.
    public enum ProposalReason: String, Sendable, Equatable {
        /// The host is the one the asking agent runs in.
        case ownHost = "own-host"
        /// No agent marker in the environment: the asker could be any host.
        case unknownCaller = "unknown-caller"
        /// The host is `off`, so blocking it would wire hooks back in.
        case hostOff = "host-off"
    }

    public enum Outcome: Sendable, Equatable {
        /// Store `block` in `guard.hosts`, as asked.
        case permanent
        /// Store a block that ends at `window.until`.
        case temporary(GuardWindow)
        /// An agent's block of this host is already open; it is not extended.
        case alreadyTemporary(GuardWindow)
        /// Change nothing; the owner decides.
        case proposal(ProposalReason)
    }

    /// The outcome of a `block` asked for without the owner's check.
    /// `storedMode` is the host's effective stored mode (its entry, else the
    /// global `guard.mode`); `openBlock` an agent's block already open now.
    public static func unconfirmedBlock(
        of host: HookHost,
        storedMode: HostMode,
        openBlock: GuardWindow?,
        callingHosts: Set<HookHost>,
        now: Date
    ) -> Outcome {
        // Already enforcing: storing `block` changes nothing agents feel.
        if storedMode == .block { return .permanent }
        if let openBlock { return .alreadyTemporary(openBlock) }
        if storedMode == .off { return .proposal(.hostOff) }
        if callingHosts.isEmpty { return .proposal(.unknownCaller) }
        if callingHosts.contains(host) { return .proposal(.ownHost) }
        return .temporary(GuardWindow(startingAt: now, lasting: GuardWindow.temporaryBlockLimit))
    }
}

/// Which agent hosts this process seems to run under, from the variables
/// each host sets in its tools' environment. A marker only ever adds a
/// host, and more hosts only turn a temporary block into a proposal, so a
/// marker inherited from an outer agent errs toward asking the owner. An
/// agent can unset its markers: then the set is empty and its block is a
/// proposal too (`HostTighten.ProposalReason.unknownCaller`). The one
/// residual case, an agent with no marker of its own under an outer agent
/// that set one, gets at most the one-hour block, which ends on its own.
public enum AgentHostMarkers {
    public static func callingHosts(in environment: [String: String]) -> Set<HookHost> {
        var hosts: Set<HookHost> = []
        for key in environment.keys {
            for (host, markers) in table where markers.contains(where: { $0.matches(key) }) {
                hosts.insert(host)
            }
        }
        return hosts
    }

    private enum Marker {
        case exact(String)
        case prefix(String)

        func matches(_ key: String) -> Bool {
            switch self {
            case .exact(let name): key == name
            case .prefix(let start): key.hasPrefix(start)
            }
        }
    }

    // CODEX_HOME is a user setting a person may export in any shell, so it
    // is not a marker; every other CODEX_ variable is.
    private static let table: [(HookHost, [Marker])] = [
        (.claude, [.exact("CLAUDECODE"), .prefix("CLAUDE_CODE_")]),
        (.codex, [.exact("CODEX_SANDBOX"), .exact("CODEX_SANDBOX_NETWORK_DISABLED"), .exact("CODEX_THREAD_ID"), .exact("CODEX_CI")]),
        (.cursor, [.exact("CURSOR_AGENT"), .exact("CURSOR_TRACE_ID")]),
        (.opencode, [.exact("OPENCODE"), .prefix("OPENCODE_")]),
        (.grok, [.prefix("GROK_")]),
        (.pi, [.prefix("PI_CODING_AGENT")]),
        (.openclaw, [.prefix("OPENCLAW_")]),
        (.hermes, [.prefix("HERMES_")]),
        (.antigravity, [.prefix("ANTIGRAVITY_")]),
        (.muse, [.prefix("MUSE_")]),
    ]
}
