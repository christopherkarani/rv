#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVHistory
import RVIPC
import RVPolicy

/// Checks the owner's login password. Only rvd calls this, so a CLI cannot
/// claim success: it can only hand over a password.
protocol OwnerPasswordChecking: Sendable {
    /// nil when this system cannot check passwords at all, or no answer
    /// came (timed out or cancelled).
    func check(_ password: String) async -> Bool?
}

/// Verifies the invoking user's own password with pam_unix's setgid helper
/// `unix_chkpwd`. The helper refuses to check any other account for a
/// non-root caller, reads the password from a pipe (never argv), and exits 0
/// only when it matches. Accounts without a usable password fail.
/// The CLI also runs it directly for the daemon-down `rv uninstall` /
/// `rv host mode` fallback, which unlocks only those local actions, never rvd.
package struct UnixChkpwdChecker: OwnerPasswordChecking {
    /// NixOS keeps setuid/setgid helpers under its root-owned wrappers dir.
    package static let candidates = ["/usr/sbin/unix_chkpwd", "/sbin/unix_chkpwd", "/run/wrappers/bin/unix_chkpwd"]
    /// pam_unix's exit for a password that does not match (`PAM_AUTH_ERR`).
    static let wrongPasswordStatus: Int32 = 7
    /// Longest password passed to the helper (its own limit is 512).
    static let maxPasswordBytes = 511
    /// Longest wait for the helper. pam_unix delays a failure by ~2 s, and
    /// the CLI waits 15 s for rvd's answer.
    static let timeout: DispatchTimeInterval = .seconds(10)

    /// Name of the dedicated thread that runs and waits for the helper.
    static let waitThreadName = "rv.unix_chkpwd"

    /// Helper paths tried in order; tests point this at a stand-in.
    package var helpers: [String] = Self.candidates
    /// Called on the waiting thread just before the helper launches; tests
    /// use it to see which thread blocks.
    package var onWaitThread: (@Sendable () -> Void)?

    package init() {}

    /// The helper wait blocks for up to `timeout` plus the kill grace, so it
    /// runs on a thread of its own, never the caller's. A Swift cooperative
    /// pool thread (one per core) parked that long stalls every other task in
    /// rvd, hook evaluations included. Cancelling the calling task kills the
    /// helper and answers nil.
    package func check(_ password: String) async -> Bool? {
        guard let helper = helpers.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let user = Self.userName()
        else { return nil }
        let bytes = Array(password.utf8)
        guard bytes.isEmpty == false, bytes.count <= Self.maxPasswordBytes, bytes.contains(0) == false else {
            return false
        }
        // NUL-terminated, as pam_unix writes it.
        let payload = Data(bytes + [0])
        let run = HelperRun()
        let onWaitThread = onWaitThread
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Thread.detachNewThread {
                    Thread.current.name = Self.waitThreadName
                    onWaitThread?()
                    continuation.resume(returning: Self.runHelper(helper, user: user, payload: payload, run: run))
                }
            }
        } onCancel: {
            run.cancel()
        }
    }

    /// Blocking; `check` runs it on its own thread.
    private static func runHelper(_ helper: String, user: String, payload: Data, run: HelperRun) -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = [user, "nonull"]
        process.environment = ["PATH": "/usr/sbin:/usr/bin:/sbin:/bin"]
        // rvd's own working directory may be one this user cannot enter
        // (Foundation changes into it before exec, and the child then exits 127).
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        run.attach(process)
        defer { run.detach() }
        // rvd does not ignore SIGPIPE, so the write runs on a thread with
        // SIGPIPE blocked: a helper that exits without reading becomes EPIPE
        // here instead of killing rvd.
        let writer = input.fileHandleForWriting
        #if canImport(Darwin)
        // Darwin can still raise a thread-blocked SIGPIPE on the process;
        // this makes the write itself fail with EPIPE instead.
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        #endif
        Thread.detachNewThread {
            var blocked = sigset_t()
            sigemptyset(&blocked)
            sigaddset(&blocked, SIGPIPE)
            pthread_sigmask(SIG_BLOCK, &blocked, nil)
            try? writer.write(contentsOf: payload)
            try? writer.close()
        }
        // Bounded: a hung helper must not hold the single owner-check slot
        // (`OwnerPresence.inFlight`) forever. Answers "cannot check", which
        // does not count toward the lockout.
        guard exited.wait(timeout: .now() + Self.timeout) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + 2) != .success {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
            return nil
        }
        if process.terminationReason == .exit {
            return answer(forExitStatus: process.terminationStatus)
        }
        // Killed by a signal: ours after a cancel is no answer, any other a failure.
        return run.isCancelled ? nil : false
    }

    /// 0 is a match and `PAM_AUTH_ERR` a wrong password. Anything else means
    /// the helper could not check this account at all: `PAM_AUTHINFO_UNAVAIL`
    /// (9) for an SSSD/LDAP/AD or systemd-homed user with no local shadow
    /// entry, or when the helper cannot read shadow (no-new-privileges);
    /// `PAM_USER_UNKNOWN` and the like. Those answer nil ("cannot check",
    /// still refused) so they never count toward the wrong-password lockout.
    static func answer(forExitStatus status: Int32) -> Bool? {
        switch status {
        case 0: true
        case wrongPasswordStatus: false
        default: nil
        }
    }

    static func userName() -> String? {
        guard let entry = getpwuid(getuid()), let name = entry.pointee.pw_name else { return nil }
        let user = String(cString: name)
        return user.isEmpty ? nil : user
    }
}

