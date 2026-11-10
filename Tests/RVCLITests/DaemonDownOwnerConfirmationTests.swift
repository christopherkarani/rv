import ArgumentParser
import Foundation
import Testing
import RVDomain
import RVIPC
import RVPolicy
@testable import RVCLI

/// Records which seams the decision touched. No seam here reaches a live
/// prompt, terminal, or rvd.
private final class SeamRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _probes = 0
    private var _localChecks = 0
    private var _notices: [String] = []

    /// nil: rvd answered; otherwise how the probe missed.
    let probe: HookDaemonFailure?
    let stdinTTY: Bool
    let stdoutTTY: Bool
    let local: DaemonDownOwnerConfirmation.LocalCheck

    init(
        probe: HookDaemonFailure?,
        stdinTTY: Bool = true,
        stdoutTTY: Bool = true,
        local: DaemonDownOwnerConfirmation.LocalCheck = .unavailable
    ) {
        self.probe = probe
        self.stdinTTY = stdinTTY
        self.stdoutTTY = stdoutTTY
        self.local = local
    }

    var probes: Int { lock.withLock { _probes } }
    var localChecks: Int { lock.withLock { _localChecks } }
    var notices: [String] { lock.withLock { _notices } }

    var seams: DaemonDownOwnerConfirmation.Seams {
        DaemonDownOwnerConfirmation.Seams(
            probeRVD: { [self] in
                lock.withLock { _probes += 1 }
                return probe
            },
            stdinIsTTY: { [self] in stdinTTY },
            stdoutIsTTY: { [self] in stdoutTTY },
            localOwnerCheck: { [self] _ in
                lock.withLock { _localChecks += 1 }
                return local
            },
            notice: { [self] line in lock.withLock { _notices.append(line) } }
        )
    }
}

private typealias Confirmation = DaemonDownOwnerConfirmation

private func decide(
    _ recorder: SeamRecorder, action: Confirmation.Action = .uninstall
) async -> Confirmation.Decision {
    await Confirmation.decide(action, reason: "Authenticate to uninstall rv.", seams: recorder.seams)
}

struct DaemonDownOwnerConfirmationTests {
    // MARK: decision

    @Test func rvdAnswers_usesDaemonPathAndNeverConsultsFallback() async {
        let recorder = SeamRecorder(probe: nil, local: .verified)
        #expect(await decide(recorder) == .useDaemonPath)
        #expect(recorder.probes == 1)
        #expect(recorder.localChecks == 0)
        #expect(recorder.notices.isEmpty)
    }

    @Test(
        "a busy, slow, dropped, untrusted or skewed rvd is not down: refuse, never confirm locally",
        arguments: [HookDaemonFailure.timeout, .connection, .untrusted, .protocol]
    )
    func rvdNotPositivelyDown_refusesWithoutLocalCheck(failure: HookDaemonFailure) async {
        let recorder = SeamRecorder(probe: failure, local: .verified)
        #expect(await decide(recorder) == .refused(Confirmation.notConfirmedDownMessage(.uninstall)))
        #expect(recorder.localChecks == 0)
        #expect(recorder.notices.contains(Confirmation.daemonDownNotice) == false)
    }

    @Test func rvdUnreachable_stdinNotATTY_refusedWithReason() async {
        let recorder = SeamRecorder(probe: .unreachable, stdinTTY: false, local: .verified)
        #expect(await decide(recorder) == .refused(Confirmation.notATerminalMessage(.uninstall)))
        #expect(recorder.notices == [Confirmation.daemonDownNotice])
        #expect(recorder.localChecks == 0)
    }

    @Test func rvdUnreachable_stdoutNotATTY_refusedWithReason() async {
        let recorder = SeamRecorder(probe: .unreachable, stdoutTTY: false, local: .verified)
        #expect(await decide(recorder) == .refused(Confirmation.notATerminalMessage(.uninstall)))
        #expect(recorder.localChecks == 0)
    }

    @Test func notATerminalMessage_namesTheActionAndTheRepair() {
        let message = Confirmation.notATerminalMessage(.uninstall)
        #expect(message.contains("uninstall rv"))
        #expect(message.contains("terminal"))
        #expect(message.contains("rv setup"))
    }

    @Test func rvdUnreachable_tty_localPasswordVerified_proceeds() async {
        let recorder = SeamRecorder(probe: .unreachable, local: .verified)
        #expect(await decide(recorder) == .proceed)
        #expect(recorder.localChecks == 1)
        #expect(recorder.notices.first == Confirmation.daemonDownNotice)
    }

