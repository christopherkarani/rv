#if os(macOS)
import Darwin
import Foundation
import RVDomain
import Synchronization

private let seatbeltHandshakeScript =
    "printf %s \"$1\" >&3 || exit 127; exec 3>&- || exit 127; shift; exec \"$@\""

/// Seatbelt launch: persist the session, spawn into an RV process group,
/// read a handshake byte string that only the in-sandbox wrapper can write,
/// then signal the group and wait until it is empty.
///
/// The child receives no descriptor the file actions did not grant.
/// Those grants are stdin/stdout/stderr for the selected IO mode, the
/// handshake write end on fd 3, and the admission pipes on fds 4 and 5.
/// A pseudo-terminal slave replaces `/dev/null` on 0, 1, and 2. The master
/// stays in RV. `POSIX_SPAWN_SETSID` runs before Seatbelt, so the child is
/// the session leader without a `setsid` allow inside the sandbox.
/// Darwin does not make that slave the controlling terminal from a file
/// action. `rv-pty-claim` reopens the slave, calls `TIOCSCTTY`, and sets
/// the foreground group to its own pid, then execs `sandbox-exec`. The
/// parent reads that group back. A live child whose group is not that pid
/// is killed. The wrapper closes fd 3 before exec. Fds 4 and 5 stay open
/// for the payload.
/// They are pipes RV created. The profile does not gain a socket or network allow.
/// The child stays stopped until its process group is recorded, so a failed
/// registration never executes the agent.
func superviseSeatbelt(
    _ request: IsolatedLaunchRequest,
    host: HookHost?,
    sessionStore: RuntimeSessionStore,
    admission: RuntimeAdmissionConfiguration = .failClosed
) -> Result<IsolatedRunResult, IsolationApplyError> {
    guard request.family == .seatbelt, let profile = request.seatbeltProfile else {
        return .failure(.backendMismatch)
    }
    guard FileManager.default.isExecutableFile(atPath: IsolationBackends.sandboxExecPath) else {
        return .failure(.backendUnavailable)
    }
    guard let workspace = request.containedWorkspacePath,
        let directory = WorkingDirectory(validating: workspace)
    else {
        return .failure(.containedGuaranteesUnsupported)
    }
    guard case .contained = request.plan.mode else {
        return .failure(.profileNotApplicable)
    }
    guard let plannedWorkspace = request.plan.workspace else {
        return .failure(.containedGuaranteesUnsupported)
    }
    switch existingResolvedWorkspacePath(plannedWorkspace) {
    case .failure(let error):
        return .failure(error)
    case .success(let resolved):
        guard resolved == workspace else {
            return .failure(.workspacePathUnresolvable)
        }
    }
    switch rejectWorkspaceInodeAlias(workspace) {
    case .failure(let error):
        return .failure(error)
    case .success:
        break
    }
    if blockingWorkIsCancelled() {
        return .failure(.cancelled)
    }
    // Hand-built profiles that are not the contained compiler output never
    // mount or execute. Production profiles include this deny.
    guard profile.source.contains("(deny file-link)") else {
        return .failure(.seatbeltNotEstablished)
    }
    let supervisor: WorkspaceSessionSupervisor
    switch WorkspaceSessionSupervisor.open(directory) {
    case .failure(let error):
        return .failure(WorkspaceSessionFailure.isolation(error))
    case .success(let opened):
        supervisor = opened
    }
    let mounted = supervisor.runSingleRuntime(
        request,
        host: host,
        sessionStore: sessionStore,
        admission: admission
    )
    let teardown = supervisor.finishSingleRuntime(publish: mounted.publish)
    return containedLaunchResult(child: mounted.result, teardown: teardown)
}

/// The workspace is back at its original path only when teardown succeeds.
/// A failed detach or rename is the result the caller has to act on, including
/// when the child already failed or the task was cancelled.
func containedLaunchResult(
    child: Result<IsolatedRunResult, IsolationApplyError>,
    teardown: Result<Void, IsolationApplyError>
) -> Result<IsolatedRunResult, IsolationApplyError> {
    switch teardown {
    case .failure(let error):
        return .failure(error)
    case .success:
        return child
    }
}

struct MountedSeatbeltOutcome {
    var result: Result<IsolatedRunResult, IsolationApplyError>
    /// Copy the volume back only after the in-sandbox handshake succeeded.
    /// The workspace owner reads this. A child exit does not publish.
    var publish: Bool
}

/// Cooperative stop for one runtime. The watch loop polls it.
final class RuntimeCancellation: @unchecked Sendable {
    private let flag = Mutex(false)

    func request() {
        flag.withLock { $0 = true }
    }

    var isRequested: Bool {
        flag.withLock { $0 }
    }
}

private final class AdmissionReply: @unchecked Sendable {
    private let value = Mutex<RuntimeAdmissionDecision?>(nil)

    func store(_ decision: RuntimeAdmissionDecision) {
        value.withLock { $0 = decision }
    }