/// One `unix_chkpwd` launch, so cancelling the check can kill it.
private final class HelperRun: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    /// Kills the helper at once if the check was cancelled before it started.
    func attach(_ process: Process) {
        let cancelled = lock.withLock { () -> Bool in
            self.process = process
            return self.cancelled
        }
        if cancelled { Self.stop(process) }
    }

    func detach() {
        lock.withLock { process = nil }
    }

    func cancel() {
        let process = lock.withLock { () -> Process? in
            cancelled = true
            return self.process
        }
        if let process { Self.stop(process) }
    }

    /// SIGKILL: the helper has nothing to clean up, and a cancelled check
    /// must not wait out a helper that ignores SIGTERM.
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }
}

/// rvd's owner-presence check for owner actions and non-macOS allow-once.
///
/// Owner actions (`confirm`):
/// - macOS: rvd shows the LocalAuthentication prompt itself, for every
///   authenticated caller. No role skips it, so it works on installs with
///   no peer-trust manifest, and the CLI cannot answer for the owner.
/// - Linux: the caller sends the owner's login password, which rvd verifies.
///
/// Allow-once redeem (`confirmRedemption`): the same as owner actions, with
/// rvd's own description of the code it issued as the prompt text.
///
/// Both:
/// - One check runs at a time, so an agent cannot slip a second request in
///   behind a prompt the owner is answering.
/// - Five wrong passwords or declined prompts within ten minutes lock checks
///   for ten minutes, so an agent can neither guess the password through rvd
///   nor keep putting prompts in front of the owner.
actor OwnerPresence {
    enum Verdict: Equatable {
        case approved
        case denied(ConfirmOwnerActionReply)
    }

    static let maxFailures = 5
    static let failureWindow: TimeInterval = 600
    static let lockout: TimeInterval = 600
    /// Longest an owner prompt stays open. The CLI waits a little longer
    /// (`ServiceClient.confirmOwnerActionTimeoutMs`) so rvd answers first.
    static let defaultPromptTimeout: Duration = .seconds(60)

    /// rvd's own prompt where the platform has one (macOS).
    static var platformAuthenticator: (any OwnerAuthenticating)? {
        #if canImport(LocalAuthentication)
        return LocalOwnerAuthenticator()
        #else
        return nil
        #endif
    }

    private let checker: any OwnerPasswordChecking
    private let authenticator: (any OwnerAuthenticating)?

    /// rvd shows its own owner prompt (macOS); otherwise it checks a password.
    nonisolated var promptsItself: Bool { authenticator != nil }
    private let promptTimeout: Duration
    private let clock: @Sendable () -> Date
    private var failures: [Date] = []
    private var lockedUntil: Date?
    private var inFlight = false

    init(
        checker: any OwnerPasswordChecking = UnixChkpwdChecker(),
        authenticator: (any OwnerAuthenticating)? = OwnerPresence.platformAuthenticator,
        promptTimeout: Duration = OwnerPresence.defaultPromptTimeout,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.checker = checker
        self.authenticator = authenticator
        self.promptTimeout = promptTimeout
        self.clock = clock
    }

    /// The owner approves the owner action `summary` (already sanitized by
    /// the caller); the prompt shows exactly that text.
    func confirm(_ summary: String, proof: OwnerProof?, context: AuthenticatedRequestContext) async -> Verdict {
        guard let authenticator else {
            return await verifyPassword(proof, context: context)
        }
        guard context.peer != nil else {
            return .denied(ConfirmOwnerActionReply(outcome: .proofRequired))
        }
        if let locked = lockedOutVerdict() { return locked }
        guard inFlight == false else {
            return .denied(ConfirmOwnerActionReply(outcome: .busy))
        }
        inFlight = true
        defer { inFlight = false }
        guard authenticator.isAvailable() else {
            return .denied(ConfirmOwnerActionReply(outcome: .unavailable))
        }
        let timeout = promptTimeout
        // Bounded: an unanswered prompt must not hold the single slot.
        // Cancelling the prompt task dismisses the dialog.
        let outcome = await withTaskGroup(of: OwnerPromptOutcome.self) { group in
            group.addTask { await authenticator.prompt(reason: summary) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .declined
            }
            let first = await group.next() ?? .declined
            group.cancelAll()
            return first
        }
        switch outcome {
        case .approved:
            failures.removeAll()
            return .approved
        case .declined:
            return recordFailure(.declined)
        case .unavailable:
            // No answer from the owner: no strike, or an agent could lock
            // the owner out through prompts that never appeared.
            return .denied(ConfirmOwnerActionReply(outcome: .unavailable))
        }
    }

    /// Allow-once redeem. `description` is rvd's own text for the code it
    /// issued (never the caller's). With rvd's prompt (macOS) every
    /// authenticated caller goes through `confirm`; without one (Linux), the
    /// caller sends the login password.
    func confirmRedemption(
        _ description: String, proof: OwnerProof?, context: AuthenticatedRequestContext
    ) async -> Verdict {
        guard authenticator != nil else { return await verify(proof, context: context) }
        return await confirm(description, proof: proof, context: context)
    }

    /// Password check for a platform without rvd's prompt (Linux). A pinned
    /// `.cli` (macOS only, so reached only without a prompt provider, as in
    /// tests) is accepted as before.
    func verify(_ proof: OwnerProof?, context: AuthenticatedRequestContext) async -> Verdict {
        if context.componentRole == .cli, context.peer != nil {
            return .approved
        }
        return await verifyPassword(proof, context: context)
    }

    private func verifyPassword(_ proof: OwnerProof?, context: AuthenticatedRequestContext) async -> Verdict {
        guard context.peer != nil, let password = proof?.password, password.isEmpty == false else {
            return .denied(ConfirmOwnerActionReply(outcome: .proofRequired))
        }
        if let locked = lockedOutVerdict() { return locked }
        guard inFlight == false else {
            return .denied(ConfirmOwnerActionReply(outcome: .busy))
        }
        inFlight = true
        defer { inFlight = false }
        // Suspends: the helper runs off this actor and off the cooperative pool.
        let result = await checker.check(password)
        switch result {
        case .none:
            return .denied(ConfirmOwnerActionReply(outcome: .unavailable))
        case .some(true):
            failures.removeAll()
            return .approved
        case .some(false):
            return recordFailure(.wrongPassword)
        }
    }

    private func lockedOutVerdict() -> Verdict? {
        let now = clock()
        guard let lockedUntil, now < lockedUntil else { return nil }
        return .denied(ConfirmOwnerActionReply(
            outcome: .lockedOut, retryAfterSeconds: Int(lockedUntil.timeIntervalSince(now).rounded(.up))))
    }

    private func recordFailure(_ outcome: ConfirmOwnerActionReply.Outcome) -> Verdict {
        let at = clock()
        failures = failures.filter { at.timeIntervalSince($0) < Self.failureWindow } + [at]
        if failures.count >= Self.maxFailures {
            lockedUntil = at.addingTimeInterval(Self.lockout)
            failures.removeAll()
            return .denied(ConfirmOwnerActionReply(outcome: .lockedOut, retryAfterSeconds: Int(Self.lockout)))
        }
        return .denied(ConfirmOwnerActionReply(outcome: outcome))
    }

    /// Appends one `owner.action` event to the hash-chained audit log.
    nonisolated static func audit(
        summary: String, approved: Bool, outcome: String, context: AuthenticatedRequestContext, home: HomeDirectory?
    ) {
        guard let home else { return }
        var detail = ["outcome": outcome]
        if let role = context.componentRole { detail["caller"] = String(describing: role) }
        AuditLog.append(
            AuditEvent(
                time: Date(), kind: AuditEventKind(rawValue: "owner.action"),
                decision: approved ? .allowed : .denied,
                subject: String(summary.prefix(ConfirmOwnerActionParams.maxSummaryBytes)),
                source: AuditLedger.Source.audit.rawValue, detail: detail
            ),
            configDirectory: RVPolicyPaths.configDirectory(home: home)
        )
    }
}
