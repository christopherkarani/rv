import ArgumentParser
import Foundation
import RVDomain
import RVIPC
import RVPolicy

/// `rv proposals`: what agents asked rv to loosen, and why (F2). Anyone
/// may read. Approving needs the owner at a terminal and rvd's own owner
/// check (Touch ID or the login password); rvd then applies exactly the
/// proposal that was shown, by its content hash.
struct ProposalsCommand: AsyncParsableCommand {
    static let name = CommandVocabulary.Command.proposals.rawValue

    static let configuration = CommandConfiguration(
        commandName: name,
        abstract: "What agents asked rv to loosen; approve or decline.",
        subcommands: [ProposalsList.self, ProposalsApprove.self, ProposalsReject.self],
        defaultSubcommand: ProposalsList.self
    )
}

struct ProposalsList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Waiting proposals, or one proposal by id."
    )

    @Argument(help: "A proposal id (p-21) to show with its fingerprint.")
    var id: String?

    @Flag(name: .customLong("all"), help: "Also show approved, declined and expired proposals.")
    var all = false

    func run() async throws {
        let wanted = try id.map { try ProposalsRun.parseID($0, command: "proposals") }
        let items = try await ProposalsRun.load(includeDecided: all || wanted != nil, command: "proposals")
        CommandContext.writeStdout(ProposalsRun.render(items, id: wanted, now: Date()))
        if let wanted, items.contains(where: { $0.id == wanted }) == false {
            throw ExitCode(1)
        }
    }
}

struct ProposalsApprove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "approve",
        abstract: "Approve one proposal with Touch ID or your password; rvd applies it."
    )

    @Argument(help: "The proposal id, e.g. p-21.")
    var id: String

    @OptionGroup
    var format: FormatFlags

    func run() async throws {
        let command = "proposals approve"
        let proposal = try ProposalsRun.parseID(id, command: command)
        try ProposalsRun.requireOwnerTerminal(command: command, format: format)
        let item = try await ProposalsRun.pendingItem(proposal, command: command)
        let now = Date()
        CommandContext.writeStdout(
            (["\(CommandVocabulary.Glyph.rv.rawValue) rv  approve this?"] + ProposalText.block(item, now: now, fingerprint: true))
                .joined(separator: "\n") + "\n")
        let proof = try ProposalsRun.ownerProof(for: item)
        #if canImport(LocalAuthentication)
        CommandContext.writeStderr(
            "rv: approve only the Touch ID or password prompt that names \(item.id) [\(item.contentHash.prefix(12))]; decline any other\n")
        #endif
        let answer = await LoosenRoute.service().decideProposal(DecideProposalParams(
            id: item.id, contentHash: item.contentHash, decision: .approve, proof: proof,
            clientSemver: ProtocolVersion.serviceSemver))
        let reply = try ProposalsRun.reply(answer, command: command)
        switch reply.outcome {
        case .approved:
            CommandContext.writeStdout(
                "\(CommandVocabulary.Glyph.done.rawValue) Approved \(item.id): \(DisplayedText.field(item.change.looser))\n")
        case .ownerRefused:
            do {
                try OwnerConfirmation.accept(
                    .success(reply.owner ?? ConfirmOwnerActionReply(outcome: .declined)), summary: "approving \(item.id)")
                try CommandContext.fail("rv: approving \(item.id) was not approved\n", exitCode: OwnerConfirmation.refusalExitCode)
            } catch let refused as OwnerConfirmation.Refused {
                try CommandContext.fail(refused.message + "\n", exitCode: OwnerConfirmation.refusalExitCode)
            }
        case .applyFailed:
            try CommandContext.fail(
                "rv \(command): you approved \(item.id), but rv could not apply it: "
                    + "\(DisplayedText.field(reply.problem ?? "unknown error")). Nothing changed; it is still waiting\n")
        default:
            try ProposalsRun.failDecision(reply, id: item.id, command: command)
        }
    }
}

struct ProposalsReject: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reject",
        abstract: "Decline one proposal; nothing changes.",
        aliases: ["decline"]
    )

    @Argument(help: "The proposal id, e.g. p-21.")
    var id: String

    @Option(name: [.customShort("r"), .customLong("reason")], help: "Why, for the agent to read.")
    var reason: String?

    @OptionGroup
    var format: FormatFlags

    func run() async throws {
        let command = "proposals reject"
        let proposal = try ProposalsRun.parseID(id, command: command)
        try ProposalsRun.requireOwnerTerminal(command: command, format: format)
        let item = try await ProposalsRun.pendingItem(proposal, command: command)
        let answer = await LoosenRoute.service().decideProposal(DecideProposalParams(
            id: item.id, contentHash: item.contentHash, decision: .reject, reason: reason,
            clientSemver: ProtocolVersion.serviceSemver))
        let reply = try ProposalsRun.reply(answer, command: command)
        guard reply.outcome == .rejected else {
            try ProposalsRun.failDecision(reply, id: item.id, command: command)
        }
        CommandContext.writeStdout("\(CommandVocabulary.Glyph.done.rawValue) Declined \(item.id). Nothing changed.\n")
    }
}

enum ProposalsRun {
    static func parseID(_ raw: String, command: String) throws -> ProposalID {
        guard let id = ProposalID(rawValue: raw.trimmingCharacters(in: .whitespaces)) else {
            try CommandContext.fail(
                "rv \(command): \(DisplayedText.field(raw)) is not a proposal id (like p-21)\n", exitCode: 2)
        }
        return id
    }