    func current() -> RuntimeAdmissionDecision? {
        value.withLock { $0 }
    }
}

/// One Seatbelt process after `posix_spawn`. The watch loop owns its lifetime.
final class LiveSeatbeltChild: @unchecked Sendable {
    let session: RuntimeSession
    let capability: RuntimeCapability
    let pid: pid_t
    let nonce: String
    let admission: RuntimeAdmissionSession
    /// Parent-side descriptors that must not appear in the child.
    private let retainedDescriptors: [Int32]
    let pty: RuntimeTerminal?
    var handshakeRead: Int32
    /// Nonce bytes already read while proving a dead leader. The watch
    /// must still see them; a pipe read is consuming.
    var handshakePreface = Data()
    private let established = Mutex(false)
    private let watchStarted = Mutex(false)
    private let terminal = Mutex<IsolationApplyError?>(nil)
    private struct PendingFrame: Sendable {
        var frame: RuntimeActionFrame
        var reply: AdmissionReply
    }
    private let pending = Mutex<PendingFrame?>(nil)

    init(
        session: RuntimeSession,
        capability: RuntimeCapability,
        pid: pid_t,
        nonce: String,
        admission: RuntimeAdmissionSession,
        parentDescriptors: [Int32],
        handshakeRead: Int32,
        terminal: RuntimeTerminal?
    ) {
        self.session = session
        self.capability = capability
        self.pid = pid
        self.nonce = nonce
        self.admission = admission
        self.retainedDescriptors = parentDescriptors
        self.handshakeRead = handshakeRead
        self.pty = terminal
    }

    /// Descriptors RV still holds. The PTY master is included only while it
    /// is open, so a reused descriptor number is not reported after close.
    var parentDescriptors: [Int32] {
        var values = retainedDescriptors
        if let fd = pty?.masterFD, fd >= 0 {
            values.append(fd)
        }
        return values
    }

    var isEstablished: Bool { established.withLock { $0 } }

    func markEstablished() {
        established.withLock { $0 = true }
    }

    func markWatchStarted() {
        watchStarted.withLock { $0 = true }
    }

    func recordTerminal(_ error: IsolationApplyError?) {
        terminal.withLock { $0 = error }
    }

    /// Spawn succeeded and then the runtime was not registered. Stop the
    /// reader, close the master once, and drop the admission pipes. The
    /// watch thread is not running, so nothing else will do this.
    func releaseAbandoned() {
        pty?.finish(status: nil)
        if handshakeRead >= 0 {
            close(handshakeRead)
            handshakeRead = -1
        }
        admission.finish()
    }

    var terminalError: IsolationApplyError? {
        terminal.withLock { $0 }
    }

    /// Ask the watch thread to run one frame. Returns nil if a frame is
    /// already waiting or the watch does not answer.
    func submit(_ frame: RuntimeActionFrame) -> RuntimeAdmissionDecision? {
        let reply = AdmissionReply()
        let posted = pending.withLock { current -> Bool in
            guard current == nil else { return false }
            current = PendingFrame(frame: frame, reply: reply)
            return true
        }
        guard posted else { return nil }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let decision = reply.current() { return decision }
            usleep(5_000)
        }
        return nil
    }

    /// Called only from the watch thread.
    func drainPending() {
        let job = pending.withLock { current -> PendingFrame? in
            defer { current = nil }
            return current
        }
        guard let job else { return }
        job.reply.store(admission.submit(.success(job.frame)))
    }

    deinit {
        abandonIfUnwatched()
        pty?.shutdownMaster()
    }

    /// The watch never started. Signal the group and drop parent descriptors.
    /// A second call is a no-op so `deinit` can run after an early failure.
    func abandonIfUnwatched() {
        let started = watchStarted.withLock { value -> Bool in
            if value { return true }
            value = true
            return false
        }
        guard started == false else { return }
        if handshakeRead >= 0 {
            close(handshakeRead)
            handshakeRead = -1
        }
        admission.finish()
        terminateSession(pgid: pid, also: [pid])
        _ = waitUntilSessionIsDead(pgid: pid, also: [pid])
        pty?.shutdownMaster()
    }
}

