import ArgumentParser
import Foundation
import RVDomain
import RVEngine
import RVIPC
import RVPolicy
import RVService

/// Step 8B.1 attestation outcome. Either case means NO grant was planted:
/// the caller must fail closed and must never fall back to file state.
enum AllowOnceAttestError: Error, Equatable {
    /// Daemon unreachable (down, timeout, transport). Retry later; the
    /// pending code stays live.
    case serviceUnavailable
    /// rvd refused the request itself (an unidentified caller, or a
    /// malformed or non-redeemable grant).
    case serviceDenied
    /// rvd has no record of issuing this code: rvd restarted since it
    /// issued it (on a deny or `rv allow-once mint`), or the row was written
    /// by someone else. rvd shows its owner prompt only for codes it issued.
    case notIssuedByService
    /// rvd ran the owner check and it refused (declined, wrong password,
    /// locked out, another prompt open, no prompt possible).
    case notApproved(ConfirmOwnerActionReply)
    /// The command or cwd is too long to show in full in a prompt, so it
    /// cannot be approved there. Nothing is ever approved from a shortened
    /// description.
    case notShowable
    /// rvd said it planted but not that it checked the owner the way this
    /// platform's rvd does. Not believed: nothing is reported as allowed.
    case ownerCheckUnconfirmed
}

enum AllowOnceCLI {
    static func interactiveTTY(
        json: Bool,
        robot: Bool,
        plain: Bool,
        noColor: Bool
    ) -> (tty: TTYCapability, robot: Bool) {
        let ctx = CommandContext.current(
            command: "allow-once",
            json: json,
            robot: robot,
            plain: plain,
            noColor: noColor
        )
        return (ctx.tty, ctx.explicitRobot)
    }

    static func home(
        from environment: [String: String] = CLIProcess.environment()
    ) -> HomeDirectory? {
        HomeDirectory(validating: environment["HOME"] ?? "")
    }

    static func requireHome(
        from environment: [String: String] = CLIProcess.environment()
    ) throws -> HomeDirectory {
        guard let home = home(from: environment) else {
            try CommandContext.failHomeMissing(command: "allow-once")
        }
        return home
    }

    static func store(home: HomeDirectory) -> AllowOnceStore {
        AllowOnceStore.makeLive(home: home)
    }

    /// Redeems one unlock code into one exact-command grant. The owner's
    /// approval happens in rvd, not here: on macOS rvd shows its own
    /// Touch ID or password prompt naming the code it issued; on Linux rvd
    /// answers a first ask with its own description of that code, this
    /// process shows it above the password prompt, and rvd verifies the
    /// password. Nothing about this process is trusted by rvd. Order:
    ///
    /// 1. Gates cheapest-first (TTY, robot, code shape).
    /// 2. Atomically read display row + fingerprint.
    /// 3. Re-read + compare fingerprint AND full row AND payload digest
    ///    (TOCTOU bind: a swapped file aborts with redemptionChanged; rvd
    ///    independently refuses anything that differs from what it issued).
    /// 4. Attest to the daemon (rvd matches the code it issued, runs the
    ///    owner check, enforces per-epoch code single-use, then plants).
    /// 5. Linux: on rvd's `proofRequired` answer, read the login password
    ///    under rvd's description and attest again with it.
    /// 6. Flip the file row as a display projection (best-effort: a flip
    ///    failure after a planted attestation is a display gap, still
    ///    granted; an attest failure leaves pending intact for retry).
    ///
    /// Post-LA equality gate: the re-read row must match the reviewed
    /// row exactly. Fingerprint-only comparison would let a same-user
    /// file swap redirect the attest (e.g. cwd) after the human
    /// approved; whole-row equality fails closed on any drift. M-07: the
    /// payload digest joins the comparison so a swapped hidden payload
    /// aborts instead of attesting.
    static func redemptionUnchanged(
        before: (row: AllowOnceListRow, fingerprint: String, payloadDigest: String?),
        after: (row: AllowOnceListRow, fingerprint: String, payloadDigest: String?)
    ) -> Bool {
        before.fingerprint == after.fingerprint && before.row == after.row
            && before.payloadDigest == after.payloadDigest
    }

