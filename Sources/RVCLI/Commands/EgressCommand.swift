import ArgumentParser
import Foundation
import RVDomain
import RVPolicy

/// Phase 4 review queue surface: blocked network egress becomes scoped
/// proposals, and the human approves or denies them here.
///
/// Reads (`pending`, `show`, `denials`) work today. Mutations (`approve`,
/// `deny`) are implemented behind `LocalControlBoundary`: local control
/// mutations stay refused until authenticated service routes land, so
/// these commands currently refuse like every other local mutation.
/// The ceremony (TTY + device-owner authentication + TOCTOU re-read)
/// mirrors the allow-once redeem tripwire.
struct Egress: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "egress",
        abstract: "Review blocked network egress and pending network proposals.",
        subcommands: [
            EgressPending.self, EgressShow.self, EgressApprove.self,
            EgressDeny.self, EgressDenials.self,
        ],
        defaultSubcommand: EgressPending.self
    )
}

/// One network proposal as the reviewer sees it.
struct EgressProposalView: Sendable, Equatable, Codable {
    var id: String
    var host: String
    var port: Int
    var state: String
    var reason: String
    var createdAt: Date
    var expiresAt: Date
}

/// One proxy denial-log line as the reviewer sees it.
struct EgressDenialView: Sendable, Equatable, Codable {
    var host: String
    var port: Int
    var reason: String
    var recordedAt: Date
}

enum EgressReviewError: Error, Sendable, Equatable {
    case unknownProposal
    case notAwaiting(String)
    case notNetworkProposal
    case reasonRequired
    case storeUnavailable
}

enum EgressReviewRun {
    static func store(home: HomeDirectory) -> PendingApprovalStore {
        PendingApprovalStore.makeLive(home: home)
    }

    /// Awaiting network proposals, oldest first.
    static func pending(
        store: PendingApprovalStore,
        now: Date
    ) async throws -> [EgressProposalView] {
        let records: [PendingApproval]
        do {
            records = try await store.list(now: now)
        } catch {
            throw EgressReviewError.storeUnavailable
        }
        return records.compactMap(view(for:)).sorted(by: { $0.createdAt < $1.createdAt })
    }

    static func view(for record: PendingApproval) -> EgressProposalView? {
        guard let rule = EgressProposal.rule(for: record) else { return nil }
        return EgressProposalView(
            id: record.id.rawValue,
            host: rule.host,
            port: rule.port,
            state: stateText(record.state),
            reason: record.reason.rawValue,
            createdAt: record.createdAt,
            expiresAt: record.expiresAt
        )
    }

    static func stateText(_ state: PendingApprovalState) -> String {
        switch state {
        case .awaitingHuman:
            return "awaiting-human"
        case .resolved(let resolution):
            return "resolved-\(resolution.decision.rawValue)"
        case .consumed(let resolution, _):
            return "consumed-\(resolution.decision.rawValue)"
        case .expired:
            return "expired"
        case .canceled:
            return "canceled"
        case .timedOut(let ending):
            return "timed-out-\(ending.policy.rawValue)"
        }
    }

    /// Last proxy-accepted live set, or nil when the supervisor has
    /// not reported (missing or corrupt file). Display only: unknown
    /// never fails the command and never reads as denied.
    static func loadedSnapshot(configDirectory: URL) -> EgressLoadedSnapshot? {
        let url = RVPolicyPaths.egressLoadedSnapshotFile(inConfigDir: configDirectory)
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return EgressLoadedSnapshot.parse(data)
    }

    static func prettyPending(
        _ views: [EgressProposalView], loaded: EgressLoadedSnapshot? = nil
    ) -> String {
        var lines: [String]
        if views.isEmpty {
            lines = ["No pending network proposals."]
        } else {
            lines = ["ID  HOST:PORT  STATE  EXPIRES"]
            for view in views {
                lines.append(
                    "\(view.id)  \(view.host):\(view.port)  \(view.state)  \(view.expiresAt)"
                )
            }
        }
        lines.append(loadedFooter(loaded))
        return lines.joined(separator: "\n") + "\n"
    }