func spawnSeatbeltProcess(
    _ request: IsolatedLaunchRequest,
    workspace: String,
    profile: SeatbeltProfile,
    boundary: WorkspaceInodeBoundary,
    started: RuntimeSession,
    admission: RuntimeAdmissionConfiguration
) -> Result<LiveSeatbeltChild, IsolationApplyError> {
    guard profile.source.contains("(deny file-link)") else {
        return .failure(.seatbeltNotEstablished)
    }
    guard boundary.remainsEstablished() else {
        return .failure(.workspaceInodeBoundaryFailed)
    }

    var admissionPipes = RuntimeAdmissionPipes()
    guard admissionPipes.open() else {
        return .failure(.processSpawnFailed)
    }
    defer { admissionPipes.closeRemaining() }
    var admissionSession: RuntimeAdmissionSession?
    defer { admissionSession?.finish() }

    let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    var pipeFDs: [Int32] = [-1, -1]
    let pipeResult = pipeFDs.withUnsafeMutableBufferPointer { buffer -> Int32 in
        guard let base = buffer.baseAddress else { return -1 }
        return pipe(base)
    }
    guard pipeResult == 0 else {
        return .failure(.processSpawnFailed)
    }
    var readEnd = pipeFDs[0]
    var writeEnd = pipeFDs[1]
    var nullFD: Int32 = -1
    defer {
        if readEnd >= 0 { close(readEnd) }
        if writeEnd >= 0 { close(writeEnd) }
        if nullFD >= 0 { close(nullFD) }
    }
    guard fcntl(readEnd, F_SETFD, FD_CLOEXEC) >= 0,
        fcntl(writeEnd, F_SETFD, FD_CLOEXEC) >= 0
    else {
        return .failure(.processSpawnFailed)
    }
    if readEnd < 16 {
        let moved = fcntl(readEnd, F_DUPFD_CLOEXEC, 16)
        guard moved >= 0 else { return .failure(.processSpawnFailed) }
        close(readEnd)
        readEnd = moved
    }

    let terminal: RuntimeTerminal?
    let spawnFlags: Int16
    let suspended = Int16(POSIX_SPAWN_START_SUSPENDED)
    let signals = Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
    switch request.io {
    case .discard, .inherit:
        terminal = nil
        spawnFlags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT) | suspended | signals
    case .pseudoTerminal(let rows, let columns):
        guard let opened = RuntimeTerminal.open(rows: rows, columns: columns) else {
            return .failure(.processSpawnFailed)
        }
        terminal = opened
        if request.spawnFault == .spawn {
            opened.shutdownMaster()
            return .failure(.processSpawnFailed)
        }
        // SETSID is not combined with SETPGROUP. The recorded process group
        // is the session leader's pid. START_SUSPENDED holds the image until
        // that group is durable.
        spawnFlags = Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT) | suspended | signals
    }
    var handedOff = false
    defer {
        if handedOff == false {
            terminal?.shutdownMaster()
        }
    }

    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else {
        return .failure(.lifetimeBoundaryFailed)
    }
    defer { posix_spawnattr_destroy(&attributes) }
    // Every parent descriptor is close-on-exec unless a file action grants it.
    guard posix_spawnattr_setflags(&attributes, spawnFlags) == 0 else {
        return .failure(.lifetimeBoundaryFailed)
    }
    // The host thread often has SIGINT blocked or ignored. A terminal child
    // must receive VINTR with the default action, or Ctrl-C never lands.
    var emptyMask = sigset_t()
    sigemptyset(&emptyMask)
    var defaulted = sigset_t()
    sigemptyset(&defaulted)
    for number in [SIGINT, SIGQUIT, SIGHUP, SIGTERM, SIGTSTP, SIGTTIN, SIGTTOU, SIGWINCH, SIGINFO] {
        sigaddset(&defaulted, number)
    }
    guard posix_spawnattr_setsigmask(&attributes, &emptyMask) == 0,
        posix_spawnattr_setsigdefault(&attributes, &defaulted) == 0
    else {
        return .failure(.lifetimeBoundaryFailed)
    }
    if terminal == nil {
        guard posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            return .failure(.lifetimeBoundaryFailed)
        }
    }

    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else {
        return .failure(.processSpawnFailed)
    }
    defer { posix_spawn_file_actions_destroy(&actions) }
    let chdirResult = workspace.withCString { path in
        if #available(macOS 26, *) {
            posix_spawn_file_actions_addchdir(&actions, path)
        } else {
            posix_spawn_file_actions_addchdir_np(&actions, path)
        }
    }
    guard chdirResult == 0 else {
        return .failure(.processSpawnFailed)
    }
    guard installGrantedDescriptorActions(
        &actions,
        io: request.io,
        readEnd: readEnd,
        writeEnd: writeEnd,
        nullFD: &nullFD,
        slavePath: terminal?.slavePath
    ), installAdmissionDescriptors(&actions, pipes: admissionPipes) else {
        return .failure(.processSpawnFailed)
    }
    guard boundary.remainsEstablished() else {
        return .failure(.workspaceInodeBoundaryFailed)
    }

    // Missing claim helper fails closed. Do not spawn sandbox-exec directly:
    // the parent cannot install the controlling terminal from outside the
    // child's session, and a live unclaimed group is the boundary failure.
    let handshakeScript = seatbeltHandshakeScript
    let spawnPath: String
    var arguments: [String]
    if let terminal {
        guard let claim = resolvedPtyClaimPath(workspace: workspace) else {
            return .failure(.lifetimeBoundaryFailed)
        }
        // argv[1] is the slave. The helper reopens it after SETSID. The
        // payload starts at argv[2], so sandbox-exec still sees its own path
        // as argv[0].
        spawnPath = claim
        arguments = [claim, terminal.slavePath, IsolationBackends.sandboxExecPath]
    } else {
        spawnPath = IsolationBackends.sandboxExecPath
        arguments = [IsolationBackends.sandboxExecPath]
    }
    arguments.append(contentsOf: [
        "-p",
        profile.source,
        "/bin/sh",
        "-c",
        handshakeScript,
        "rv-seatbelt",
        nonce,
        request.command.executable,
    ])
    arguments.append(contentsOf: request.command.arguments)
    let environment = containedRuntimeEnvironment(workspace: workspace, io: request.io)
    let argv = SpawnPointers(arguments)
    let envp = SpawnPointers(environment)
    defer {
        argv.release()
        envp.release()
    }

    if TerminalTestInjection.failSpawn.withLock({ $0 }) {
        return .failure(.processSpawnFailed)
    }

    var pid: pid_t = 0
    let spawnResult = argv.withPointers { argvPointer in
        envp.withPointers { envPointer in
            posix_spawn(
                &pid,
                spawnPath,
                &actions,
                &attributes,
                argvPointer,
                envPointer
            )
        }
    }
    if nullFD >= 0 {
        close(nullFD)
        nullFD = -1
    }
    if writeEnd >= 0 {
        close(writeEnd)
        writeEnd = -1
    }
    if admissionPipes.requestWrite >= 0 {
        close(admissionPipes.requestWrite)
        admissionPipes.requestWrite = -1
    }
    if admissionPipes.responseRead >= 0 {
        close(admissionPipes.responseRead)
        admissionPipes.responseRead = -1
    }
    guard spawnResult == 0, pid > 1 else {
        return .failure(.processSpawnFailed)
    }
    // The wait loop polls this fd. A blocking read would ignore cancellation
    // until the child writes or exits, so a failed flag change cannot continue.
    let flagsNow = fcntl(readEnd, F_GETFL)
    let admissionFlags = fcntl(admissionPipes.requestRead, F_GETFL)
    guard flagsNow >= 0, fcntl(readEnd, F_SETFL, flagsNow | O_NONBLOCK) >= 0,
        admissionFlags >= 0,
        fcntl(admissionPipes.requestRead, F_SETFL, admissionFlags | O_NONBLOCK) >= 0
    else {
        terminateSession(pgid: pid, also: [pid])
        _ = waitUntilSessionIsDead(pgid: pid, also: [pid])
        return .failure(.lifetimeBoundaryFailed)
    }

    let pgid = getpgid(pid)
    if pgid != pid {
        let alreadyExited = pgid == -1 && errno == ESRCH
        if alreadyExited == false {
            terminateSession(pgid: pid, also: [pid])
            _ = waitUntilSessionIsDead(pgid: pid, also: [pid])
            return .failure(.lifetimeBoundaryFailed)
        }
    }
    // The image is still stopped. Recording the process group happens before
    // SIGCONT. The claim helper cannot install the controlling terminal until
    // that resume, so the foreground proof runs there, not here.

    let capability = RuntimeCapability()
    let parentRead = admissionPipes.requestRead
    let parentWrite = admissionPipes.responseWrite
    let running = started.withChild(pid: pid)
    let admitted = RuntimeAdmissionSession(
        binding: RuntimeChannelBinding(session: running, capability: capability),
        configuration: admission,
        launch: AdmittedLaunchContext(
            plan: compileContainedPlan(
                workspace: request.plan.workspace ?? running.workspace,
                repositoryRoot: request.plan.repositoryRoot
            ),
            profileSource: profile.source,
            workspacePath: workspace,
            sessionLeader: pid
        ),
        requestRead: parentRead,
        responseWrite: parentWrite
    )
    admissionPipes.requestRead = -1
    admissionPipes.responseWrite = -1
    admissionSession = nil
    admitted.sendGrant()
    let ownedRead = readEnd
    readEnd = -1
    let child = LiveSeatbeltChild(
        session: running,
        capability: capability,
        pid: pid,
        nonce: nonce,
        admission: admitted,
        parentDescriptors: [ownedRead, parentRead, parentWrite],
        handshakeRead: ownedRead,
        terminal: terminal
    )
    handedOff = true
    return .success(child)
}

