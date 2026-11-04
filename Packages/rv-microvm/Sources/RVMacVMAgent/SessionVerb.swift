import Darwin
import Foundation
import RVMicroVMCore

/// `rv-macvm-agent session`: runs one guest command from the request in
/// `RV_MACVM_SESSION`. In a guest, `sshd` starts it as the guest user (see
/// `MacVMSession`); in host tests the agent starts it directly.
///
/// It leads the command's process group and ignores the signals that
/// group receives, so a terminal's Ctrl-C or the agent's `kill(-group)`
/// reaches the command once. When the command exits it kills what is left
/// of the group and exits with the shell status.
public enum SessionVerb {
    /// Ignored here, default in the command: the signals the agent forwards
    /// and the terminal's job-control signals.
    public static let forwardedSignals: [Int32] = [
        SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGUSR1, SIGUSR2, SIGALRM, SIGWINCH, SIGINFO,
    ]
    static let jobControlSignals: [Int32] = [SIGTSTP, SIGTTIN, SIGTTOU]
    /// After the command exits, how long its background processes may keep
    /// writing before they are killed.
    static let leftoverGraceMicroseconds: useconds_t = 300_000

    public static func run() -> Never {
        // First, so a signal the agent forwards as soon as this process
        // exists is meant for the command and cannot end the session.
        (forwardedSignals + jobControlSignals).forEach { signal($0, SIG_IGN) }
        guard let value = ProcessInfo.processInfo.environment[MacVMSession.variable],
            let request = MacVMSession.decode(value)
        else { fail("no valid \(MacVMSession.variable) request") }
        if let problem = request.validated() { fail(problem) }
        unsetenv(MacVMSession.variable)
        guard chdir(request.workspace) == 0 else {
            fail("cannot enter \(request.workspace): \(String(cString: strerror(errno)))")
        }
        leadProcessGroup()

        let arguments = [GuestChild.sandboxExec, "-p", MacVMSession.guardedProfile(request.sandboxProfile)]
            + request.arguments
        let pid: pid_t
        switch spawn(arguments, environment: request.environment) {
        case .failure(let message): fail(message.description)
        case .success(let spawned): pid = spawned
        }
        var status: Int32 = 0
        var reaped = waitpid(pid, &status, 0)
        while reaped < 0, errno == EINTR { reaped = waitpid(pid, &status, 0) }
        // ECHILD or any other failure leaves `status` meaningless: not success.
        if reaped < 0 { status = CommandGroup.unknownStatus }
        stopGroup()
        if isGuestUser { sweepUser() }
        exit(GuestChild.shellStatus(status))
    }

    /// Under `sshd` a login shell may run this as its child: become the
    /// group leader, and the terminal's foreground group.
    static func leadProcessGroup() {
        guard getpgrp() != getpid() else { return }
        _ = setpgid(0, 0)
        if isatty(STDIN_FILENO) == 1 { _ = tcsetpgrp(STDIN_FILENO, getpid()) }
    }

    static func spawn(_ arguments: [String], environment: [String]) -> Result<pid_t, AgentError> {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addinherit_np(&actions, descriptor)
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        )
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        var pid: pid_t = 0
        let status = withCStrings(arguments) { argv in
            withCStrings(environment) { envp in posix_spawn(&pid, arguments[0], &actions, &attributes, argv, envp) }
        }
        guard status == 0 else {
            return .failure(AgentError("cannot start \(arguments[0]): \(String(cString: strerror(status)))"))
        }
        return .success(pid)
    }

    /// Kills the rest of this group, after a grace period if any remain.
    static func stopGroup() {
        guard !others(inGroup: getpgrp()).isEmpty else { return }
        usleep(leftoverGraceMicroseconds)
        others(inGroup: getpgrp()).forEach { _ = kill($0, SIGKILL) }
    }

    static func others(inGroup group: pid_t) -> [pid_t] {
        processes(PROC_PGRP_ONLY, UInt32(group)).filter { $0 != getpid() }
    }

    /// True in a guest: only then does every process of this user belong
    /// to this command.
    static var isGuestUser: Bool {
        guard let entry = getpwuid(getuid()) else { return false }
        return String(cString: entry.pointee.pw_name) == MacVMAgent.user
    }

    /// Kills every process of this user except this one and its ancestors
    /// (the `sshd` session that carries the exit status): a process that
    /// left the group would otherwise keep the session open.
    static func sweepUser() {
        var keep: Set<pid_t> = [getpid()]
        var ancestor = getppid()
        while ancestor > 1, keep.insert(ancestor).inserted, let next = parent(of: ancestor) {
            ancestor = next
        }
        processes(PROC_UID_ONLY, UInt32(getuid())).filter { !keep.contains($0) }.forEach { _ = kill($0, SIGKILL) }
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? pid_t(info.pbi_ppid) : nil
    }

    static func processes(_ kind: Int32, _ value: UInt32) -> [pid_t] {
        let estimate = proc_listpids(UInt32(kind), value, nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) / MemoryLayout<pid_t>.size + 32)
        let bytes = proc_listpids(UInt32(kind), value, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(max(0, Int(bytes)) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("rv-macvm-agent: \(message)\n".utf8))
        exit(126)
    }
}
