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
    /// Daemon refused (no `.cli` role: unenrolled service/binary).
    /// Approve in RVOperatorUI or enroll via `rv setup`.
    case serviceDenied
}

enum AllowOnceCLI {
    static func interactiveTTY(
        json: Bool,
        robot: Bool,
        plain: Bool,
        noColor: Bool
    ) -> (tty: TTYCapability, robot: Bool) {
        let probe = ThemeProbeFactory.live(
            jsonFlag: json,
            robotFlag: robot,
            plainFlag: plain,
            noColorFlag: noColor
        )
        let tty = TTYCapability(
            stdinIsTTY: probe.terminal.stdinIsTTY,
            stdoutIsTTY: probe.terminal.stdoutIsTTY,
            ci: probe.forbid.ci
        )
        return (tty, json || robot)
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
            FileHandle.standardError.write(Data("rv allow-once: HOME is not set\n".utf8))
            throw ExitCode(1)
        }
        return home
    }

    static func store(home: HomeDirectory) -> AllowOnceStore {
        AllowOnceStore.makeLive(home: home)
    }

    /// Redeems one unlock code into one exact-command grant. Ceremony order
    /// is load-bearing (Step 8B.1 trust anchor — the pinned genuine CLI
    /// enforces it; the daemon trusts nothing else about this process):
    ///
    /// 1. Gates cheapest-first (TTY, robot, code shape).
    /// 2. Atomically read display row + fingerprint (pre-LA review).
    /// 3. LocalAuthentication naming the reviewed grant (B-F6).
    /// 4. Re-read + compare fingerprint AND full row (TOCTOU bind: a
    ///    swapped file aborts with redemptionChanged instead of attesting
    ///    a row the human never reviewed; the fingerprint covers the
    ///    action, the row covers cwd/expiry/display).
    /// 5. Attest to the daemon (plants the memory grant; daemon re-checks
    ///    role + fields + per-epoch code single-use).
    /// 6. Flip the file row as a display projection (best-effort: a flip
    ///    failure after a planted attestation is a display gap, still
    ///    granted; an attest failure leaves pending intact for retry).
    ///
    /// Post-LA equality gate: the re-read row must match the reviewed
    /// row exactly. Fingerprint-only comparison would let a same-user
    /// file swap redirect the attest (e.g. cwd) after the human
    /// approved; whole-row equality fails closed on any drift.
    static func redemptionUnchanged(
        before: (row: AllowOnceListRow, fingerprint: String),
        after: (row: AllowOnceListRow, fingerprint: String)
    ) -> Bool {
        before.fingerprint == after.fingerprint && before.row == after.row
    }

    /// A missing pre-LA read skips LA entirely and reports the precise
    /// failure: unknown codes never prompt for authentication.
    static func redeem(
        code: String,
        tty: TTYCapability,
        robot: Bool,
        store: AllowOnceStore,
        now: Date,
        client: ServiceClient? = nil
    ) async throws -> AllowOnceListRow {
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
            // trigger Touch ID. This branch NEVER attests: a row appearing
            // after this read would be unreviewed, so at most a projection
            // flips (fail-closed).
            return try await store.redeem(code: code, tty: tty, now: now, robot: robot)
        }
        let reason = "Allow once: \(peeked.row.commandRedacted) in \(peeked.row.cwd.rawValue)."
        try await CLIOwnerAuth.requireAuthenticated(reason: reason)
        let service = client ?? ServiceClient()
        guard let rechecked = await store.validatePending(code: code, now: now),
            Self.redemptionUnchanged(before: peeked, after: rechecked)
        else {
            throw AllowOnceError.redemptionChanged
        }
        let attested = await service.attestTTYRedemption(AttestTTYRedemptionParams(
            fingerprint: rechecked.fingerprint,
            cwd: rechecked.row.cwd,
            codeHash: sha256Hex(normalized),
            clientSemver: ProtocolVersion.serviceSemver
        ))
        switch attested {
        case .success(let reply):
            guard reply.planted else { throw AllowOnceError.alreadySpent }
        case .failure(let error):
            switch error {
            case .noTransport, .transport:
                throw AllowOnceAttestError.serviceUnavailable
            case .service:
                throw AllowOnceAttestError.serviceDenied
            }
        }
        do {
            return try await store.redeem(
                code: code, tty: tty, now: now, robot: robot,
                expectedFingerprint: rechecked.fingerprint
            )
        } catch {
            // Attestation planted: the flip is display-only. A failure
            // here (file swap/lock race in the millisecond window) is a
            // projection gap, not a grant failure.
            return rechecked.row
        }
    }

    /// Pre-arms one unlock code for a command. Minting alone grants
    /// nothing — the printed code must still clear the redeem tripwire —
    /// but minting is LA-gated anyway so an agent cannot farm codes from a
    /// pty to social-engineer a later redeem.
    static func mint(
        command: ShellCommand,
        cwd: WorkingDirectory,
        tty: TTYCapability,
        robot: Bool,
        store: AllowOnceStore,
        now: Date
    ) async throws -> AllowOnceUnlockCode {
        guard allowsInteractiveAllowOnce(tty) else { throw AllowOnceError.ttyRequired }
        guard robot == false else { throw AllowOnceError.robotRefused }
        let view = Normalize.matchingView(of: command)
        guard view.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw AllowOnceError.emptyCommand
        }
        try await CLIOwnerAuth.requireAuthenticated()
        return try await store.mint(
            matchingView: view,
            cwd: cwd,
            ruleID: nil,
            tty: tty,
            now: now,
            robot: robot
        )
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
            FileHandle.standardError.write(
                Data(
                    """
                    usage: rv allow-once mint -- <command>
                           rv allow-once <code>
                           rv allow-once list
                           rv allow-once clear

                    """.utf8
                )
            )
            throw ExitCode(2)
        }
        let live = AllowOnceCLI.interactiveTTY(
            json: format.json,
            robot: format.robot,
            plain: format.plain,
            noColor: format.noColor
        )
        do {
            let row = try await AllowOnceCLI.redeem(
                code: code,
                tty: live.tty,
                robot: live.robot,
                store: AllowOnceCLI.store(home: try AllowOnceCLI.requireHome()),
                now: Date()
            )
            FileHandle.standardOutput.write(
                Data("granted \(row.commandRedacted) (cwd \(row.cwd.rawValue))\n".utf8)
            )
        } catch AllowOnceError.ttyRequired {
            FileHandle.standardError.write(
                Data("rv allow-once: requires an interactive TTY (stdin and stdout)\n".utf8)
            )
            throw ExitCode(2)
        } catch AllowOnceError.robotRefused {
            FileHandle.standardError.write(
                Data("rv allow-once: --json/--robot refused for redeem\n".utf8)
            )
            throw ExitCode(2)
        } catch AllowOnceError.unknownCode, AllowOnceError.expired, AllowOnceError.alreadySpent {
            FileHandle.standardError.write(Data("rv allow-once: code not redeemable\n".utf8))
            throw ExitCode(2)
        } catch AllowOnceError.redemptionChanged {
            FileHandle.standardError.write(
                Data("rv allow-once: grant changed during review; retry with a fresh code\n".utf8)
            )
            throw ExitCode(2)
        } catch AllowOnceAttestError.serviceUnavailable {
            FileHandle.standardError.write(
                Data("rv allow-once: RV service unavailable; approval not recorded (code stays live, retry later)\n".utf8)
            )
            throw ExitCode(2)
        } catch AllowOnceAttestError.serviceDenied {
            FileHandle.standardError.write(
                Data("rv allow-once: service refused approval; enroll via `rv setup` or approve in RVOperatorUI\n".utf8)
            )
            throw ExitCode(2)
        } catch AllowOnceError.lockFailed, AllowOnceError.encodeFailed {
            FileHandle.standardError.write(Data("rv allow-once: store unavailable\n".utf8))
            throw ExitCode(2)
        } catch AllowOnceAuthError.required {
            FileHandle.standardError.write(
                Data("rv allow-once: device-owner authentication required\n".utf8)
            )
            throw ExitCode(2)
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
            FileHandle.standardError.write(Data("rv allow-once mint: missing command\n".utf8))
            throw ExitCode(2)
        }
        let live = AllowOnceCLI.interactiveTTY(
            json: format.json,
            robot: format.robot,
            plain: format.plain,
            noColor: format.noColor
        )
        do {
            guard let cwd = WorkingDirectory(validating: FileManager.default.currentDirectoryPath) else {
                FileHandle.standardError.write(Data("rv allow-once mint: missing working directory\n".utf8))
                throw ExitCode(2)
            }
            let code = try await AllowOnceCLI.mint(
                command: ShellCommand(rawValue: raw),
                cwd: cwd,
                tty: live.tty,
                robot: live.robot,
                store: AllowOnceCLI.store(home: try AllowOnceCLI.requireHome()),
                now: Date()
            )
            FileHandle.standardOutput.write(
                Data("allow-once code: \(code.rawValue)\nrv allow-once \(code.rawValue)\n".utf8)
            )
        } catch AllowOnceError.ttyRequired {
            FileHandle.standardError.write(
                Data("rv allow-once: requires an interactive TTY (stdin and stdout)\n".utf8)
            )
            throw ExitCode(2)
        } catch AllowOnceError.robotRefused {
            FileHandle.standardError.write(
                Data("rv allow-once mint: --json/--robot refused\n".utf8)
            )
            throw ExitCode(2)
        } catch AllowOnceError.emptyCommand {
            FileHandle.standardError.write(Data("rv allow-once mint: missing command\n".utf8))
            throw ExitCode(2)
        } catch AllowOnceError.alreadyPending {
            FileHandle.standardError.write(
                Data("rv allow-once mint: a pending unlock already exists for this command\n".utf8)
            )
            throw ExitCode(2)
        } catch AllowOnceError.lockFailed, AllowOnceError.encodeFailed, AllowOnceError.collision {
            FileHandle.standardError.write(Data("rv allow-once mint: store unavailable\n".utf8))
            throw ExitCode(2)
        } catch AllowOnceAuthError.required {
            FileHandle.standardError.write(
                Data("rv allow-once mint: device-owner authentication required\n".utf8)
            )
            throw ExitCode(2)
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
        let rows = await AllowOnceCLI.store(home: try AllowOnceCLI.requireHome()).list(now: Date())
        if format.json || format.robot {
            let document = RobotDocument.allowOnceList(allowOnceRobotRows(from: rows))
            FileHandle.standardOutput.write(Data((try document.render() + "\n").utf8))
            return
        }
        if rows.isEmpty {
            FileHandle.standardOutput.write(Data("no allow-once rows\n".utf8))
            return
        }
        for row in rows {
            FileHandle.standardOutput.write(
                Data("\(row.kind.rawValue) \(row.commandRedacted) cwd=\(row.cwd.rawValue)\n".utf8)
            )
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
        let live = AllowOnceCLI.interactiveTTY(
            json: format.json,
            robot: format.robot,
            plain: format.plain,
            noColor: format.noColor
        )
        do {
            // Clearing destroys the operator's own rows and grants nothing,
            // so the TTY gate suffices: no LA tripwire.
            try await AllowOnceCLI.store(home: try AllowOnceCLI.requireHome())
                .clear(tty: live.tty, now: Date())
            FileHandle.standardOutput.write(Data("cleared allow-once rows\n".utf8))
        } catch AllowOnceError.ttyRequired {
            FileHandle.standardError.write(
                Data("rv allow-once clear: requires an interactive TTY\n".utf8)
            )
            throw ExitCode(2)
        } catch AllowOnceError.lockFailed, AllowOnceError.encodeFailed {
            FileHandle.standardError.write(Data("rv allow-once clear: store unavailable\n".utf8))
            throw ExitCode(2)
        }
    }
}