    static let notShowableMessage =
        "this command is too long to approve in a prompt (it cannot be shown in full, and nothing is approved from a shortened view); nothing was allowed. Run it yourself in a terminal instead"

    /// Why rvd's owner check refused a redeem. The pending code stays live.
    static func notApprovedMessage(_ refused: ConfirmOwnerActionReply) -> String {
        switch refused.outcome {
        case .declined:
            return "not approved (the Touch ID or password prompt was cancelled, failed or timed out); the code stays live"
        case .wrongPassword:
            return "wrong password; nothing was allowed and the code stays live"
        case .lockedOut:
            let wait = refused.retryAfterSeconds.map { " Try again in \($0 / 60 + 1) min." } ?? ""
            return "too many failed owner checks; owner approvals are locked.\(wait)"
        case .busy:
            return "another owner prompt is already open. If you did not start it, decline it: your coding agent may have opened it. Then run this again"
        case .unavailable:
            #if canImport(LocalAuthentication)
            return "rvd cannot show a Touch ID or password prompt here (no passcode set or no login session)"
            #else
            return "rvd could not check the password (unix_chkpwd missing or not answering)"
            #endif
        case .proofRequired, .approved:
            return "rvd did not approve this request; nothing was allowed"
        }
    }

    /// A missing pre-LA read skips LA entirely and reports the precise
    /// failure: unknown codes never prompt for authentication.
    ///
    /// Returns the flipped row plus whether the attested daemon epoch
    /// differs from the previously recorded one (m2): true means the
    /// daemon restarted since the last attest and earlier memory
    /// approvals died with the old table.
    static func redeem(
        code: String,
        tty: TTYCapability,
        robot: Bool,
        store: AllowOnceStore,
        now: Date,
        client: ServiceClient? = nil,
        readOwnerProof: @Sendable (String) async throws -> OwnerProof? = CLIOwnerAuth.ownerProofForAttestation(reason:)
    ) async throws -> (row: AllowOnceListRow, epochChanged: Bool) {
        guard allowsInteractiveAllowOnce(tty) else { throw AllowOnceError.ttyRequired }
        guard robot == false else { throw AllowOnceError.robotRefused }
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard AllowOnceUnlockCode(validating: normalized) != nil else {
            throw AllowOnceError.unknownCode
        }
        let peeked = await store.validatePending(code: code, now: now)
        guard let peeked else {
            // No live pending row: report the precise failure (unknown/
            // expired/spent) WITHOUT prompting LA — garbage codes must not
            // trigger Touch ID. This branch NEVER attests. A row appearing
            // after the first read is unreviewed: flipping it here would
            // print "granted" with no LA and no attestation, so recheck
            // and fail closed with redemptionChanged instead — the code
            // stays live-pending for a genuine retry.
            if await store.validatePending(code: code, now: now) != nil {
                throw AllowOnceError.redemptionChanged
            }
            let row = try await store.redeem(code: code, tty: tty, now: now, robot: robot)
            return (row, false)
        }
        guard await store.reserveLAPrompt(now: now) else {
            throw AllowOnceAuthError.throttled
        }
        try CLIOwnerAuth.beginRedeem(code: normalized)
        let service = client ?? OwnerConfirmation.defaultClient()
        guard let rechecked = await store.validatePending(code: code, now: now),
            Self.redemptionUnchanged(before: peeked, after: rechecked)
        else {
            throw AllowOnceError.redemptionChanged
        }
        var params = AttestTTYRedemptionParams(
            fingerprint: GrantFingerprint(rawValue: rechecked.fingerprint),
            cwd: rechecked.row.cwd,
            codeHash: CodeHash(rawValue: sha256Hex(normalized)),
            clientSemver: ProtocolVersion.serviceSemver,
            // M-07: the rechecked row's payload digest binds the planted
            // grant to the reviewed hidden payload (digest only — exact
            // segments never cross IPC). Nil rows plant unbound.
            payloadDigest: rechecked.payloadDigest.map(ContentPayloadDigest.init(rawValue:))
        )
        var attested = await service.attestTTYRedemption(params)
        // Linux: rvd answers the first ask with its own description of the
        // code it issued; the owner reads that (never the same-user pending
        // file) above the password prompt, and rvd verifies the password.
        if case .success(let first) = attested, first.ownerCheck?.outcome == .proofRequired,
            let described = first.promptText {
            params.ownerProof = try await readOwnerProof(described)
            attested = await service.attestTTYRedemption(params)
        }
        let reply: AttestTTYRedemptionReply
        switch attested {
        case .success(let response):
            reply = response
            if response.notShowable == true {
                throw AllowOnceAttestError.notShowable
            }
            if let refused = response.ownerCheck {
                // Nothing planted; the pending code stays live.
                throw AllowOnceAttestError.notApproved(refused)
            }
            if response.planted, response.presence != OwnerConfirmation.expectedPresence {
                throw AllowOnceAttestError.ownerCheckUnconfirmed
            }
            guard response.planted else {
                // m1: double-attest — this code already planted this epoch
                // (a concurrent genuine redeem, or a retry after the success
                // path's flip failed). The daemon holds the grant; reconcile
                // the projection instead of erroring, so the human's retry
                // reports the approval that exists. Spend-time expiry and
                // single-use are still enforced authoritatively in memory.
                let changed = await store.noteAttestedEpoch(response.epoch)
                let row = (try? await store.redeem(
                    code: code, tty: tty, now: now, robot: robot,
                    expectedFingerprint: rechecked.fingerprint,
                    expectedPayloadDigest: rechecked.payloadDigest
                )) ?? rechecked.row
                return (row, changed)
            }
        case .failure(let error):
            switch error {
            case .noTransport, .transport:
                throw AllowOnceAttestError.serviceUnavailable
            case .service(let refusal) where refusal == String(describing: IPCError.allowOnceNotFound):
                throw AllowOnceAttestError.notIssuedByService
            case .service:
                throw AllowOnceAttestError.serviceDenied
            }
        }
        let changed = await store.noteAttestedEpoch(reply.epoch)
        do {
            let row = try await store.redeem(
                code: code, tty: tty, now: now, robot: robot,
                expectedFingerprint: rechecked.fingerprint,
                expectedPayloadDigest: rechecked.payloadDigest
            )
            return (row, changed)
        } catch {
            // Attestation planted: the flip is display-only. A failure
            // here (file swap/lock race in the millisecond window) is a
            // projection gap, not a grant failure.
            return (rechecked.row, changed)
        }
    }