    static func loadedFooter(_ loaded: EgressLoadedSnapshot?) -> String {
        guard let loaded else {
            return "loaded: unknown (supervisor has not reported)"
        }
        let rules = loaded.rules.count == 1 ? "1 rule" : "\(loaded.rules.count) rules"
        let approvals =
            loaded.approvalIDs.count == 1
            ? "1 approval" : "\(loaded.approvalIDs.count) approvals"
        return
            "loaded generation \(loaded.generation): \(rules) (\(approvals)) as of \(loaded.updatedAt)"
    }

    static func robot(_ views: [EgressProposalView]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(views)
        return String(decoding: data, as: UTF8.self)
    }

    struct ShowSnapshot: Sendable, Equatable, Codable {
        var proposal: EgressProposalView
        var rejectionReason: String?
        var loaded: EgressLoadedView?
    }

    struct EgressLoadedView: Sendable, Equatable, Codable {
        var generation: UInt64
        var ruleLoaded: Bool
        var rulesLoaded: Int
        var asOf: Date
    }

    static func robotShow(
        _ view: EgressProposalView,
        rejectionReason: String?,
        loaded: EgressLoadedSnapshot? = nil
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(
            ShowSnapshot(
                proposal: view, rejectionReason: rejectionReason,
                loaded: loadedView(for: view, loaded: loaded))
        )
        return String(decoding: data, as: UTF8.self)
    }

    static func prettyShow(
        _ view: EgressProposalView, rejectionReason: String?,
        loaded: EgressLoadedSnapshot? = nil
    ) -> String {
        var text =
            "proposal \(view.id)\n  egress \(view.host):\(view.port)\n  state \(view.state)\n"
            + "  reason \(view.reason)\n  created \(view.createdAt)\n  expires \(view.expiresAt)\n"
        if let rejectionReason {
            text += "  rejection-reason \(rejectionReason)\n"
        }
        text += "  \(loadedLine(for: view, loaded: loaded))\n"
        return text
    }

    static func loadedView(
        for view: EgressProposalView, loaded: EgressLoadedSnapshot?
    ) -> EgressLoadedView? {
        guard let loaded else { return nil }
        return EgressLoadedView(
            generation: loaded.generation,
            ruleLoaded: loaded.rules.contains { $0.host == view.host && $0.port == view.port },
            rulesLoaded: loaded.rules.count,
            asOf: loaded.updatedAt
        )
    }

    static func loadedLine(for view: EgressProposalView, loaded: EgressLoadedSnapshot?) -> String {
        guard let status = loadedView(for: view, loaded: loaded) else {
            return "loaded unknown"
        }
        return "loaded \(status.ruleLoaded ? "yes" : "no") (generation \(status.generation))"
    }

