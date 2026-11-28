import ArgumentParser
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVIPC
import RVPolicy

/// rvd's loosen-proposal methods (F2), as the CLI reaches them.
protocol ProposalServicing: Sendable {
    func proposeLoosen(_ params: ProposeLoosenParams) async -> Result<ProposeLoosenReply, ServiceClient.ServiceCommandError>
    func listProposals(_ params: ListProposalsParams) async -> Result<ListProposalsReply, ServiceClient.ServiceCommandError>
    func decideProposal(_ params: DecideProposalParams) async -> Result<DecideProposalReply, ServiceClient.ServiceCommandError>
}

extension ServiceClient: ProposalServicing {}

/// Where a loosen goes (F2). The owner at a terminal gets the owner check
/// they always got. Anyone else (an agent, a script, a pipe) never raises
/// a prompt and never changes anything: the loosen is sent to rvd as a
/// proposal the owner can approve later with Touch ID.
enum LoosenRoute {
    enum Outcome: Sendable, Equatable {
        /// The owner check passed: apply the change with this authorization.
        case owner(authorization: String)
        /// Filed with rvd; its lines are already printed. Change nothing
        /// and print no success mark.
        case proposed(ProposalItem)
    }

    /// The owner check for `summary` on an interactive terminal; otherwise
    /// files `change` as a proposal. A proposal rvd could not take prints
    /// one line and exits `EX_NOPERM`: the change is never made.
    /// `propose` (`--propose`): always a proposal, even on a terminal. The
    /// self-protection guard lets an agent run only this form.
    static func ownerOrProposal(
        _ change: PolicyLoosen, summary: String, command: String, propose: Bool = false
    ) async throws -> Outcome {
        if propose == false, isOwnerTerminal() {
            return .owner(authorization: try await OwnerConfirmation.require(summary))
        }
        return .proposed(try await Self.propose(change, command: command))
    }

    /// stdin and stdout are a terminal and this is not CI: the only place
    /// rv asks the owner directly. An agent's pseudo-terminal still meets
    /// rvd's own owner check there, as before.
    static func isOwnerTerminal() -> Bool {
        let ci = CLIProcess.environment()["CI"].map { $0.isEmpty == false && $0 != "0" && $0 != "false" } ?? false
        return allowsInteractiveAllowOnce(
            TTYCapability(stdinIsTTY: CLIProcess.stdinIsTTY(), stdoutIsTTY: CLIProcess.stdoutIsTTY(), ci: ci))
    }

    /// Files `change` and prints what happened. Throws `ExitCode` when rvd
    /// did not take it.
    static func propose(_ change: PolicyLoosen, command: String) async throws -> ProposalItem {
        let params = ProposeLoosenParams(
            change: change, from: proposer(), cwd: ProposalText.home(CLIProcess.workspacePath()),
            clientSemver: ProtocolVersion.serviceSemver)
        let answer = await service().proposeLoosen(params)
        let reply: ProposeLoosenReply
        switch answer {
        case .success(let value): reply = value
        case .failure: try refuse(command, "rvd is not reachable to save it as a proposal")
        }
        switch reply.outcome {
        case .filed:
            guard let item = reply.proposal else { try refuse(command, "rvd did not return the proposal") }
            CommandContext.writeStdout(ProposalText.filed(item, created: reply.created))
            return item
        case .invalid:
            try CommandContext.fail(
                "rv \(command): \(DisplayedText.field(reply.problem ?? "rvd refused this change")); nothing was sent\n",
                exitCode: 2)
        case .full:
            try refuse(command, "\(LoosenProposalLedger.maxPending) proposals already wait for \(ProposalText.ownerName)")
        case .unavailable:
            try refuse(command, "rvd could not save the proposal")
        }
    }

    private static func refuse(_ command: String, _ why: String) throws -> Never {
        try CommandContext.fail(
            "rv \(command): this makes rv less strict, so it needs \(ProposalText.ownerName) at a terminal (\(why)). Nothing changed\n",
            exitCode: OwnerConfirmation.refusalExitCode)
    }

    /// rvd, or the test context's stand-in. An installed context without
    /// one never reaches the live daemon: every call answers "no transport".
    static func service() -> any ProposalServicing {
        if let context = CLIProcess.context {
            return context.proposalService ?? UnreachableProposals()
        }
        return ServiceClient()
    }

    /// The agent host this process runs under, from the variable it sets.
    /// A label only: rvd treats it as untrusted text.
    static func proposer() -> String? {
        let environment = CLIProcess.environment()
        if environment["CLAUDECODE"] == "1" { return "claude" }
        if environment["CODEX_SANDBOX"] != nil || environment["CODEX_MANAGED_BY_NPM"] != nil { return "codex" }
        if environment["OPENCODE"] != nil { return "opencode" }
        return nil
    }
}

