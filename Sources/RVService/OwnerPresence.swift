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
    /// nil when this system cannot check passwords at all.
    func check(_ password: String) -> Bool?
}

/// Verifies the invoking user's own password with pam_unix's setgid helper
/// `unix_chkpwd`. The helper refuses to check any other account for a
/// non-root caller, reads the password from a pipe (never argv), and exits 0
/// only when it matches. Accounts without a usable password fail.
struct UnixChkpwdChecker: OwnerPasswordChecking {
    static let candidates = ["/usr/sbin/unix_chkpwd", "/sbin/unix_chkpwd"]
    /// Longest password passed to the helper (its own limit is 512).
    static let maxPasswordBytes = 511
    /// Longest wait for the helper. pam_unix delays a failure by ~2 s, and
    /// the CLI waits 15 s for rvd's answer.
    static let timeout: DispatchTimeInterval = .seconds(10)

    /// Helper paths tried in order; tests point this at a stand-in.
    var helpers: [String] = Self.candidates

    func check(_ password: String) -> Bool? {
        guard let helper = helpers.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let user = Self.userName()
        else { return nil }
        let bytes = Array(password.utf8)
        guard bytes.isEmpty == false, bytes.count <= Self.maxPasswordBytes, bytes.contains(0) == false else {
            return false
        }
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
        // NUL-terminated, as pam_unix writes it. rvd does not ignore SIGPIPE,
        // so the write runs on a thread with SIGPIPE blocked: a helper that
        // exits without reading becomes EPIPE here instead of killing rvd.
        let writer = input.fileHandleForWriting
        let payload = Data(bytes + [0])
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
        return process.terminationReason == .exit && process.terminationStatus == 0
    }

    static func userName() -> String? {
        guard let entry = getpwuid(getuid()), let name = entry.pointee.pw_name else { return nil }
        let user = String(cString: name)
        return user.isEmpty ? nil : user
    }
}

/// rvd's owner-presence check for owner actions and non-macOS allow-once.
///
/// - The genuine macOS CLI (`.cli` role, code-pinned) has already run
///   LocalAuthentication; rvd accepts it without a proof.
/// - Every other caller must send the owner's login password, which rvd
///   verifies itself.
/// - One check runs at a time, so an agent cannot slip a second request in
///   behind a prompt the owner is answering.
/// - Five wrong passwords within ten minutes lock checks for ten minutes,
///   so an agent cannot guess the password through rvd.
actor OwnerPresence {
    enum Verdict: Equatable {
        case approved
        case denied(ConfirmOwnerActionReply)
    }

    static let maxFailures = 5
    static let failureWindow: TimeInterval = 600
    static let lockout: TimeInterval = 600

    private let checker: any OwnerPasswordChecking
    private let clock: @Sendable () -> Date
    private var failures: [Date] = []
    private var lockedUntil: Date?
    private var inFlight = false

    init(checker: any OwnerPasswordChecking = UnixChkpwdChecker(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.checker = checker
        self.clock = clock
    }

    func verify(_ proof: OwnerProof?, context: AuthenticatedRequestContext) async -> Verdict {
        if context.componentRole == .cli, context.peer != nil {
            return .approved
        }
        guard context.peer != nil, let password = proof?.password, password.isEmpty == false else {
            return .denied(ConfirmOwnerActionReply(outcome: .proofRequired))
        }
        let now = clock()
        if let lockedUntil, now < lockedUntil {
            return .denied(ConfirmOwnerActionReply(
                outcome: .lockedOut, retryAfterSeconds: Int(lockedUntil.timeIntervalSince(now).rounded(.up))))
        }
        guard inFlight == false else {
            return .denied(ConfirmOwnerActionReply(outcome: .busy))
        }
        inFlight = true
        defer { inFlight = false }
        let checker = checker
        // Off the actor: the helper is a short blocking process.
        let result = await Task.detached { checker.check(password) }.value
        switch result {
        case .none:
            return .denied(ConfirmOwnerActionReply(outcome: .unavailable))
        case .some(true):
            failures.removeAll()
            return .approved
        case .some(false):
            let at = clock()
            failures = failures.filter { at.timeIntervalSince($0) < Self.failureWindow } + [at]
            if failures.count >= Self.maxFailures {
                lockedUntil = at.addingTimeInterval(Self.lockout)
                failures.removeAll()
                return .denied(ConfirmOwnerActionReply(outcome: .lockedOut, retryAfterSeconds: Int(Self.lockout)))
            }
            return .denied(ConfirmOwnerActionReply(outcome: .wrongPassword))
        }
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
