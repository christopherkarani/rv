#if os(macOS)
import Darwin
import Foundation
import RVDomain
import Synchronization

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
    // mount or execute. Provenance rides the profile value, not a text scan.
    guard profile.isContainedCompilerOutput else {
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

struct MountedSeatbeltOutcome {
    var result: Result<IsolatedRunResult, IsolationApplyError>
    /// Copy the volume back only after the in-sandbox handshake succeeded.
    /// The workspace owner reads this. A child exit does not publish.
    var publish: Bool
}

/// Cooperative stop for one runtime. The watch loop polls it.
///
/// Backed by the same flag type the executor installs, so `request`
/// also arms the one cancel clock at the request instant. The watch
/// thread installs `launchStopFlag`; without it, `spentSinceCancel`
/// and the shared clock read an empty thread dictionary there and
/// teardown silently arms fresh budgets.
final class RuntimeCancellation: Sendable {
    let launchStopFlag = CooperativeLaunchStop.Flag()

    func request() {
        launchStopFlag.cancel()
    }

    var isRequested: Bool {
        launchStopFlag.isSet
    }
}

private final class AdmissionReply: Sendable {
    private let value = Mutex<RuntimeAdmissionDecision?>(nil)

    func store(_ decision: RuntimeAdmissionDecision) {
        value.withLock { $0 = decision }
    }

    func current() -> RuntimeAdmissionDecision? {
        value.withLock { $0 }
    }
}

/// One Seatbelt process after `posix_spawn`. The watch loop owns its lifetime.
final class LiveSeatbeltChild: Sendable {
    let session: RuntimeSession
    let capability: RuntimeCapability
    let pid: pid_t
    let nonce: String
    let admission: RuntimeAdmissionSession
    /// Parent-side descriptors that must not appear in the child.
    private let retainedDescriptors: [Int32]
    let pty: RuntimeTerminal?
    let resources: RuntimeResourceManifest?
    private let handshakeIO = Mutex<HandshakeIO>(HandshakeIO())

    private struct HandshakeIO: Sendable {
        var read: Int32 = -1
        /// Nonce bytes already read while proving a dead leader. The watch
        /// must still see them; a pipe read is consuming.
        var preface = Data()
    }

    var handshakeRead: Int32 {
        get { handshakeIO.withLock { $0.read } }
        set { handshakeIO.withLock { $0.read = newValue } }
    }

    var handshakePreface: Data {
        get { handshakeIO.withLock { $0.preface } }
        set { handshakeIO.withLock { $0.preface = newValue } }
    }
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
        terminal: RuntimeTerminal?,
        resources: RuntimeResourceManifest?
    ) {
        self.session = session
        self.capability = capability
        self.pid = pid
        self.nonce = nonce
        self.admission = admission
        self.retainedDescriptors = parentDescriptors
        self.pty = terminal
        self.resources = resources
        self.handshakeRead = handshakeRead
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
        let fd = takeHandshakeRead()
        if fd >= 0 {
            close(fd)
        }
        admission.finish()
    }

    /// Takes the handshake fd exactly once, so concurrent teardown paths
    /// cannot close the same descriptor twice.
    func takeHandshakeRead() -> Int32 {
        handshakeIO.withLock { io in
            let fd = io.read
            io.read = -1
            return fd
        }
    }

    var terminalError: IsolationApplyError? {
        terminal.withLock { $0 }
    }

    /// Ask the watch thread to run one frame. Returns nil if a frame is
    /// already waiting or the watch does not answer. Frame routing into
    /// the session's legacy door; sensitive mediation needs its own door.
    func submitLegacy(_ frame: RuntimeActionFrame) -> RuntimeAdmissionDecision? {
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
        job.reply.store(admission.submitLegacy(.success(job.frame)))
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
        let fd = takeHandshakeRead()
        if fd >= 0 {
            close(fd)
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
    admission: RuntimeAdmissionConfiguration,
    egressProxyPort: Int? = nil,
    egressProxyCredential: EgressProxyCredential? = nil,
    host: HookHost? = nil,
    stagingAgent: DefinitionStagingTag? = nil,
    keychain: [(name: String, value: String)] = [],
    preparedEnvironment: [String]? = nil,
    cwdVerification: CwdCommitVerification? = nil
) -> Result<LiveSeatbeltChild, IsolationApplyError> {
    let first = spawnSeatbeltProcessBody(
        request,
        workspace: workspace,
        profile: profile,
        boundary: boundary,
        started: started,
        admission: admission,
        egressProxyPort: egressProxyPort,
        egressProxyCredential: egressProxyCredential,
        host: host,
        stagingAgent: stagingAgent,
        keychain: keychain,
        preparedEnvironment: preparedEnvironment,
        cwdVerification: cwdVerification
    )
    guard case .failure(.processSpawnFailed) = first else { return first }
    if blockingWorkIsCancelled() { return first }
    // One retry: pipe/fork pressure under parallel load fails a spawn a
    // few times per suite run, and the next attempt succeeds. The attempt
    // closes every descriptor it opened, so the retry starts clean, and
    // deterministic failures fail twice with the same error.
    usleep(100_000)
    if blockingWorkIsCancelled() { return first }
    return spawnSeatbeltProcessBody(
        request,
        workspace: workspace,
        profile: profile,
        boundary: boundary,
        started: started,
        admission: admission,
        egressProxyPort: egressProxyPort,
        egressProxyCredential: egressProxyCredential,
        host: host,
        stagingAgent: stagingAgent,
        keychain: keychain,
        preparedEnvironment: preparedEnvironment,
        cwdVerification: cwdVerification
    )
}

/// Map a request-scoped launch fault to the PTY-open stage it fails.
/// Non-PTY faults fail at their own gates, not here.
func terminalOpenFault(for fault: RuntimeSpawnFault?) -> TerminalOpenFault? {
    switch fault {
    case .openpt:
        return .master
    case .grant:
        return .grant
    case .unlock:
        return .unlock
    case .slave:
        return .slaveOpen
    case .spawn, .register, nil:
        return nil
    }
}

func spawnSeatbeltProcessBody(
    _ request: IsolatedLaunchRequest,
    workspace: String,
    profile: SeatbeltProfile,
    boundary: WorkspaceInodeBoundary,
    started: RuntimeSession,
    admission: RuntimeAdmissionConfiguration,
    egressProxyPort: Int? = nil,
    egressProxyCredential: EgressProxyCredential? = nil,
    host: HookHost? = nil,
    stagingAgent: DefinitionStagingTag? = nil,
    keychain: [(name: String, value: String)] = [],
    preparedEnvironment: [String]? = nil,
    cwdVerification: CwdCommitVerification? = nil
) -> Result<LiveSeatbeltChild, IsolationApplyError> {
    // Provenance rides the profile value, not a text scan (same gate as
    // `superviseSeatbelt` above).
    guard profile.isContainedCompilerOutput else {
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
    guard relocateDescriptor(&readEnd, above: 16) else {
        return .failure(.processSpawnFailed)
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
        guard
            let opened = RuntimeTerminal.open(
                rows: rows,
                columns: columns,
                openFault: terminalOpenFault(for: request.spawnFault)
            )
        else {
            return .failure(.processSpawnFailed)
        }
        terminal = opened
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
    let handshakeScript = spawnHandshakeScript
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
    // Step 8 (F2): only the definition-derived staging tag selects
    // credentials. `host` is routing/metadata and never falls back into
    // selection — a nil tag stages unfiltered entries only.
    let agentName = stagingAgent?.rawValue
    if let resources = request.resources {
        switch resources.stage(forAgent: agentName) {
        case .success:
            break
        case .failure(let staging):
            return .failure(.resourceStagingFailed(staging.detail))
        }
    } else if case .pseudoTerminal = request.io {
        // Profile-less PTY shells point TMPDIR at the workspace-local cage
        // dir. Best-effort like the pre-profile staging: the shell reports
        // its own failure if the directory cannot be created.
        try? FileManager.default.createDirectory(
            atPath: "\(workspace)/\(ContainedCagePaths.tmpSubpath)",
            withIntermediateDirectories: true
        )
    }
    var resourceStageHandedOff = false
    defer { if !resourceStageHandedOff { request.resources?.remove() } }
    let agentBin = request.legacyAgentIntegration ? AgentBin.installedDirectory() : nil
    let productive =
        request.productive
        ?? resolveProductiveWorkspace(
            workspacePath: workspace,
            agentBin: agentBin,
            credentialDelivery: request.credentialDelivery
        )
    if request.legacyAgentIntegration, case .pseudoTerminal = request.io {
        // Stage into the RV-managed home; the degraded workspace home
        // keeps staging working when no managed home exists. Credential
        // symlinks additionally require explicit opt-in on the request.
        stageAgentHomes(
            cageHome: productive.developerHome?.home ?? workspace,
            credentialDelivery: request.credentialDelivery
        )
    }
    // A retained prepared environment bypasses recomputation entirely:
    // dispatch executes exactly what preparation froze, byte for byte —
    // except the proxy binding, which never freezes: preparation mints
    // no runtime, so it mints no proxy either, and the live per-runtime
    // port (plus credential) is substituted at dispatch instead
    // (`restampEgressProxyVariables`, GUD-2-6). Nil preserves the legacy
    // behavior of resolving live at spawn.
    let environment: [String]
    if let frozen = preparedEnvironment {
        environment = restampEgressProxyVariables(
            frozen, port: egressProxyPort, credential: egressProxyCredential
        )
    } else {
        environment = containedRuntimeEnvironment(
            workspace: workspace,
            io: request.io,
            agentBin: agentBin,
            resources: request.resources,
            egressProxyPort: egressProxyPort,
            egressProxyCredential: egressProxyCredential,
            keychain: keychain,
            productive: productive,
            credentialDelivery: request.credentialDelivery
        )
    }
    let argv = SpawnPointers(arguments)
    let envp = SpawnPointers(environment)
    defer {
        argv.release()
        envp.release()
    }

    // Request-scoped: a global flag here would fail parallel sibling
    // launches that share this process.
    if request.spawnFault == .spawn {
        return .failure(.processSpawnFailed)
    }

    // Redemption cwd verification, immediately before `posix_spawn`: the
    // live workspace must still be the retained identity. No observable
    // side effect sits between this check and the spawn, so a swap here
    // must win blind at microsecond precision — and must also win the
    // post-spawn check below to survive.
    if let cwdVerification,
        verifyLiveCwdIdentity(
            policyWorkspacePath: cwdVerification.policyWorkspacePath,
            expected: cwdVerification.expected
        ) == false {
        return .failure(.workspaceInodeBoundaryFailed)
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
    // Doubly nested withPointers yields Int??; unwrap both levels
    // explicitly so inner nil fails closed without relying on
    // Optional-promoted ==.
    guard let spawnResult, let spawnStatus = spawnResult, spawnStatus == 0, pid > 1 else {
        return .failure(.processSpawnFailed)
    }
    // The child is START_SUSPENDED: it has chdir'd but never run. Re-verify
    // the cwd before it resumes: a swap that landed between the pre-spawn
    // check and the chdir and is still in place fails here, and the
    // never-started child is reaped without effects. Only a swap-in and
    // swap-back both landing inside this blind microsecond sandwich can
    // pass — the residual this path-based chdir cannot close without an
    // FD-pinned spawn, which remains future hardening work.
    if let cwdVerification,
        verifyLiveCwdIdentity(
            policyWorkspacePath: cwdVerification.policyWorkspacePath,
            expected: cwdVerification.expected
        ) == false {
        terminateSession(pgid: pid, also: [pid])
        _ = waitUntilSessionIsDead(pgid: pid, also: [pid])
        return .failure(.workspaceInodeBoundaryFailed)
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
            profileIsContainedCompilerOutput: profile.isContainedCompilerOutput,
            workspacePath: workspace,
            sessionLeader: pid,
            egressProxyPort: egressProxyPort,
            productive: productive
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
        terminal: terminal,
        resources: request.resources
    )
    handedOff = true
    resourceStageHandedOff = true
    return .success(child)
}

/// Workspace-local fallback for a PTY launch with no resource profile.
/// Staged launches use the manifest's private tmp; one-shot launches keep
/// the byte-identical workspace TMPDIR. Without this, profile-less shells
/// would scatter temp files across the workspace root.
enum ContainedCagePaths {
    static let tmpSubpath = ".rv-cage/tmp"
}

/// Cage environment for one spawn: the projected host environment plus
/// runtime-owned values.
///
/// The defaults are effectful: a nil host reads the live process
/// environment, and a nil productive re-resolves the workspace (live
/// probes plus idempotent `ensure`, and possibly a `git` spawn for
/// commit-identity seeding). The spawn path passes prepare-time facts
/// explicitly so each launch resolves once.
func containedRuntimeEnvironment(
    workspace: String,
    io: IsolatedIO,
    agentBin: String? = nil,
    resources: RuntimeResourceManifest? = nil,
    egressProxyPort: Int? = nil,
    egressProxyCredential: EgressProxyCredential? = nil,
    hostEnvironment: [String: String]? = nil,
    keychain: [(name: String, value: String)] = [],
    productive: ProductiveWorkspaceResolution? = nil,
    probe: ContainedPATHProbe = .live,
    credentialDelivery: ContainedCredentialDelivery = .closed
) -> [String] {
    let host = hostEnvironment ?? ProcessInfo.processInfo.environment
    let context =
        productive
        ?? resolveProductiveWorkspace(
            workspacePath: workspace,
            hostEnvironment: host,
            agentBin: agentBin,
            probe: probe,
            credentialDelivery: credentialDelivery
        )
    let cageHome = context.developerHome?.home ?? workspace
    let cageTmp = context.developerHome.map { $0.tmp + "/" } ?? workspace
    // Projected host context first. Runtime-managed names never appear
    // here, so the owned values appended below cannot collide.
    var values = ContainedEnvironmentPolicy.project(host: host)
    values.append(("PATH", context.pathValue))
    if values.allSatisfy({ $0.0 != "LANG" }) {
        values.append(("LANG", "C"))
    }
    if values.allSatisfy({ $0.0 != "LC_ALL" }) {
        values.append(("LC_ALL", "C"))
    }
    values.append(("HOME", cageHome))
    values.append(("TMPDIR", cageTmp))
    values.append(("TEMP", cageTmp))
    values.append(("TMP", cageTmp))
    if let developerHome = context.developerHome {
        values.append(("XDG_CACHE_HOME", developerHome.cache))
        values.append(("XDG_CONFIG_HOME", "\(cageHome)/.config"))
        values.append(("XDG_DATA_HOME", "\(cageHome)/.local/share"))
        values.append(("XDG_STATE_HOME", "\(cageHome)/.local/state"))
        // SwiftPM honors this override for manifest and target module
        // caches. Without it the compiler writes to the confstr user
        // cache directory, which no sandbox can redirect and which must
        // stay unshared with the host.
        values.removeAll { $0.0 == "SWIFTPM_MODULECACHE_OVERRIDE" }
        values.append(("SWIFTPM_MODULECACHE_OVERRIDE", "\(developerHome.cache)/swift-modulecache"))
    }
    values.append(("PWD", workspace))
    if let candidate = host["SHELL"], isUsableAbsolutePath(candidate),
        probe.isExecutable(candidate)
    {
        values.append(("SHELL", candidate))
    } else {
        values.append(("SHELL", "/bin/zsh"))
    }
    // One entry per name: the projection may carry host values the runtime
    // overrides below.
    values.removeAll { $0.0 == "TERM" || $0.0 == "CLICOLOR" }
    switch io {
    case .pseudoTerminal:
        values.append(("TERM", TerminalStreamLimits.supportedTerm))
        // The sandbox cannot see user dotfiles, so interactive shells
        // start bare. Standard color output only; zsh ignores an inherited
        // PS1, so the prompt stays its default unless the user creates a
        // cage-home .zshrc.
        values.append(("CLICOLOR", "1"))
    case .discard, .inherit:
        if let term = host["TERM"], term.isEmpty == false,
            ContainedEnvironmentPolicy.isSaneValue(term)
        {
            values.append(("TERM", term))
        }
    }
    if agentBin != nil {
        // The cage cannot manage host services or rewrite installs, so
        // agent self-update and service-ensure steps stay off.
        let owned: Set<String> = [
            "OCX_SHIM_BYPASS", "MUSE_NO_AUTO_UPDATE", "DISABLE_AUTOUPDATER",
        ]
        values.removeAll { owned.contains($0.0) }
        values.append(("OCX_SHIM_BYPASS", "1"))
        values.append(("MUSE_NO_AUTO_UPDATE", "1"))
        values.append(("DISABLE_AUTOUPDATER", "1"))
        // F2 default closed: host API keys stay stripped unless the
        // operator explicitly opts legacy keys in. Gateway routing needs
        // no re-injection: no gatewayPassthrough name matches a denied
        // token, infix, prefix, or exact rule, so the projection above is
        // its single delivery path — a second, weaker check can no longer
        // smuggle through a value the projection refused.
        if credentialDelivery.legacyAPIKeys {
            for name in AgentHomeStaging.apiKeyPassthrough {
                if let value = host[name],
                    ContainedEnvironmentPolicy.isSaneValue(value)
                {
                    values.append((name, value))
                }
            }
        }
        // Public constant, never a live key: gateway-routed runs work with
        // no host key configured, and direct-endpoint runs with it fail
        // closed at the provider (401), same as having no key.
        if values.allSatisfy({ $0.0 != "ANTHROPIC_API_KEY" }) {
            values.append(("ANTHROPIC_API_KEY", AgentHomeStaging.anthropicGatewayPlaceholder))
        }
    }
    // Per-runtime proxy binding (CON-2-3, PAT-2-5): this runtime's
    // loopback port, plus its supervisor-minted credential as URL
    // userinfo when one was minted. Omitted on a bad or nil port: without
    // a proxy the cage has no route out at all (fail closed).
    if let port = egressProxyPort, (1...65535).contains(port) {
        let proxy = egressProxyURL(port: port, credential: egressProxyCredential)
        values.append(("HTTPS_PROXY", proxy))
        values.append(("HTTP_PROXY", proxy))
        values.append(("https_proxy", proxy))
        values.append(("http_proxy", proxy))
        // Loopback bypasses the proxy when the client honors it (the
        // seatbelt rule admits it directly); the proxy also relays
        // loopback absolute-URI requests for clients that do not.
        values.append(("NO_PROXY", "localhost,127.0.0.1,::1"))
        values.append(("no_proxy", "localhost,127.0.0.1,::1"))
    }
    return addingKeychainEnvironment(
        addingResourceEnvironment(
            values,
            workspace: workspace,
            io: io,
            resources: resources,
            hostEnvironment: hostEnvironment
        ),
        keychain: keychain
    ).map { "\($0.0)=\($0.1)" }
}

/// Per-runtime proxy URL for one cage environment: the runtime's
/// loopback port plus, when the supervisor minted one for this runtime,
/// the credential as URL userinfo. Stock HTTP clients send `*_PROXY`
/// userinfo as Basic `Proxy-Authorization`, which the credentialed proxy
/// authenticates against that runtime's grant alone
/// (`EgressProxy.proxyCredentialToken`); a sibling runtime holds a
/// different token and is judged against its own grant. This is
/// credential separation, not secrecy: the token rides the process
/// environment, and the production (coarse sysctl-read) profile lets a
/// same-uid sibling read it via KERN_PROCARGS2. Today every grant is
/// the same `.publicHTTPS` policy, so harvesting a token grants no
/// wider egress — but per-runtime policy differentiation must not ship
/// until the per-MIB/pidinfo posture (or a dedicated uid) makes the
/// token unreadable across cages. A missing or non-userinfo-safe
/// credential stamps the port-only shape instead: open-mode proxies keep
/// working unchanged, while credentialed proxies answer 407
/// (`denied-credential`, fail closed) rather than admitting.
private func egressProxyURL(port: Int, credential: EgressProxyCredential?) -> String {
    guard let raw = credential?.rawValue, isEmbeddableProxyCredential(raw) else {
        return "http://127.0.0.1:\(port)"
    }
    return "http://\(raw)@127.0.0.1:\(port)"
}

/// Tokens safe to embed as proxy-URL userinfo verbatim: non-empty,
/// short, RFC 3986 unreserved characters only. Minted credentials are
/// lowercase hex and always pass. Anything else — notably `@`, `/`,
/// `:`, `?`, `#`, `%`, whitespace, or non-ASCII — would rewrite the URL
/// authority or smuggle a second field, so it falls back to the
/// port-only shape instead of percent-encoding: there is no decode gap
/// because the proxy compares the exact presented token.
private func isEmbeddableProxyCredential(_ raw: String) -> Bool {
    guard raw.isEmpty == false, raw.utf8.count <= 256 else { return false }
    return raw.allSatisfy { character in
        guard let ascii = character.asciiValue else { return false }
        return ascii.isEmbeddableProxyCredentialByte
    }
}

private extension UInt8 {
    var isEmbeddableProxyCredentialByte: Bool {
        switch self {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F, 0x7E:
            return true
        default:
            return false
        }
    }
}

/// GUD-2-6 re-stamp rule: substitute the live per-runtime proxy binding
/// into a retained (frozen) environment at dispatch.
///
/// Preparation freezes with no proxy (`egressProxyPort: nil`: no
/// runtime exists yet, so no proxy is minted), and dispatch executes
/// what preparation froze — except the proxy binding, which belongs to
/// the live runtime, not the frozen bytes. Rotation mid-preparation is
/// safe by construction: frozen proxy entries (a stale port, a stale
/// credential, a future prepare change) are stripped and the live
/// values stamped. A nil or invalid port stamps nothing: without a
/// proxy the cage has no route out at all (fail closed). Non-proxy
/// entries pass through byte for byte, in order.
func restampEgressProxyVariables(
    _ frozen: [String],
    port: Int?,
    credential: EgressProxyCredential? = nil
) -> [String] {
    var kept = frozen.filter { entry in
        guard let mark = entry.firstIndex(of: "=") else { return true }
        return restampedProxyNames.contains(String(entry[..<mark]).uppercased()) == false
    }
    guard let port, (1...65535).contains(port) else { return kept }
    let proxy = egressProxyURL(port: port, credential: credential)
    kept.append("HTTPS_PROXY=\(proxy)")
    kept.append("HTTP_PROXY=\(proxy)")
    kept.append("https_proxy=\(proxy)")
    kept.append("http_proxy=\(proxy)")
    kept.append("NO_PROXY=localhost,127.0.0.1,::1")
    kept.append("no_proxy=localhost,127.0.0.1,::1")
    return kept
}

/// Proxy-variable names the re-stamp owns (uppercased for a
/// case-insensitive match): the six the live path stamps, plus
/// `ALL_PROXY`, which the live path never emits but a stale or foreign
/// frozen entry must not smuggle past dispatch as a second route.
private let restampedProxyNames: Set<String> = [
    "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY",
]

private func addingResourceEnvironment(
    _ values: [(String, String)],
    workspace: String,
    io: IsolatedIO,
    resources: RuntimeResourceManifest?,
    hostEnvironment: [String: String]?
) -> [(String, String)] {
    var values = values
    var present = Set(values.map(\.0))
    if let resources {
        values.removeAll { $0.0 == "HOME" || $0.0 == "TMPDIR" || $0.0 == "TEMP" || $0.0 == "TMP" }
        values.append(("HOME", resources.privateHome))
        values.append(("TMPDIR", resources.tmp))
        values.append(("TEMP", resources.tmp))
        values.append(("TMP", resources.tmp))
        if let pathIndex = values.firstIndex(where: { $0.0 == "PATH" }) {
            values[pathIndex].1 = "\(resources.bin):\(values[pathIndex].1)"
        }
        present = Set(values.map(\.0))
    } else if case .pseudoTerminal = io {
        values.removeAll { $0.0 == "TMPDIR" || $0.0 == "TEMP" || $0.0 == "TMP" }
        let tmpdir = "\(workspace)/\(ContainedCagePaths.tmpSubpath)"
        values.append(("TMPDIR", tmpdir))
        values.append(("TEMP", tmpdir))
        values.append(("TMP", tmpdir))
        present = Set(values.map(\.0))
    }
    let host = hostEnvironment ?? ProcessInfo.processInfo.environment
    for entry in resources?.profile.environment ?? [] {
        let value: String?
        switch entry.resolvedSource {
        case .hostVariable(let variable):
            value = host[variable]
        case .literal(let literal):
            value = literal
        case nil:
            continue
        }
        guard let value, !value.contains("\0"), value.utf8.count <= 8_192 else { continue }
        guard present.insert(entry.name).inserted else { continue }
        values.append((entry.name, value))
    }
    return values
}

private func addingKeychainEnvironment(
    _ values: [(String, String)],
    keychain: [(name: String, value: String)]
) -> [(String, String)] {
    var values = values
    // One entry per name: `execve` lookup returns the first match, so
    // duplicates would be dead entries that only confuse auditors. Profile
    // credentials replace an ambient host value of the same name — a host
    // copy winning would hand the cage the real key instead of the staged
    // one. Runtime-owned and proxy names are never replaced.
    let present = Set(values.map(\.0))
    var staged = Set<String>()
    for entry in keychain {
        // Cage-bound hardening: keychain entries are operator opt-in — the
        // only production caller reads them from the selected resource
        // profile (`WorkspaceSessionSupervisor.spawn`, via
        // `keychainEnvironment(forAgent:reader:)`), and an empty profile
        // section injects nothing — but they still cannot claim
        // runtime-managed names, invalid names, or insane values.
        // Secret-shaped names (`*_KEY`, `*_TOKEN`, ...) stay allowed: the
        // generic projection never sees this path, and delivering them is
        // the feature's purpose. A staged name replaces an ambient host
        // value of the same name so the cage receives the staged secret.
        guard ContainedEnvironmentPolicy.isValidName(entry.name),
            ContainedEnvironmentPolicy.isSaneValue(entry.value),
            entry.value.utf8.count <= 8_192,
            ContainedEnvironmentPolicy.isManagedByRuntime(entry.name) == false,
            entry.name.uppercased().hasSuffix("_PROXY") == false,
            staged.insert(entry.name).inserted
        else { continue }
        if present.contains(entry.name) {
            values.removeAll { $0.0 == entry.name }
        }
        values.append((entry.name, entry.value))
    }
    return values
}

func watchSeatbeltProcess(
    _ live: LiveSeatbeltChild,
    stop: RuntimeCancellation,
    onDeathObserved: (() -> Void)? = nil
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
        drain: { live.drainPending() },
        onDeathObserved: onDeathObserved
    )
    if outcome.cancelled {
        // The clock starts at cancel, which is before this poll. The poll
        // stops at what that clock has left. It does not run its own two
        // seconds and then let detach arm a fresh 7.75s.
        CooperativeLaunchStop.noteCancel()
    }
    let sessionBudget = outcome.cancelled
        ? DiskImageCancelBudget.boundedWait(
            spentSinceCancel: CooperativeLaunchStop.spentSinceCancel(),
            cap: DiskImageCancelBudget.sessionDeathWait
        )
        : DiskImageCancelBudget.sessionDeathWait
    let dead = waitUntilSessionIsDead(
        pgid: live.pid,
        also: outcome.recordedPIDs.union([live.pid]),
        budget: sessionBudget
    )
    if dead { live.resources?.remove() }
    let mounted: MountedSeatbeltOutcome
    switch seatbeltWatchDisposition(cancelled: outcome.cancelled, leaderDead: dead) {
    case .cancelled:
        // The leader is dead. Publish only when the handshake completed.
        // Teardown still has to unmount; a mounted volume is not .cancelled.
        mounted = MountedSeatbeltOutcome(
            result: .failure(.cancelled),
            publish: outcome.established
        )
    case .leaderStillAlive:
        // Cancel was requested and the leader is still alive. This is not
        // a finished cancel, and it is not a lifetime miss.
        mounted = MountedSeatbeltOutcome(
            result: .failure(.workspaceInodeBoundaryFailed),
            publish: false
        )
    case .lifetimeBoundaryFailed:
        mounted = MountedSeatbeltOutcome(result: .failure(.lifetimeBoundaryFailed), publish: false)
    case .proceed:
        if outcome.established, let status = outcome.status {
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
    }
    if case .failure(let error) = mounted.result {
        live.recordTerminal(error)
    } else {
        live.recordTerminal(nil)
    }
    live.pty?.finish(status: outcome.status)
    let handshakeFD = live.takeHandshakeRead()
    if handshakeFD >= 0 {
        close(handshakeFD)
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
    drain: () -> Void,
    onDeathObserved: (() -> Void)? = nil
) -> SeatbeltWaitOutcome {
    var outcome = SeatbeltWaitOutcome()
    let expected = Data(nonce.utf8)
    var matcher = HandshakePrefixMatcher(expected: expected, preface: preface)
    var recorded: Set<pid_t> = [root]
    while true {
        if blockingWorkIsCancelled() || stop.isRequested {
            outcome.cancelled = true
            // Arm the shared clock before the leader reap. Detach later
            // adopts that clock instead of starting 7.75s from scratch.
            CooperativeLaunchStop.noteCancel()
            admission.finish()
        }
        if outcome.established == false {
            if matcher.append(readAvailable(readEnd, limit: expected.count)) {
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
            // Definitive leader death is session death: this branch kills
            // the group next, so authority ends here, before the reap and
            // group-drain tail — mirroring cancel(), where authority dies
            // before the reap completes. Fires at most once: this branch
            // returns. No fire on bare cancel: the leader may still be
            // alive, and cancel() already revoked synchronously.
            if rootGone {
                onDeathObserved?()
            }
            recorded.formUnion(visibleSessionPIDs(root: root))
            terminateSession(pgid: root, also: recorded)
            if outcome.established == false {
                if matcher.append(readAvailable(readEnd, limit: expected.count)) {
                    outcome.established = true
                    onEstablished()
                }
            }
            if outcome.status == nil {
                let budget = outcome.cancelled
                    ? DiskImageCancelBudget.boundedWait(
                        spentSinceCancel: CooperativeLaunchStop.spentSinceCancel(),
                        cap: DiskImageCancelBudget.leaderReap
                    )
                    : DiskImageCancelBudget.leaderReap
                outcome.status = reapLeaderStatus(root, budget: budget)
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
        guard relocateDescriptor(&nullFD, above: 16) else { return false }
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
        CooperativeLaunchStop.noteCancel()
        let budget = DiskImageCancelBudget.boundedWait(
            spentSinceCancel: CooperativeLaunchStop.spentSinceCancel(),
            cap: DiskImageCancelBudget.sessionDeathWait
        )
        let dead = waitUntilSessionIsDead(pgid: child.pid, also: [child.pid], budget: budget)
        if seatbeltWatchDisposition(cancelled: true, leaderDead: dead) == .cancelled {
            return .failure(.cancelled)
        }
        return .failure(.workspaceInodeBoundaryFailed)
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
/// `budget` is the leader-reap cap, already shortened by time spent since
/// cancel so this poll cannot run and then leave a full detach clock.
private func reapLeaderStatus(
    _ pid: pid_t,
    budget: TimeInterval = DiskImageCancelBudget.leaderReap
) -> Int32? {
    let deadline = Date().addingTimeInterval(max(0, budget))
    while true {
        var status: Int32 = 0
        let waited = waitpid(pid, &status, WNOHANG)
        if waited == pid {
            return exitStatus(status)
        }
        if waited < 0, errno == ECHILD {
            return nil
        }
        if Date() >= deadline { return nil }
        usleep(10_000)
    }
}

func waitUntilSessionIsDead(
    pgid: pid_t,
    also pids: Set<pid_t>,
    reap: Bool = true,
    budget: TimeInterval = DiskImageCancelBudget.sessionDeathWait
) -> Bool {
    let deadline = Date().addingTimeInterval(max(0, budget))
    // Always one reap+terminate pass, even at a zero budget: a leader
    // that already took SIGKILL is a zombie until `waitpid`, and the
    // kill-based checks below read a zombie as alive.
    while true {
        if reap {
            var status: Int32 = 0
            _ = waitpid(pgid, &status, WNOHANG)
        }
        terminateSession(pgid: pgid, also: pids)
        let gone = pids.allSatisfy { processIsGone($0) || (reap == false && sessionLeaderHasExited($0)) }
        if processGroupIsEmpty(pgid), gone {
            return true
        }
        if Date() >= deadline { break }
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
    // Same fail-closed rule as the Landlock exec check: a stopped
    // realpath leaves the workspace spelling's target unknown.
    let canonicalWorkspace: String
    switch posixRealpathRead(workspacePath) {
    case .path(let resolvedWorkspace):
        canonicalWorkspace = resolvedWorkspace
    case .stopped:
        return nil
    case .unresolved:
        canonicalWorkspace = workspacePath
    }
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

#endif