private func containedRuntimeEnvironment(workspace: String, io: IsolatedIO) -> [String] {
    var values = [
        "PATH=/usr/bin:/bin",
        "LANG=C",
        "LC_ALL=C",
        "HOME=\(workspace)",
        "TMPDIR=\(workspace)",
    ]
    if case .pseudoTerminal = io {
        values.append("TERM=\(TerminalStreamLimits.supportedTerm)")
    }
    return values
}

func watchSeatbeltProcess(
    _ live: LiveSeatbeltChild,
    stop: RuntimeCancellation
) -> MountedSeatbeltOutcome {
    live.markWatchStarted()
    let outcome = waitForSeatbeltSession(
        root: live.pid,
        readEnd: live.handshakeRead,
        nonce: live.nonce,
        preface: live.handshakePreface,
        admission: live.admission,
        stop: stop,
        onEstablished: { live.markEstablished() },
        drain: { live.drainPending() }
    )
    let dead = waitUntilSessionIsDead(
        pgid: live.pid,
        also: outcome.recordedPIDs.union([live.pid])
    )
    let mounted: MountedSeatbeltOutcome
    if dead == false {
        mounted = MountedSeatbeltOutcome(result: .failure(.lifetimeBoundaryFailed), publish: false)
    } else if outcome.cancelled {
        mounted = MountedSeatbeltOutcome(
            result: .failure(.cancelled),
            publish: outcome.established
        )
    } else if outcome.established, let status = outcome.status {
        mounted = MountedSeatbeltOutcome(
            result: .success(
                IsolatedRunResult(
                    established: .seatbelt(live.session),
                    exitStatus: status
                )
            ),
            publish: true
        )
    } else {
        mounted = MountedSeatbeltOutcome(
            result: .failure(.seatbeltNotEstablished),
            publish: false
        )
    }
    if case .failure(let error) = mounted.result {
        live.recordTerminal(error)
    } else {
        live.recordTerminal(nil)
    }
    live.pty?.finish(status: outcome.status)
    if live.handshakeRead >= 0 {
        close(live.handshakeRead)
        live.handshakeRead = -1
    }
    return mounted
}