    /// Parse `egress-denials.jsonl` text into views, newest last. Corrupt
    /// lines drop (the log is display, never authority).
    static func parseDenialsLog(_ text: String) -> [EgressDenialView] {
        // String-or-number tolerant: the writer stringifies port/at today,
        // but a future numeric emission must not drop every line into
        // "no denials recorded".
        func stringField(_ json: [String: Any], _ key: String) -> String? {
            json[key] as? String
        }
        func intField(_ json: [String: Any], _ key: String) -> Int? {
            if let number = json[key] as? NSNumber { return number.intValue }
            if let string = json[key] as? String { return Int(string) }
            return nil
        }
        func doubleField(_ json: [String: Any], _ key: String) -> Double? {
            if let number = json[key] as? NSNumber { return number.doubleValue }
            if let string = json[key] as? String { return Double(string) }
            return nil
        }
        var views: [EgressDenialView] = []
        for line in text.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let host = stringField(json, "host"),
                let port = intField(json, "port"),
                let reason = stringField(json, "reason"),
                let at = doubleField(json, "recordedAt")
            else {
                continue
            }
            views.append(
                EgressDenialView(
                    host: host,
                    port: port,
                    reason: reason,
                    recordedAt: Date(timeIntervalSince1970: at)
                )
            )
        }
        return views
    }

    static func prettyDenials(_ views: [EgressDenialView]) -> String {
        if views.isEmpty {
            return "No recorded egress denials.\n"
        }
        return views.map { "\($0.host):\($0.port)  \($0.reason)  \($0.recordedAt)" }
            .joined(separator: "\n") + "\n"
    }

    static func robotDenials(_ views: [EgressDenialView]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(views)
        return String(decoding: data, as: UTF8.self)
    }

    /// Device-owner prompt naming the exact grant. The host plus port
    /// alone fully specify a network approval (no hidden payload).
    /// Non-web ports are flagged in the prompt: a live rule may name any
    /// port, and approving SSH/SMTP-shaped egress should never read like
    /// approving ordinary HTTPS.
    static func approveReason(host: String, port: Int) -> String {
        let marker = (port == 80 || port == 443) ? "" : " (non-web port)"
        return "Allow network egress to \(host):\(port)\(marker)."
    }

    static func denyReason(host: String, port: Int) -> String {
        "Deny network egress to \(host):\(port)."
    }

    /// TOCTOU bind: the re-read row must equal the reviewed row in full
    /// (terms included — expiry, continuation, timeout policy), not just
    /// identity fields, and still await a human. Any drift fails closed.
    static func reviewUnchanged(before: PendingApproval, after: PendingApproval) -> Bool {
        guard before == after else { return false }
        guard case .awaitingHuman = after.state else { return false }
        return true
    }

    /// Reserve from the shared LA-prompt budget (same file the allow-once
    /// ceremony spends from) so a pty agent cannot spam Touch ID through
    /// egress review either. Exhaustion fails closed as `.throttled`.
    static func reserveLAPrompt(store: PendingApprovalStore, now: Date) async throws {
        let budget = AllowOnceStore(baseDirectory: store.baseDirectory)
        guard await budget.reserveLAPrompt(now: now) else {
            throw AllowOnceAuthError.throttled
        }
    }

    /// Map a resolve-CAS failure: binding/state losses mean the proposal
    /// changed under review (retry), never a store outage.
    static func mapResolveError(_ error: Error) -> Error {
        guard let pending = error as? PendingApprovalError else {
            return EgressReviewError.storeUnavailable
        }
        switch pending {
        case .fingerprintMismatch, .identityMismatch, .continuationMismatch,
            .alreadyResolved, .alreadyConsumed, .expired, .canceled, .timedOut,
            .notFound:
            return AllowOnceError.redemptionChanged
        case .invalidRequest, .duplicateID, .notResolved, .encodeFailed,
            .lockFailed, .storeFull:
            return EgressReviewError.storeUnavailable
        }
    }

    /// Approve ceremony. Order mirrors the allow-once redeem tripwire:
    /// gates, pre-LA load, device-owner authentication, re-read plus
    /// compare, resolve CAS. No auto-approve path exists.
    static func approve(
        id: ApprovalID,
        tty: TTYCapability,
        robot: Bool,
        store: PendingApprovalStore,
        now: Date,
        refreshedNow: @Sendable () -> Date = { Date() }
    ) async throws -> EgressProposalView {
        guard allowsInteractiveAllowOnce(tty) else { throw AllowOnceError.ttyRequired }
        guard robot == false else { throw AllowOnceError.robotRefused }
        let before = try await loadAwaitingNetworkProposal(id: id, store: store, now: now)
        guard let rule = EgressProposal.rule(for: before) else {
            throw EgressReviewError.notNetworkProposal
        }
        try await reserveLAPrompt(store: store, now: now)
        try await CLIOwnerAuth.requireAuthenticated(
            reason: approveReason(host: rule.host, port: rule.port)
        )
        // Fresh stamp after the prompt: expiry/sweep on re-read and
        // resolve must judge the row as of now, not as of command start.
        let afterNow = refreshedNow()
        let after: PendingApproval
        do {
            after = try await store.load(id: id, now: afterNow)
        } catch {
            throw EgressReviewError.storeUnavailable
        }
        guard reviewUnchanged(before: before, after: after) else {
            throw AllowOnceError.redemptionChanged
        }
        let resolved: PendingApproval
        do {
            resolved = try await store.resolve(
                id: id,
                decision: .allowOnce,
                fingerprint: after.fingerprint,
                identity: after.identity,
                now: afterNow
            )
        } catch {
            throw mapResolveError(error)
        }
        guard let view = view(for: resolved) else {
            throw EgressReviewError.notNetworkProposal
        }
        return view
    }

    /// Deny ceremony: same gates as approve, plus a required human reason
    /// that the rejection carries for later review.
    static func deny(
        id: ApprovalID,
        reason: String,
        tty: TTYCapability,
        robot: Bool,
        store: PendingApprovalStore,
        now: Date,
        refreshedNow: @Sendable () -> Date = { Date() }
    ) async throws -> EgressProposalView {
        guard allowsInteractiveAllowOnce(tty) else { throw AllowOnceError.ttyRequired }
        guard robot == false else { throw AllowOnceError.robotRefused }
        guard PendingApprovalStore.canonicalRejectionReason(reason) != nil else {
            throw EgressReviewError.reasonRequired
        }
        let before = try await loadAwaitingNetworkProposal(id: id, store: store, now: now)
        guard let rule = EgressProposal.rule(for: before) else {
            throw EgressReviewError.notNetworkProposal
        }
        try await reserveLAPrompt(store: store, now: now)
        try await CLIOwnerAuth.requireAuthenticated(
            reason: denyReason(host: rule.host, port: rule.port)
        )
        let afterNow = refreshedNow()
        let after: PendingApproval
        do {
            after = try await store.load(id: id, now: afterNow)
        } catch {
            throw EgressReviewError.storeUnavailable
        }
        guard reviewUnchanged(before: before, after: after) else {
            throw AllowOnceError.redemptionChanged
        }
        let resolved: PendingApproval
        do {
            resolved = try await store.resolveWithReason(
                id: id,
                decision: .deny,
                fingerprint: after.fingerprint,
                identity: after.identity,
                reason: reason,
                now: afterNow
            )
        } catch PendingApprovalError.invalidRequest {
            throw EgressReviewError.reasonRequired
        } catch {
            throw mapResolveError(error)
        }
        guard let view = view(for: resolved) else {
            throw EgressReviewError.notNetworkProposal
        }
        return view
    }

    static func loadAwaitingNetworkProposal(
        id: ApprovalID,
        store: PendingApprovalStore,
        now: Date
    ) async throws -> PendingApproval {
        let record: PendingApproval
        do {
            record = try await store.load(id: id, now: now)
        } catch PendingApprovalError.notFound {
            throw EgressReviewError.unknownProposal
        } catch {
            throw EgressReviewError.storeUnavailable
        }
        guard EgressProposal.isNetworkProposal(record) else {
            throw EgressReviewError.notNetworkProposal
        }
        guard case .awaitingHuman = record.state else {
            throw EgressReviewError.notAwaiting(stateText(record.state))
        }
        return record
    }
}