    @Test func rvdUnreachable_tty_localPasswordRejected_refused() async {
        let recorder = SeamRecorder(probe: .unreachable, local: .rejected)
        #expect(await decide(recorder) == .refused(Confirmation.rejectedMessage(.uninstall)))
    }

    /// `script`/`expect`/`unbuffer` give an agent both TTYs and a pty it
    /// can write to. With no local owner check, nothing entered there may
    /// stand in for the owner: the only answer is a refusal.
    @Test func rvdUnreachable_ptyWithNoLocalVerifier_typedPhraseCannotAuthorize() async {
        for action in [Confirmation.Action.uninstall, .hostMode(.off, host: .claude)] {
            let recorder = SeamRecorder(probe: .unreachable, local: .unavailable)
            #expect(await decide(recorder, action: action) == .refused(Confirmation.noLocalVerifierMessage(action)))
            #expect(recorder.localChecks == 1)
        }
    }

    @Test func noLocalVerifierMessage_saysHowToProceedWithoutAnAgent() {
        let message = Confirmation.noLocalVerifierMessage(.uninstall)
        #expect(message.contains("uninstall rv was not done"))
        #expect(message.contains("rv setup"))
        #expect(message.contains("~/.local/bin"))
    }

    @Test func hostModeActions_nameHostAndMode() {
        #expect(Confirmation.Action.hostMode(.off, host: .claude).summary == "turn off rv for claude")
        #expect(Confirmation.Action.hostMode(.observe, host: .codex).summary == "set rv to observe for codex")
    }

    @Test func daemonDownNotice_saysWhy() {
        #expect(Confirmation.daemonDownNotice
            == "rv: rvd is not running, so your password cannot be checked by rvd. Confirming locally instead.")
    }

    // MARK: CLIOwnerAuth entry point

    private func withContext(
        _ recorder: SeamRecorder?, ownerAuthOutcome: UIAuthenticationOutcome? = nil,
        _ body: () async throws -> Void
    ) async rethrows {
        var context = CLIProcess.Context(ownerAuthOutcome: ownerAuthOutcome)
        context.daemonDownConfirmation = recorder?.seams
        try await CLIProcess.$context.withValue(context, operation: body)
    }

    private func authenticate() async throws {
        try await CLIOwnerAuth.requireAuthenticatedOrLocalWhenDaemonDown(
            reason: "Authenticate to uninstall rv.", action: .uninstall)
    }

    @Test func entry_rvdReachable_runsExistingOwnerAuth() async throws {
        let approved = SeamRecorder(probe: nil, local: .verified)
        try await withContext(approved, ownerAuthOutcome: .authenticated) { try await authenticate() }
        #expect(approved.localChecks == 0)

        let refused = SeamRecorder(probe: nil, local: .verified)
        await #expect(throws: AllowOnceAuthError.required) {
            try await withContext(refused) { try await authenticate() }
        }
        #expect(refused.localChecks == 0)
    }

    @Test func entry_seamedContextWithoutFallbackSeam_failsClosed() async {
        await #expect(throws: AllowOnceAuthError.required) {
            try await withContext(nil) { try await authenticate() }
        }
    }

    @Test func entry_rvdDown_localConfirmation_proceeds() async throws {
        let recorder = SeamRecorder(probe: .unreachable, local: .verified)
        try await withContext(recorder) { try await authenticate() }
    }

    @Test func entry_rvdDown_refusal_printsReasonAndThrows() async {
        let recorder = SeamRecorder(probe: .unreachable, stdinTTY: false)
        await #expect(throws: AllowOnceAuthError.required) {
            try await withContext(recorder) { try await authenticate() }
        }
        #expect(recorder.notices == [
            Confirmation.daemonDownNotice, Confirmation.notATerminalMessage(.uninstall),
        ])
    }

    // MARK: command wiring

    @Test func uninstall_rvdDownNotATTY_refusedBeforeTouchingHome() async throws {
        let recorder = SeamRecorder(probe: .unreachable, stdinTTY: false)
        await #expect(throws: ExitCode(EX_NOPERM)) {
            try await withContext(recorder) { try await Uninstall.parse(["--robot"]).run() }
        }
        #expect(recorder.notices.contains(Confirmation.notATerminalMessage(.uninstall)))
    }
}