private struct SeatbeltWaitOutcome {
    var established = false
    var cancelled = false
    var status: Int32?
    var recordedPIDs: Set<pid_t> = []
}

private func waitForSeatbeltSession(
    root: pid_t,
    readEnd: Int32,
    nonce: String,
    preface: Data = Data(),
    admission: RuntimeAdmissionSession,
    stop: RuntimeCancellation,
    onEstablished: () -> Void,
    drain: () -> Void
) -> SeatbeltWaitOutcome {
    var outcome = SeatbeltWaitOutcome()
    var handshake = preface
    let expected = Data(nonce.utf8)
    var recorded: Set<pid_t> = [root]
    while true {
        if blockingWorkIsCancelled() || stop.isRequested {
            outcome.cancelled = true
            admission.finish()
        }
        if outcome.established == false {
            handshake.append(contentsOf: readAvailable(readEnd, limit: expected.count))
            if handshake.starts(with: expected), handshake.count >= expected.count {
                outcome.established = true
                onEstablished()
            }
        }
        drain()
        recorded.formUnion(visibleSessionPIDs(root: root))
        var status: Int32 = 0
        let waited = waitpid(root, &status, WNOHANG)
        if waited == root {
            outcome.status = exitStatus(status)
        }
        let rootGone = waited == root || (waited < 0 && errno == ECHILD && outcome.status != nil)
        if outcome.cancelled || rootGone {
            admission.finish()
            recorded.formUnion(visibleSessionPIDs(root: root))
            terminateSession(pgid: root, also: recorded)
            if outcome.established == false {
                handshake.append(contentsOf: readAvailable(readEnd, limit: expected.count))
                if handshake.starts(with: expected), handshake.count >= expected.count {
                    outcome.established = true
                    onEstablished()
                }
            }
            if outcome.status == nil {
                outcome.status = reapLeaderStatus(root)
            }
            outcome.recordedPIDs = recorded
            return outcome
        }
        if outcome.established {
            admission.service()
        }
        usleep(10_000)
    }
}