private struct UnreachableProposals: ProposalServicing {
    func proposeLoosen(_ params: ProposeLoosenParams) async -> Result<ProposeLoosenReply, ServiceClient.ServiceCommandError> {
        .failure(.noTransport)
    }
    func listProposals(_ params: ListProposalsParams) async -> Result<ListProposalsReply, ServiceClient.ServiceCommandError> {
        .failure(.noTransport)
    }
    func decideProposal(_ params: DecideProposalParams) async -> Result<DecideProposalReply, ServiceClient.ServiceCommandError> {
        .failure(.noTransport)
    }
}

/// The words every proposal screen uses (Policy Rules artifact, "Loosen:
/// a proposal, not a side door"). Pure.
enum ProposalText {
    /// Who decides: the account's first name ("Chris"), else "the owner".
    static var ownerName: String {
        guard let entry = getpwuid(getuid()), let gecos = entry.pointee.pw_gecos else { return "the owner" }
        let first = String(cString: gecos).split(separator: ",").first.map(String.init) ?? ""
        let name = first.split(separator: " ").first.map(String.init) ?? ""
        let safe = name.unicodeScalars.allSatisfy { DisplayedText.needsApprovalEscape($0) == false }
        return name.isEmpty || safe == false ? "the owner" : name
    }

    /// How the owner approves on this platform.
    #if canImport(LocalAuthentication)
    static let how = "Touch ID"
    #else
    static let how = "their login password"
    #endif

    /// Why this change counts as looser, in one sentence.
    static func whyLooser(_ change: PolicyLoosen) -> String {
        switch change {
        case .allowRule, .allowCommand: "An exception is looser."
        case .safetyNormal: "Normal safety is looser than strict."
        case .packOff: "Turning a pack off is looser."
        }
    }

    /// What the proposer sees once rvd stored it.
    static func filed(_ item: ProposalItem, created: Bool, owner: String = ownerName) -> String {
        let lead = created ? "Sent to \(owner) as proposal \(item.id)." : "Already sent to \(owner) as proposal \(item.id)."
        return [
            "\(CommandVocabulary.Glyph.rv.rawValue) \(lead) \(whyLooser(item.change))",
            "  \(owner) decides with \(how). Nothing changes until then. Don't retry.",
            "\(CommandVocabulary.Glyph.next.rawValue) rv \(ProposalsCommand.name) \(item.id)",
        ].joined(separator: "\n") + "\n"
    }

    /// `$HOME` shown as `~`.
    static func home(_ path: String) -> String {
        guard let home = CLIProcess.home()?.rawValue, home.isEmpty == false else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func status(_ status: ProposalStatus) -> String {
        switch status {
        case .pending: "waiting for you"
        case .approved: "approved"
        case .rejected: "declined"
        case .expired: "expired"
        }
    }

    static func ago(_ ms: Int64, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince1970 - Double(ms) / 1000))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60) min ago"
        case ..<86_400: return "\(seconds / 3600) h ago"
        default: return "\(seconds / 86_400) d ago"
        }
    }

    /// One proposal's lines: id, the looser line in rv's words, where it
    /// came from, and the proposer's own words, labelled as theirs.
    static func block(_ item: ProposalItem, now: Date, fingerprint: Bool = false) -> [String] {
        let glyph = item.status == .pending ? CommandVocabulary.Glyph.watched.rawValue : statusGlyph(item.status)
        var lines = ["  \(item.id)  \(glyph) Looser: \(DisplayedText.field(item.change.looser))"]
        let who = item.from.map(DisplayedText.field) ?? "an agent"
        var origin = ["from \(who)"]
        if let cwd = item.cwd { origin.append(DisplayedText.field(cwd)) }
        origin.append(ago(item.createdAtMs, now: now))
        lines.append("        " + origin.joined(separator: " · "))
        if let reason = item.change.reason {
            lines.append("        \(who) says: \(DisplayedText.field(reason))")
        }
        if item.status != .pending {
            var decided = "        \(status(item.status))"
            if let reason = item.declineReason { decided += ": \(DisplayedText.field(reason))" }
            lines.append(decided)
        }
        if fingerprint { lines.append("        fingerprint \(item.contentHash.prefix(12))") }
        return lines
    }

    private static func statusGlyph(_ status: ProposalStatus) -> String {
        switch status {
        case .approved: CommandVocabulary.Glyph.done.rawValue
        case .rejected, .expired: CommandVocabulary.Glyph.stopped.rawValue
        case .pending: CommandVocabulary.Glyph.watched.rawValue
        }
    }
}