    static let mintServiceUnavailableMessage =
        "rvd is not reachable, and only rvd can pre-arm a code (one it did not issue can never be redeemed); nothing was minted. Start rvd and run this again"
    static let mintServiceDeniedMessage =
        "rvd refused to pre-arm a code (it could not identify the caller, or it is older than this rv: restart it); nothing was minted"

    /// Why rvd's owner check refused a pre-arm. Nothing was minted.
    static func mintNotApprovedMessage(_ refused: ConfirmOwnerActionReply) -> String {
        switch refused.outcome {
        case .declined:
            return "not approved (the Touch ID or password prompt was cancelled, failed or timed out); nothing was minted"
        case .wrongPassword:
            return "wrong password; nothing was minted"
        case .lockedOut, .busy, .unavailable, .proofRequired, .approved:
            return notApprovedMessage(refused)
        }
    }

    /// Printed with every pre-armed code: rvd holds it in memory only.
    static func mintedMessage(code: String) -> String {
        """
        allow-once code: \(code)
        rv allow-once \(code)
        This code lives only in rvd's memory: it is lost if rvd restarts, and expires in 24 hours.

        """
    }

    /// Pre-arms one unlock code for a command, through rvd. Minting alone
    /// grants nothing (the code must still be redeemed through rvd's
    /// prompt), but rvd mints only after the same owner check as redeem,
    /// naming the whole command and cwd, so an agent cannot farm codes to
    /// social-engineer a later redeem. rvd remembers the code with the
    /// exact command, which is what lets the later redeem name it; there is
    /// no local fallback, because a code rvd did not issue can never be
    /// redeemed.
    static func mint(
        command: ShellCommand,
        cwd: WorkingDirectory,
        tty: TTYCapability,
        robot: Bool,
        store: AllowOnceStore,
        now: Date,
        client: ServiceClient? = nil,
        peek: (@Sendable (ShellCommand, WorkingDirectory) async -> EvaluationResult)? = nil,
        readOwnerProof: @Sendable (String) async throws -> OwnerProof? = CLIOwnerAuth.ownerProofForAttestation(reason:)
    ) async throws -> AllowOnceUnlockCode {
        guard allowsInteractiveAllowOnce(tty) else { throw AllowOnceError.ttyRequired }
        guard robot == false else { throw AllowOnceError.robotRefused }
        let view = Normalize.matchingView(of: command)
        guard view.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw AllowOnceError.emptyCommand
        }
        // M-33 manual-mint gate: refuse to pre-arm a command no grant can
        // unlock. Pinned denies fail closed at spend time (consumingGrant
        // denies without burning), so minting one wastes the LA ceremony
        // plus attestation. Only a definite pinned deny refuses — allow,
        // unlockable deny, and indeterminate (evaluation uncertainty)
        // all proceed to the ceremony.
        //
        // Spend-free by construction: a fresh empty grant table on the
        // preview path never honors or consumes authority, records no
        // denial, and contacts no daemon. Never route this through the
        // service evaluate call: the service applies, which would spend
        // a live grant for the same command.
        let evaluated: EvaluationResult
        if let peek {
            evaluated = await peek(command, cwd)
        } else {
            evaluated = await GatedEvaluate().peek(
                command: command,
                cwd: cwd,
                home: nil,
                grants: EphemeralAllowOnceTable(),
                now: now,
                allowlist: { .empty }
            )
        }
        guard RulePinning.blocksAllowOverride(evaluated) == false else {
            throw AllowOnceError.notUnlockable
        }
        guard await store.reserveLAPrompt(now: now) else {
            throw AllowOnceAuthError.throttled
        }
        // rvd refuses too; checked here so the owner is not prompted at all.
        guard AllowOncePromptText.reason(command: command.rawValue, cwd: cwd, ruleID: nil) != nil else {
            throw AllowOnceAttestError.notShowable
        }
        try CLIOwnerAuth.beginMint()
        // Under a test context with no client, no transport: a test never
        // reaches a live rvd.
        let service = client
            ?? (CLIProcess.context == nil ? OwnerConfirmation.defaultClient() : ServiceClient(transport: nil))
        var params = MintAllowOnceParams(
            command: command.rawValue, cwd: cwd, clientSemver: ProtocolVersion.serviceSemver)
        var minted = await service.mintAllowOnce(params)
        // Linux: rvd answers the first ask with its own description; the
        // owner reads it above the password prompt and rvd checks the password.
        if case .success(let first) = minted, first.ownerCheck?.outcome == .proofRequired,
            let described = first.promptText {
            params.ownerProof = try await readOwnerProof(described)
            minted = await service.mintAllowOnce(params)
        }
        switch minted {
        case .success(let reply):
            if reply.notShowable == true { throw AllowOnceAttestError.notShowable }
            if reply.alreadyPending == true { throw AllowOnceError.alreadyPending }
            if let refused = reply.ownerCheck { throw AllowOnceAttestError.notApproved(refused) }
            guard let code = reply.code.flatMap(AllowOnceUnlockCode.init(validating:)) else {
                throw AllowOnceAttestError.serviceDenied
            }
            return code
        case .failure(.noTransport), .failure(.transport):
            throw AllowOnceAttestError.serviceUnavailable
        case .failure(.service):
            throw AllowOnceAttestError.serviceDenied
        }
    }
}