/// Grants stdio and the handshake write end. Admission fds are added by the
/// caller after this returns, so a `/dev/null` close cannot drop them.
/// The handshake is installed first so a later `/dev/null` dup cannot overwrite
/// a pipe end on 0, 1, or 2 before it is copied to fd 3.
/// `/dev/null` itself is moved to fd 16 or above. If that open stayed on fd 3,
/// the close of the extra `/dev/null` descriptor would drop the handshake
/// write end just installed there.
/// `POSIX_SPAWN_CLOEXEC_DEFAULT` closes every descriptor these file actions
/// do not grant, including the log and any socket the parent still holds.
private func installGrantedDescriptorActions(
    _ actions: inout posix_spawn_file_actions_t?,
    io: IsolatedIO,
    readEnd: Int32,
    writeEnd: Int32,
    nullFD: inout Int32,
    slavePath: String?
) -> Bool {
    if writeEnd == 3 {
        guard posix_spawn_file_actions_addinherit_np(&actions, writeEnd) == 0 else {
            return false
        }
    } else {
        guard posix_spawn_file_actions_adddup2(&actions, writeEnd, 3) == 0 else {
            return false
        }
    }
    if readEnd != 3 {
        guard posix_spawn_file_actions_addclose(&actions, readEnd) == 0 else {
            return false
        }
    }
    if writeEnd != 3 {
        guard posix_spawn_file_actions_addclose(&actions, writeEnd) == 0 else {
            return false
        }
    }
    switch io {
    case .inherit:
        return posix_spawn_file_actions_addinherit_np(&actions, STDIN_FILENO) == 0
            && posix_spawn_file_actions_addinherit_np(&actions, STDOUT_FILENO) == 0
            && posix_spawn_file_actions_addinherit_np(&actions, STDERR_FILENO) == 0
    case .discard:
        let opened = open("/dev/null", O_RDWR | O_CLOEXEC)
        guard opened >= 0 else { return false }
        nullFD = opened
        if nullFD < 16 {
            let moved = fcntl(nullFD, F_DUPFD_CLOEXEC, 16)
            guard moved >= 0 else { return false }
            close(nullFD)
            nullFD = moved
        }
        guard posix_spawn_file_actions_adddup2(&actions, nullFD, STDIN_FILENO) == 0,
            posix_spawn_file_actions_adddup2(&actions, nullFD, STDOUT_FILENO) == 0,
            posix_spawn_file_actions_adddup2(&actions, nullFD, STDERR_FILENO) == 0,
            posix_spawn_file_actions_addclose(&actions, nullFD) == 0
        else {
            return false
        }
        return true
    case .pseudoTerminal:
        guard let slavePath else { return false }
        let opened = slavePath.withCString { path in
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, path, O_RDWR, 0)
        }
        guard opened == 0,
            posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO) == 0,
            posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO) == 0
        else {
            return false
        }
        return true
    }
}

private func readAvailable(_ fd: Int32, limit: Int) -> Data {
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 256)
    while bytes.count < limit {
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return read(fd, base, min(raw.count, limit - bytes.count))
        }
        if count > 0 {
            bytes.append(contentsOf: buffer.prefix(count))
            continue
        }
        if count < 0, errno == EINTR {
            continue
        }
        return Data(bytes)
    }
    return Data(bytes)
}

private func visibleSessionPIDs(root: pid_t) -> Set<pid_t> {
    var found: Set<pid_t> = []
    var pending = [root]
    var seen = Set<pid_t>()
    while let pid = pending.popLast() {
        guard pid > 1, seen.insert(pid).inserted else { continue }
        found.insert(pid)
        for child in listedPIDs(proc_listchildpids, pid) {
            pending.append(child)
        }
    }
    for member in listedPIDs(proc_listpgrppids, root) {
        found.insert(member)
    }
    return found
}

private func listedPIDs(
    _ call: (pid_t, UnsafeMutableRawPointer?, Int32) -> Int32,
    _ pid: pid_t
) -> [pid_t] {
    let capacity = 512
    var buffer = [Int32](repeating: 0, count: capacity)
    let bytes = buffer.withUnsafeMutableBytes { raw -> Int32 in
        guard let base = raw.baseAddress else { return -1 }
        return call(pid, base, Int32(raw.count))
    }
    guard bytes > 0 else { return [] }
    let count = min(Int(bytes) / MemoryLayout<Int32>.size, capacity)
    return buffer.prefix(count).compactMap { value in
        value > 1 ? pid_t(value) : nil
    }
}

/// `POSIX_SPAWN_START_SUSPENDED` stops the child before its image runs.
func resumeSuspendedSeatbelt(_ pid: pid_t) -> Bool {
    guard pid > 1 else { return false }
    return kill(pid, SIGCONT) == 0
}

/// Continue a spawned child, then require a PTY leader to be its own
/// foreground group. Discard and inherit have no claim helper.
/// The reader starts only after the claim succeeds, so a failed proof does
/// not leave a thread on a master that is about to be closed.
func resumeAndClaimForeground(_ child: LiveSeatbeltChild) -> Result<Void, IsolationApplyError> {
    guard resumeSuspendedSeatbelt(child.pid) else {
        return .failure(.lifetimeBoundaryFailed)
    }
    guard let terminal = child.pty else {
        return .success(())
    }
    switch proveForegroundGroup(
        terminal,
        pid: child.pid,
        handshake: child.handshakeRead,
        nonce: Data(child.nonce.utf8)
    ) {
    case .claimed(let preface):
        child.handshakePreface = preface
        terminal.startReader()
        return .success(())
    case .cancelled:
        terminateSession(pgid: child.pid, also: [child.pid])
        _ = waitUntilSessionIsDead(pgid: child.pid, also: [child.pid])
        return .failure(.cancelled)
    case .failed:
        terminateSession(pgid: child.pid, also: [child.pid])
        _ = waitUntilSessionIsDead(pgid: child.pid, also: [child.pid])
        return .failure(.lifetimeBoundaryFailed)
    }
}

private func terminateSession(pgid: pid_t, also pids: Set<pid_t>) {
    if pgid > 1 {
        _ = kill(-pgid, SIGKILL)
    }
    for pid in pids where pid > 1 {
        _ = kill(pid, SIGKILL)
    }
}

