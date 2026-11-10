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
    private var _prompts: [String] = []
    private var _notices: [String] = []

    let reachable: Bool
    let stdinTTY: Bool
    let stdoutTTY: Bool
    let local: DaemonDownOwnerConfirmation.LocalCheck
    let typed: String?

    init(
        reachable: Bool,
        stdinTTY: Bool = true,
        stdoutTTY: Bool = true,
        local: DaemonDownOwnerConfirmation.LocalCheck = .unavailable,
        typed: String? = nil
    ) {
        self.reachable = reachable
        self.stdinTTY = stdinTTY
        self.stdoutTTY = stdoutTTY
        self.local = local
        self.typed = typed
    }

    var probes: Int { lock.withLock { _probes } }
    var localChecks: Int { lock.withLock { _localChecks } }
    var prompts: [String] { lock.withLock { _prompts } }
    var notices: [String] { lock.withLock { _notices } }

    var seams: DaemonDownOwnerConfirmation.Seams {
        DaemonDownOwnerConfirmation.Seams(
            rvdReachable: { [self] in
                lock.withLock { _probes += 1 }
                return reachable
            },
            stdinIsTTY: { [self] in stdinTTY },
            stdoutIsTTY: { [self] in stdoutTTY },
            localOwnerCheck: { [self] _ in
                lock.withLock { _localChecks += 1 }
                return local
            },
            readTTYLine: { [self] prompt in
                lock.withLock { _prompts.append(prompt) }
                return typed
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

    @Test func rvdReachable_usesDaemonPathAndNeverConsultsFallback() async {
        let recorder = SeamRecorder(reachable: true, local: .verified, typed: "uninstall rv")
        #expect(await decide(recorder) == .useDaemonPath)
        #expect(recorder.probes == 1)
        #expect(recorder.localChecks == 0)
        #expect(recorder.prompts.isEmpty)
        #expect(recorder.notices.isEmpty)
    }

    @Test func rvdDown_stdinNotATTY_refusedWithReason() async {
        let recorder = SeamRecorder(reachable: false, stdinTTY: false, local: .verified, typed: "uninstall rv")
        #expect(await decide(recorder) == .refused(Confirmation.notATerminalMessage(.uninstall)))
        #expect(recorder.notices == [Confirmation.daemonDownNotice])
        #expect(recorder.localChecks == 0)
        #expect(recorder.prompts.isEmpty)
    }

    @Test func rvdDown_stdoutNotATTY_refusedWithReason() async {
        let recorder = SeamRecorder(reachable: false, stdoutTTY: false, local: .verified, typed: "uninstall rv")
        #expect(await decide(recorder) == .refused(Confirmation.notATerminalMessage(.uninstall)))
        #expect(recorder.localChecks == 0)
        #expect(recorder.prompts.isEmpty)
    }

    @Test func notATerminalMessage_namesTheActionAndTheRepair() {
        let message = Confirmation.notATerminalMessage(.uninstall)
        #expect(message.contains("uninstall rv"))
        #expect(message.contains("terminal"))
        #expect(message.contains("rv setup"))
    }

    @Test func rvdDown_tty_localPasswordVerified_proceedsWithoutPhrase() async {
        let recorder = SeamRecorder(reachable: false, local: .verified)
        #expect(await decide(recorder) == .proceed)
        #expect(recorder.localChecks == 1)
        #expect(recorder.prompts.isEmpty)
        #expect(recorder.notices.first == Confirmation.daemonDownNotice)
    }

    @Test func rvdDown_tty_localPasswordRejected_refusedWithoutPhrase() async {
        let recorder = SeamRecorder(reachable: false, local: .rejected, typed: "uninstall rv")
        #expect(await decide(recorder) == .refused(Confirmation.rejectedMessage(.uninstall)))
        #expect(recorder.prompts.isEmpty)
    }

    @Test func rvdDown_tty_noLocalVerifier_rightPhraseProceeds() async {
        let recorder = SeamRecorder(reachable: false, local: .unavailable, typed: "uninstall rv")
        #expect(await decide(recorder) == .proceed)
        #expect(recorder.prompts == [Confirmation.phrasePrompt(.uninstall)])
        #expect(recorder.notices.contains(Confirmation.noLocalVerifierNotice))
    }

    @Test func rvdDown_tty_noLocalVerifier_phraseToleratesSurroundingWhitespace() async {
        let recorder = SeamRecorder(reachable: false, local: .unavailable, typed: "  uninstall rv \r")
        #expect(await decide(recorder) == .proceed)
    }

    @Test func rvdDown_tty_noLocalVerifier_wrongPhraseRefused() async {
        for typed in ["", "y", "yes", "Uninstall rv", "uninstall", "uninstall rv now"] {
            let recorder = SeamRecorder(reachable: false, local: .unavailable, typed: typed)
            #expect(await decide(recorder) == .refused(Confirmation.phraseMismatchMessage(.uninstall)))
        }
    }

    @Test func rvdDown_tty_noLocalVerifier_noTerminalToReadRefused() async {
        let recorder = SeamRecorder(reachable: false, local: .unavailable, typed: nil)
        #expect(await decide(recorder) == .refused(Confirmation.phraseMismatchMessage(.uninstall)))
    }

    @Test func hostModeActions_phraseNamesHostAndMode() async {
        #expect(Confirmation.Action.hostMode(.off, host: .claude).phrase == "turn off rv for claude")
        #expect(Confirmation.Action.hostMode(.observe, host: .codex).phrase == "set rv to observe for codex")
        let action = Confirmation.Action.hostMode(.off, host: .claude)
        let wrong = SeamRecorder(reachable: false, local: .unavailable, typed: "uninstall rv")
        #expect(await decide(wrong, action: action) == .refused(Confirmation.phraseMismatchMessage(action)))
        let right = SeamRecorder(reachable: false, local: .unavailable, typed: "turn off rv for claude")
        #expect(await decide(right, action: action) == .proceed)
    }

    @Test func daemonDownNotice_saysWhy() {
        #expect(Confirmation.daemonDownNotice
            == "rv: rvd is not answering, so your password cannot be checked by rvd. Confirming locally instead.")
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
        let approved = SeamRecorder(reachable: true, local: .verified)
        try await withContext(approved, ownerAuthOutcome: .authenticated) { try await authenticate() }
        #expect(approved.localChecks == 0)

        let refused = SeamRecorder(reachable: true, local: .verified, typed: "uninstall rv")
        await #expect(throws: AllowOnceAuthError.required) {
            try await withContext(refused) { try await authenticate() }
        }
        #expect(refused.localChecks == 0)
        #expect(refused.prompts.isEmpty)
    }

    @Test func entry_seamedContextWithoutFallbackSeam_failsClosed() async {
        await #expect(throws: AllowOnceAuthError.required) {
            try await withContext(nil) { try await authenticate() }
        }
    }

    @Test func entry_rvdDown_localConfirmation_proceeds() async throws {
        let recorder = SeamRecorder(reachable: false, local: .unavailable, typed: "uninstall rv")
        try await withContext(recorder) { try await authenticate() }
    }

    @Test func entry_rvdDown_refusal_printsReasonAndThrows() async {
        let recorder = SeamRecorder(reachable: false, stdinTTY: false)
        await #expect(throws: AllowOnceAuthError.required) {
            try await withContext(recorder) { try await authenticate() }
        }
        #expect(recorder.notices == [
            Confirmation.daemonDownNotice, Confirmation.notATerminalMessage(.uninstall),
        ])
    }

    // MARK: command wiring

    @Test func uninstall_rvdDownNotATTY_refusedBeforeTouchingHome() async throws {
        let recorder = SeamRecorder(reachable: false, stdinTTY: false)
        await #expect(throws: ExitCode(EX_NOPERM)) {
            try await withContext(recorder) { try await Uninstall.parse(["--robot"]).run() }
        }
        #expect(recorder.notices.contains(Confirmation.notATerminalMessage(.uninstall)))
    }
}