struct AllowOnceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "allow-once",
        abstract: "Redeem the six-character code from a hook deny.",
        discussion: """
            Redeem the six-character code printed on a hook deny. mint is optional pre-arm.
            """,
        subcommands: [AllowOnceRedeem.self, AllowOnceMint.self, AllowOnceList.self, AllowOnceClear.self],
        defaultSubcommand: AllowOnceRedeem.self
    )
}

/// Default `allow-once` subcommand: redeem holds the code positional here
/// (not on the parent) so `list`/`clear`/`mint` route to their subcommands
/// instead of parsing as a code (B-F6). Bare `rv allow-once <code>` keeps
/// working through the default.
struct AllowOnceRedeem: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "redeem",
        abstract: "Redeem the six-character code from a hook deny."
    )

    @Argument(help: "Six-character allow-once code.")
    var code: String?

    @OptionGroup
    var format: FormatFlags

    func run() async throws {
        guard let code, code.isEmpty == false else {
            try CommandContext.fail(
                """
                usage: rv allow-once mint -- <command>
                       rv allow-once <code>
                       rv allow-once list
                       rv allow-once clear

                """,
                exitCode: 2
            )
        }
        let ctx = CommandContext.current(command: "allow-once", format: format)
        do {
            let redeemed = try await AllowOnceCLI.redeem(
                code: code,
                tty: ctx.tty,
                robot: ctx.explicitRobot,
                store: AllowOnceCLI.store(home: try ctx.requireHome()),
                now: Date()
            )
            if redeemed.epochChanged {
                ctx.writeStderr(
                    "rv allow-once: note: RV service restarted; approvals from before the restart were invalidated\n"
                )
            }
            ctx.writeStdout(
                "granted \(DisplayedText.field(redeemed.row.commandRedacted)) (cwd \(DisplayedText.field(redeemed.row.cwd.rawValue)))\n"
            )
        } catch AllowOnceError.unknownCode, AllowOnceError.expired, AllowOnceError.alreadySpent {
            try ctx.fail("rv allow-once: code not redeemable\n", exitCode: 2)
        } catch AllowOnceAttestError.serviceUnavailable {
            try ctx.fail(
                "rv allow-once: RV service unavailable; approval not recorded (code stays live, retry later)\n",
                exitCode: 2
            )
        } catch AllowOnceAttestError.serviceDenied {
            try ctx.fail(
                "rv allow-once: rvd refused this request (it could not identify the caller); nothing was allowed\n",
                exitCode: 2
            )
        } catch AllowOnceAttestError.notIssuedByService {
            try ctx.fail(
                "rv allow-once: rvd did not issue this code (rvd restarted since it issued it, or the pending file was edited); rerun the command for a fresh code\n",
                exitCode: 2
            )
        } catch AllowOnceAttestError.notShowable {
            try ctx.fail("rv allow-once: \(AllowOnceCLI.notShowableMessage)\n", exitCode: 2)
        } catch AllowOnceAttestError.ownerCheckUnconfirmed {
            try ctx.fail(
                "rv allow-once: rvd did not say it checked the owner (an older rvd still running after an upgrade?); nothing was allowed. Run rv service restart and try again\n",
                exitCode: 2
            )
        } catch AllowOnceAttestError.notApproved(let refused) {
            try ctx.fail("rv allow-once: \(AllowOnceCLI.notApprovedMessage(refused))\n", exitCode: 2)
        } catch {
            try ctx.failOwnerGate(error, command: "allow-once", subject: .grant)
        }
    }
}