struct EgressPending: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pending",
        abstract: "List network proposals awaiting a human."
    )

    @OptionGroup
    var format: FormatFlags

    func run() async throws {
        let ctx = CommandContext.current(command: "egress pending", format: format)
        do {
            let home = try ctx.requireHome()
            let views = try await EgressReviewRun.pending(
                store: EgressReviewRun.store(home: home),
                now: Date()
            )
            if ctx.explicitRobot {
                do {
                    ctx.writeStdout(try EgressReviewRun.robot(views) + "\n")
                } catch {
                    try ctx.fail("rv egress pending: encode failed\n")
                }
            } else {
                let loaded = EgressReviewRun.loadedSnapshot(
                    configDirectory: RVPolicyPaths.configDirectory(home: home))
                ctx.writeStdout(EgressReviewRun.prettyPending(views, loaded: loaded))
            }
        } catch EgressReviewError.storeUnavailable {
            try ctx.fail("rv egress pending: store unavailable\n", exitCode: 2)
        }
    }
}

struct EgressShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show one network proposal, including any rejection reason."
    )

    @Argument(help: "Proposal id from rv egress pending.")
    var id: String

    @OptionGroup
    var format: FormatFlags

    func run() async throws {
        let ctx = CommandContext.current(command: "egress show", format: format)
        let home = try ctx.requireHome()
        let store = EgressReviewRun.store(home: home)
        let record: PendingApproval
        do {
            record = try await store.load(id: ApprovalID(rawValue: id), now: Date())
        } catch PendingApprovalError.notFound {
            try ctx.fail("rv egress show: unknown proposal\n", exitCode: 2)
        } catch {
            try ctx.fail("rv egress show: store unavailable\n", exitCode: 2)
        }
        guard let view = EgressReviewRun.view(for: record) else {
            try ctx.fail("rv egress show: not a network proposal\n", exitCode: 2)
        }
        let rejection = await store.rejectionReason(for: record.id)
        let loaded = EgressReviewRun.loadedSnapshot(
            configDirectory: RVPolicyPaths.configDirectory(home: home))
        if ctx.explicitRobot {
            do {
                ctx.writeStdout(
                    try EgressReviewRun.robotShow(
                        view, rejectionReason: rejection, loaded: loaded) + "\n"
                )
            } catch {
                try ctx.fail("rv egress show: encode failed\n")
            }
        } else {
            ctx.writeStdout(
                EgressReviewRun.prettyShow(view, rejectionReason: rejection, loaded: loaded))
        }
    }
}