/// After SIGKILL, poll `waitpid(WNOHANG)` for a short bound. A blocking
/// `waitpid` does not return when the leader is stuck in disk I/O.
private func reapLeaderStatus(_ pid: pid_t) -> Int32? {
    let deadline = Date().addingTimeInterval(0.25)
    while Date() < deadline {
        var status: Int32 = 0
        let waited = waitpid(pid, &status, WNOHANG)
        if waited == pid {
            return exitStatus(status)
        }
        if waited < 0, errno == ECHILD {
            return nil
        }
        usleep(10_000)
    }
    return nil
}

private func waitUntilSessionIsDead(pgid: pid_t, also pids: Set<pid_t>, reap: Bool = true) -> Bool {
    for _ in 0..<200 {
        if reap {
            var status: Int32 = 0
            _ = waitpid(pgid, &status, WNOHANG)
        }
        terminateSession(pgid: pgid, also: pids)
        let gone = pids.allSatisfy { processIsGone($0) || (reap == false && sessionLeaderHasExited($0)) }
        if processGroupIsEmpty(pgid), gone {
            return true
        }
        usleep(10_000)
    }
    let gone = pids.allSatisfy { processIsGone($0) || (reap == false && sessionLeaderHasExited($0)) }
    return processGroupIsEmpty(pgid) && gone
}

/// SIGKILL the session leader's group.
/// `reap: false` does not `waitpid`, so the watch thread still collects the status.
func stopOwnedSession(leader: pid_t, reap: Bool = true) -> Bool {
    terminateSession(pgid: leader, also: [leader])
    if reap == false {
        return sessionLeaderHasExited(leader) || processIsGone(leader)
    }
    return waitUntilSessionIsDead(pgid: leader, also: visibleSessionPIDs(root: leader).union([leader]))
}

func processGroupIsEmpty(_ pgid: pid_t) -> Bool {
    guard pgid > 1 else { return false }
    return kill(-pgid, 0) == -1 && errno == ESRCH
}

func processIsGone(_ pid: pid_t) -> Bool {
    guard pid > 1 else { return true }
    if kill(pid, 0) == 0 {
        return false
    }
    return errno == ESRCH
}

private enum ForegroundProof {
    case claimed(Data)
    case cancelled
    case failed
}

/// Polls until the session leader is the foreground group, the leader has
/// exited after the post-claim handshake, or the deadline passes.
/// Two seconds is the claim itself, not a test timeout. A live mismatch
/// is `.failed`.
private func proveForegroundGroup(
    _ terminal: RuntimeTerminal,
    pid: pid_t,
    handshake: Int32,
    nonce: Data
) -> ForegroundProof {
    let deadline = Date().addingTimeInterval(2)
    while true {
        if blockingWorkIsCancelled() {
            return .cancelled
        }
        let exited = sessionLeaderHasExited(pid) || processIsGone(pid)
        if exited == false, foregroundGroupIsLeader(terminal, pid: pid) {
            return .claimed(Data())
        }
        if exited {
            let queued = readAvailable(handshake, limit: max(nonce.count, 1))
            if deadLeaderClaimedByHandshake(queued: queued, nonce: nonce) {
                return .claimed(queued)
            }
            return .failed
        }
        if Date() >= deadline {
            return .failed
        }
        usleep(1_000)
    }
}

private let ptyClaimExecutableName = "rv-pty-claim"

/// Layouts where `release.sh` and `swift build` publish `rv-pty-claim`.
/// The test runner's argv0 is the xctest inside `debug/`, not the host
/// binary. The host publishes the helper beside itself in `release-stage`
/// and in the release products directory.
private let ptyClaimPublishSuffixes = [
    "rv-pty-claim",
    "release/rv-pty-claim",
    "debug/rv-pty-claim",
    "release-stage/rv-pty-claim",
    ".build/release-stage/rv-pty-claim",
    ".build/debug/rv-pty-claim",
    ".build/release/rv-pty-claim",
]