    /// Approve and decline take only a person at a terminal, as every
    /// owner gate does. rvd still checks the owner for an approval.
    static func requireOwnerTerminal(command: String, format: FormatFlags) throws {
        guard LoosenRoute.isOwnerTerminal() else {
            try CommandContext.fail(
                "rv \(command): \(OwnerGateRefusal.ttyRequired.text(subject: .allowlistEntry))\n",
                exitCode: OwnerGateRefusal.ttyRequired.exitCode)
        }
        guard format.json == false, format.robot == false else {
            try CommandContext.fail(
                "rv \(command): \(OwnerGateRefusal.robotRefused.text(subject: .allowlistEntry))\n",
                exitCode: OwnerGateRefusal.robotRefused.exitCode)
        }
    }

    static func load(includeDecided: Bool, command: String) async throws -> [ProposalItem] {
        let answer = await LoosenRoute.service().listProposals(ListProposalsParams(includeDecided: includeDecided))
        guard case .success(let reply) = answer, reply.readable else {
            try CommandContext.fail("rv \(command): rvd is not reachable, so proposals cannot be read. Run rv doctor.\n")
        }
        // A row whose content does not hash to its own hash is not shown as
        // approvable: rvd would refuse it anyway.
        return reply.proposals
    }

    /// The pending proposal `id`, checked against its content hash before
    /// it is shown: what the owner reads is what the hash names.
    static func pendingItem(_ id: ProposalID, command: String) async throws -> ProposalItem {
        let items = try await load(includeDecided: true, command: command)
        guard let item = items.last(where: { $0.id == id }) else {
            try CommandContext.fail("rv \(command): no proposal \(id). See them: rv \(ProposalsCommand.name)\n")
        }
        guard item.status == .pending else {
            try CommandContext.fail("rv \(command): \(id) is already \(ProposalText.status(item.status)); nothing changed\n")
        }
        let hash = LoosenProposalLedger.contentHash(id: item.id, change: item.change, from: item.from, cwd: item.cwd)
        guard hash == item.contentHash else {
            try CommandContext.fail("rv \(command): \(id) does not match its fingerprint; nothing changed\n")
        }
        return item
    }

    /// Linux: the owner's login password, read from the terminal for rvd
    /// to check. macOS: none (rvd shows its own prompt). A test context
    /// reads no terminal and sends none; rvd's check still decides.
    static func ownerProof(for item: ProposalItem) throws -> OwnerProof? {
        #if canImport(LocalAuthentication)
        return nil
        #else
        if CLIProcess.context != nil { return nil }
        if let locked = OwnerConfirmation.refusalIfAccountLocked() {
            try CommandContext.fail("rv: approving \(item.id) was not done: \(locked)\n", exitCode: OwnerConfirmation.refusalExitCode)
        }
        guard let password = OwnerConfirmation.ownerPasswordForRvd(
            prompt: "rv: approve \(item.id) [\(item.contentHash.prefix(12))]\nPassword for \(UserName.current ?? "your account"): ")
        else {
            try CommandContext.fail(
                "rv: approving \(item.id) needs your login password at an interactive terminal\n",
                exitCode: OwnerConfirmation.refusalExitCode)
        }
        return OwnerProof(password: password)
        #endif
    }

    static func reply(
        _ answer: Result<DecideProposalReply, ServiceClient.ServiceCommandError>, command: String
    ) throws -> DecideProposalReply {
        guard case .success(let reply) = answer else {
            try CommandContext.fail("rv \(command): rvd is not reachable; nothing changed. Run rv doctor.\n")
        }
        return reply
    }

    static func failDecision(_ reply: DecideProposalReply, id: ProposalID, command: String) throws -> Never {
        let why: String
        switch reply.outcome {
        case .changed: why = "\(id) changed after it was shown; nothing changed. Look again: rv \(ProposalsCommand.name) \(id)"
        case .notFound: why = "no proposal \(id)"
        case .notPending: why = "\(id) is already \(ProposalText.status(reply.proposal?.status ?? .expired)); nothing changed"
        case .invalid: why = "\(id) cannot be applied: \(DisplayedText.field(reply.problem ?? "invalid"))"
        case .unavailable: why = "rvd could not read or write its proposals; nothing changed"
        case .approved, .rejected, .ownerRefused, .applyFailed: why = "unexpected answer from rvd; nothing changed"
        }
        try CommandContext.fail("rv \(command): \(why)\n")
    }

    /// The list, or one proposal. The next command comes last.
    static func render(_ items: [ProposalItem], id: ProposalID?, now: Date) -> String {
        let rv = CommandVocabulary.Glyph.rv.rawValue
        let next = CommandVocabulary.Glyph.next.rawValue
        if let id {
            guard let item = items.last(where: { $0.id == id }) else { return "\(rv) rv  no proposal \(id)\n" }
            var lines = ["\(rv) rv  proposal \(id), \(ProposalText.status(item.status))"]
            lines += ProposalText.block(item, now: now, fingerprint: true)
            if item.status == .pending { lines += ["", "\(next) rv \(ProposalsCommand.name) approve \(id)"] }
            return lines.joined(separator: "\n") + "\n"
        }
        let waiting = items.filter { $0.status == .pending }
        guard items.isEmpty == false else { return "\(rv) rv  no proposals wait for you\n" }
        let count = waiting.count == 1 ? "1 proposal waits" : "\(waiting.count) proposals wait"
        var lines = ["\(rv) rv  \(count) for you", ""]
        for item in items { lines += ProposalText.block(item, now: now) }
        if let first = waiting.first { lines += ["", "\(next) rv \(ProposalsCommand.name) approve \(first.id)"] }
        return lines.joined(separator: "\n") + "\n"
    }
}