struct EgressApprove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "approve",
        abstract: "Approve one network proposal (refused until authenticated service routes land)."
    )

    @Argument(help: "Proposal id from rv egress pending.")
    var id: String

    @OptionGroup
    var format: FormatFlags

    func run() async throws {
        try LocalControlBoundary.requireOwnerAuthorization()
        let ctx = CommandContext.current(command: "egress approve", format: format)
        do {
            let view = try await EgressReviewRun.approve(
                id: ApprovalID(rawValue: id),
                tty: ctx.tty,
                robot: ctx.explicitRobot,
                store: EgressReviewRun.store(home: try ctx.requireHome()),
                now: Date()
            )
            ctx.writeStdout(
                "approved \(view.host):\(view.port) (live within seconds; no restart)\n"
            )
        } catch AllowOnceError.ttyRequired {
            try ctx.fail(
                "rv egress approve: requires an interactive TTY (stdin and stdout)\n",
                exitCode: 2
            )
        } catch AllowOnceError.robotRefused {
            try ctx.fail(
                "rv egress approve: --json/--robot refused for approve\n",
                exitCode: 2
            )
        } catch AllowOnceError.redemptionChanged {
            try ctx.fail(
                "rv egress approve: proposal changed during review; retry\n",
                exitCode: 2
            )
        } catch EgressReviewError.unknownProposal {
            try ctx.fail("rv egress approve: unknown proposal\n", exitCode: 2)
        } catch EgressReviewError.notNetworkProposal {
            try ctx.fail("rv egress approve: not a network proposal\n", exitCode: 2)
        } catch EgressReviewError.notAwaiting(let state) {
            try ctx.fail("rv egress approve: proposal is \(state)\n", exitCode: 2)
        } catch EgressReviewError.storeUnavailable {
            try ctx.fail("rv egress approve: store unavailable\n", exitCode: 2)
        } catch AllowOnceAuthError.required {
            try ctx.fail(
                "rv egress approve: device-owner authentication required\n",
                exitCode: 2
            )
        } catch AllowOnceAuthError.throttled {
            try ctx.fail(
                "rv egress approve: too many authentication prompts; wait and retry\n",
                exitCode: 2
            )
        }
    }
}