struct AllowOnceMint: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mint",
        abstract: "Mint a single-use allow-once code for a command."
    )

    @OptionGroup
    var format: FormatFlags

    @Argument(parsing: .captureForPassthrough, help: "Command to unlock once.")
    var commandParts: [String] = []

    func run() async throws {
        let raw = commandParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.isEmpty == false else {
            try CommandContext.fail("rv allow-once mint: missing command\n", exitCode: 2)
        }
        let ctx = CommandContext.current(command: "allow-once", format: format)
        do {
            guard let cwd = WorkingDirectory(validating: FileManager.default.currentDirectoryPath) else {
                try ctx.fail("rv allow-once mint: missing working directory\n", exitCode: 2)
            }
            let code = try await AllowOnceCLI.mint(
                command: ShellCommand(rawValue: raw),
                cwd: cwd,
                tty: ctx.tty,
                robot: ctx.explicitRobot,
                store: AllowOnceCLI.store(home: try ctx.requireHome()),
                now: Date()
            )
            ctx.writeStdout(AllowOnceCLI.mintedMessage(code: code.rawValue))
        } catch AllowOnceError.emptyCommand {
            try ctx.fail("rv allow-once mint: missing command\n", exitCode: 2)
        } catch AllowOnceAttestError.notShowable {
            try ctx.fail("rv allow-once mint: \(AllowOnceCLI.notShowableMessage)\n", exitCode: 2)
        } catch AllowOnceAttestError.serviceUnavailable {
            try ctx.fail("rv allow-once mint: \(AllowOnceCLI.mintServiceUnavailableMessage)\n", exitCode: 2)
        } catch AllowOnceAttestError.serviceDenied, AllowOnceAttestError.notIssuedByService {
            try ctx.fail("rv allow-once mint: \(AllowOnceCLI.mintServiceDeniedMessage)\n", exitCode: 2)
        } catch AllowOnceAttestError.notApproved(let refused) {
            try ctx.fail("rv allow-once mint: \(AllowOnceCLI.mintNotApprovedMessage(refused))\n", exitCode: 2)
        } catch AllowOnceError.notUnlockable {
            try ctx.fail(
                "rv allow-once mint: no one-shot unlock is possible for this command\n",
                exitCode: 2
            )
        } catch AllowOnceError.alreadyPending {
            try ctx.fail(
                "rv allow-once mint: a pending unlock already exists for this command\n",
                exitCode: 2
            )
        } catch {
            try ctx.failOwnerGate(error, command: "allow-once mint", subject: .grant)
        }
    }
}

