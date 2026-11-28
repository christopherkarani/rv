import Foundation
import RVDomain
import RVPolicy

/// A host mode change an agent asked for that waits for the owner
/// (`HostTighten.Outcome.proposal`).
struct HostModeProposal: Equatable, Sendable {
    let host: HookHost
    let mode: HostMode
    let reason: HostTighten.ProposalReason
}

/// Where a proposal goes. The seam F2 ("loosen is a proposal") points at
/// its proposal store, so the owner approves it with Touch ID from the menu
/// bar or rv term. Until then `UnstoredHostModeProposals` keeps nothing:
/// the proposal is the command the owner types, printed last.
protocol HostModeProposalSink: Sendable {
    /// Hands the proposal on. Returns the id the owner approves it by, or
    /// nil when nothing was stored. Never applies it.
    func submit(_ proposal: HostModeProposal) -> String?
}

struct UnstoredHostModeProposals: HostModeProposalSink {
    func submit(_ proposal: HostModeProposal) -> String? { nil }
}

/// Who asked for a host mode change, as far as the CLI can tell. Neither
/// fact is proof: `atTerminal` only decides whether the owner check may be
/// shown; the check itself is what makes a block permanent. Like
/// `DaemonDownOwnerConfirmation`, it needs stdin and stdout on a terminal,
/// and here also no agent marker: an agent holding a pty is not prompted,
/// and its block goes to `HostTighten` instead.
struct HostModeRequester: Equatable, Sendable {
    var atTerminal: Bool
    var callingHosts: Set<HookHost>

    /// No terminal, no known host: the least authority, and the default.
    static let unattended = HostModeRequester(atTerminal: false, callingHosts: [])

    static func live() -> HostModeRequester {
        let callingHosts = AgentHostMarkers.callingHosts(in: CLIProcess.environment())
        return HostModeRequester(
            atTerminal: CLIProcess.stdinIsTTY() && CLIProcess.stdoutIsTTY() && callingHosts.isEmpty,
            callingHosts: callingHosts)
    }
}

/// "14:22" in the viewer's time zone.
enum ClockText {
    static func hourMinute(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// "9 min left", rounding up so the last minute reads "1 min left".
    static func minutesLeft(_ seconds: Int) -> String {
        "\(max(1, (seconds + 59) / 60)) min left"
    }

    static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