struct EgressDeny: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deny",
        abstract: "Deny one network proposal with a reason."
    )

    @Argument(help: "Proposal id from rv egress pending.")
    var id: String

    @Option(name: .long, help: "Why this egress is denied (required).")
    var reason: String?

    @OptionGroup
    var format: FormatFlags

    func run() async throws {
        try LocalControlBoundary.requireOwnerAuthorization()
        let ctx = CommandContext.current(command: "egress deny", format: format)
        guard let reason, reason.isEmpty == false else {
            try ctx.fail("rv egress deny: --reason is required\n", exitCode: 2)
        }
        do {
            let view = try await EgressReviewRun.deny(
                id: ApprovalID(rawValue: id),
                reason: reason,
                tty: ctx.tty,
                robot: ctx.explicitRobot,
                store: EgressReviewRun.store(home: try ctx.requireHome()),
                now: Date()
            )
            ctx.writeStdout("denied \(view.host):\(view.port)\n")
        } catch AllowOnceError.ttyRequired {
            try ctx.fail(
                "rv egress deny: requires an interactive TTY (stdin and stdout)\n",
                exitCode: 2
            )
        } catch AllowOnceError.robotRefused {
            try ctx.fail(
                "rv egress deny: --json/--robot refused for deny\n",
                exitCode: 2
            )
        } catch AllowOnceError.redemptionChanged {
            try ctx.fail(
                "rv egress deny: proposal changed during review; retry\n",
                exitCode: 2
            )
        } catch EgressReviewError.reasonRequired {
            try ctx.fail(
                "rv egress deny: --reason is required (one line, 500 chars)\n",
                exitCode: 2
            )
        } catch EgressReviewError.unknownProposal {
            try ctx.fail("rv egress deny: unknown proposal\n", exitCode: 2)
        } catch EgressReviewError.notNetworkProposal {
            try ctx.fail("rv egress deny: not a network proposal\n", exitCode: 2)
        } catch EgressReviewError.notAwaiting(let state) {
            try ctx.fail("rv egress deny: proposal is \(state)\n", exitCode: 2)
        } catch EgressReviewError.storeUnavailable {
            try ctx.fail("rv egress deny: store unavailable\n", exitCode: 2)
        } catch AllowOnceAuthError.required {
            try ctx.fail(
                "rv egress deny: device-owner authentication required\n",
                exitCode: 2
            )
        } catch AllowOnceAuthError.throttled {
            try ctx.fail(
                "rv egress deny: too many authentication prompts; wait and retry\n",
                exitCode: 2
            )
        }
    }
}

struct EgressDenials: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "denials",
        abstract: "Show recent proxy denials (policy blocks become proposals)."
    )

    @Option(name: .long, help: "Maximum rows to show.")
    var limit: Int = 20

    @OptionGroup
    var format: FormatFlags

    func run() async throws {
        let ctx = CommandContext.current(command: "egress denials", format: format)
        guard limit > 0 else {
            try ctx.fail("rv egress denials: --limit must be positive\n", exitCode: 2)
        }
        let home = try ctx.requireHome()
        let url = RVPolicyPaths.configDirectory(home: home)
            .appendingPathComponent("egress-denials.jsonl", isDirectory: false)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let views = Array(EgressReviewRun.parseDenialsLog(text).suffix(limit))
        if ctx.explicitRobot {
            do {
                ctx.writeStdout(try EgressReviewRun.robotDenials(views) + "\n")
            } catch {
                try ctx.fail("rv egress denials: encode failed\n")
            }
        } else {
            ctx.writeStdout(EgressReviewRun.prettyDenials(views))
        }
    }
}