struct AllowOnceList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List redacted allow-once rows."
    )

    @OptionGroup
    var format: FormatFlags

    func run() async throws {
        let ctx = CommandContext.current(command: "allow-once", format: format)
        let rows = await AllowOnceCLI.store(home: try ctx.requireHome()).list(now: Date())
        if ctx.explicitRobot {
            let document = RobotDocument.allowOnceList(allowOnceRobotRows(from: rows))
            ctx.writeStdout(try document.render() + "\n")
            return
        }
        if rows.isEmpty {
            ctx.writeStdout("no allow-once rows\n")
            return
        }
        for row in rows {
            let invoked: String
            if let tag = row.invocationDisplay {
                invoked = "\(DisplayedText.field(tag)) \(DisplayedText.field(row.commandRedacted))"
            } else {
                invoked = DisplayedText.field(row.commandRedacted)
            }
            ctx.writeStdout("\(row.kind.rawValue) \(invoked) cwd=\(DisplayedText.field(row.cwd.rawValue))\n")
        }
    }
}

struct AllowOnceClear: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Clear pending and granted allow-once rows."
    )

    @OptionGroup
    var format: FormatFlags

    func run() async throws {
        let ctx = CommandContext.current(command: "allow-once", format: format)
        do {
            // Clearing destroys the operator's own rows and grants nothing,
            // so the TTY gate suffices: no LA tripwire.
            try await AllowOnceCLI.store(home: try ctx.requireHome())
                .clear(tty: ctx.tty, now: Date())
            ctx.writeStdout("cleared allow-once rows\n")
        } catch {
            try ctx.failOwnerGate(error, command: "allow-once clear", subject: .grant)
        }
    }
}