/// Locate `rv-pty-claim`. Never an env override, never a relative argv0,
/// never a helper at or under the workspace. A missing helper fails the
/// PTY launch. There is no direct `sandbox-exec` fallback.
func resolvedPtyClaimPath(workspace: String) -> String? {
    var seen = Set<String>()
    func consider(_ path: String) -> String? {
        guard seen.insert(path).inserted else { return nil }
        return usablePtyClaimPath(path, workspacePath: workspace)
    }
    func considerDirectory(_ directory: URL) -> String? {
        for suffix in ptyClaimPublishSuffixes {
            if let found = consider(directory.appendingPathComponent(suffix).path) {
                return found
            }
        }
        return nil
    }
    func walk(_ start: URL) -> String? {
        var directory = start
        for _ in 0..<8 {
            if let found = considerDirectory(directory) {
                return found
            }
            if let found = considerBuildTriples(directory, consider: consider) {
                return found
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }
    if let argv0 = CommandLine.arguments.first, IsolatedCommand.isAbsoluteExecutable(argv0) {
        if let found = walk(URL(fileURLWithPath: argv0).deletingLastPathComponent()) {
            return found
        }
    }
    for bundle in Bundle.allBundles {
        if let found = walk(bundle.bundleURL) {
            return found
        }
        if let executable = bundle.executableURL, let found = walk(executable.deletingLastPathComponent()) {
            return found
        }
    }
    // Checkout that compiled this file. An installed host finds the sibling
    // of argv0 first; this path is absent on a machine that does not have
    // the source tree.
    let compiled = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return walk(compiled)
}

/// `<.build>/<triple>/{debug,release}/rv-pty-claim` and the swiftbuild
/// layout `<.build>/out/Products/Debug/rv-pty-claim`. The triple is not a
/// fixed name, so it is not in the suffix list.
private func considerBuildTriples(
    _ directory: URL,
    consider: (String) -> String?
) -> String? {
    let build: URL
    if directory.lastPathComponent == ".build" {
        build = directory
    } else {
        build = directory.appendingPathComponent(".build", isDirectory: true)
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: build.path, isDirectory: &isDirectory),
        isDirectory.boolValue
    else {
        return nil
    }
    guard let children = try? FileManager.default.contentsOfDirectory(
        at: build,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        return nil
    }
    for child in children {
        for config in ["debug", "release", "Debug", "Release"] {
            if let found = consider(
                child.appendingPathComponent(config, isDirectory: true)
                    .appendingPathComponent(ptyClaimExecutableName).path
            ) {
                return found
            }
            if let found = consider(
                child.appendingPathComponent("Products", isDirectory: true)
                    .appendingPathComponent(config, isDirectory: true)
                    .appendingPathComponent(ptyClaimExecutableName).path
            ) {
                return found
            }
        }
    }
    return nil
}

/// True when `pid` is the foreground group of `slavePath`.
///
/// `TIOCGPGRP` on the master is the first read. The parent is not in the
/// child's session, so that ioctl can return `ENOTTY` even after the claim.
/// `proc_bsdinfo.e_tpgid` is the same foreground group, and `e_tdev` must be
/// this slave. A live child that is not that group still fails the launch.
private func foregroundGroupIsLeader(_ terminal: RuntimeTerminal, pid: pid_t) -> Bool {
    if let group = terminal.foregroundProcessGroup() {
        return group == pid
    }
    return sessionLeaderIsForeground(pid, slavePath: terminal.slavePath)
}

private func sessionLeaderIsForeground(_ pid: pid_t, slavePath: String) -> Bool {
    guard pid > 1 else { return false }
    var info = proc_bsdinfo()
    errno = 0
    let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
    let wrote = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
    guard wrote > 0 else { return false }
    guard info.pbi_pgid == UInt32(pid), Int(info.e_tpgid) == Int(pid) else { return false }
    guard info.e_tdev != 0 else { return false }
    var status = stat()
    guard slavePath.withCString({ stat($0, &status) == 0 }) else { return false }
    return info.e_tdev == UInt32(truncatingIfNeeded: status.st_rdev)
}

func usablePtyClaimPath(_ path: String, workspacePath: String) -> String? {
    guard IsolatedCommand.isAbsoluteExecutable(path) else { return nil }
    guard URL(fileURLWithPath: path).lastPathComponent == ptyClaimExecutableName else { return nil }
    guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
    guard let resolved = posixRealpath(path) else { return nil }
    guard IsolatedCommand.isAbsoluteExecutable(resolved),
        isFilesystemRoot(resolved) == false,
        URL(fileURLWithPath: resolved).lastPathComponent == ptyClaimExecutableName
    else {
        return nil
    }
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory)
    guard exists, isDirectory.boolValue == false else { return nil }
    let canonicalWorkspace = posixRealpath(workspacePath) ?? workspacePath
    if isFilesystemRoot(canonicalWorkspace)
        || isLookupInsideWorkspace(path, workspace: canonicalWorkspace)
        || isResolvedPath(resolved, atOrBeneath: canonicalWorkspace)
    {
        return nil
    }
    return resolved
}

private func exitStatus(_ status: Int32) -> Int32 {
    let waited = status & 0o177
    if waited == 0 {
        return (status >> 8) & 0xff
    }
    if waited != 0o177 {
        return waited
    }
    return status
}

/// C string vectors that live until `release()`.
private struct SpawnPointers {
    private var storage: [UnsafeMutablePointer<CChar>?]

    init(_ values: [String]) {
        storage = values.map { value in
            value.withCString { strdup($0) }
        }
        storage.append(nil)
    }

    func withPointers<T>(
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
    ) -> T {
        var values = storage
        return values.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else {
                preconditionFailure("spawn argument vector is empty")
            }
            return body(base)
        }
    }

    func release() {
        for pointer in storage {
            free(pointer)
        }
    }
}

#endif
