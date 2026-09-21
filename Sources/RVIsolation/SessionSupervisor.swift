#if os(macOS)
import Darwin
import Foundation
import RVDomain

private let seatbeltHandshakeScript =
    "printf %s \"$1\" >&3 || exit 127; exec 3>&-; shift; exec \"$@\""

/// Seatbelt launch: persist the session, spawn into an RV process group,
/// read a handshake byte string that only the in-sandbox wrapper can write,
/// then signal the group and wait until it is empty.
func superviseSeatbelt(
    _ request: IsolatedLaunchRequest,
    host: HookHost?,
    sessionStore: RuntimeSessionStore
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
    if Task.isCancelled {
        return .failure(.cancelled)
    }
    let started = RuntimeSession(
        id: RuntimeSessionID(),
        host: host,
        workspace: directory,
        mode: request.plan.mode,
        backend: .seatbelt,
        startedAt: Date(),
        child: nil
    )
    switch sessionStore.append(started) {
    case .failure(let error):
        return .failure(error)
    case .success:
        break
    }
    if Task.isCancelled {
        return .failure(.cancelled)
    }

    let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    var pipeFDs: [Int32] = [0, 0]
    let pipeResult = pipeFDs.withUnsafeMutableBufferPointer { buffer in
        pipe(buffer.baseAddress)
    }
    guard pipeResult == 0 else {
        return .failure(.processSpawnFailed)
    }
    let readEnd = pipeFDs[0]
    let writeEnd = pipeFDs[1]
    defer { close(readEnd) }

    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else {
        close(writeEnd)
        return .failure(.lifetimeBoundaryFailed)
    }
    defer { posix_spawnattr_destroy(&attributes) }
    let flags = Int16(POSIX_SPAWN_SETPGROUP)
    guard posix_spawnattr_setflags(&attributes, flags) == 0,
        posix_spawnattr_setpgroup(&attributes, 0) == 0
    else {
        close(writeEnd)
        return .failure(.lifetimeBoundaryFailed)
    }

    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else {
        close(writeEnd)
        return .failure(.processSpawnFailed)
    }
    defer { posix_spawn_file_actions_destroy(&actions) }
    let chdirResult = workspace.withCString { path in
        posix_spawn_file_actions_addchdir(&actions, path)
    }
    guard chdirResult == 0 else {
        close(writeEnd)
        return .failure(.processSpawnFailed)
    }
    var nullFD: Int32 = -1
    if request.io == .discard {
        nullFD = open("/dev/null", O_RDWR | O_CLOEXEC)
        guard nullFD >= 0,
            posix_spawn_file_actions_adddup2(&actions, nullFD, STDIN_FILENO) == 0,
            posix_spawn_file_actions_adddup2(&actions, nullFD, STDOUT_FILENO) == 0,
            posix_spawn_file_actions_adddup2(&actions, nullFD, STDERR_FILENO) == 0,
            posix_spawn_file_actions_addclose(&actions, nullFD) == 0
        else {
            if nullFD >= 0 { close(nullFD) }
            close(writeEnd)
            return .failure(.processSpawnFailed)
        }
    }
    guard installHandshakeActions(&actions, readEnd: readEnd, writeEnd: writeEnd) else {
        if nullFD >= 0 { close(nullFD) }
        close(writeEnd)
        return .failure(.processSpawnFailed)
    }

    var arguments = [
        IsolationBackends.sandboxExecPath,
        "-p",
        profile.source,
        "/bin/sh",
        "-c",
        seatbeltHandshakeScript,
        "rv-seatbelt",
        nonce,
        request.command.executable,
    ]
    arguments.append(contentsOf: request.command.arguments)
    let environment = [
        "PATH=/usr/bin:/bin",
        "LANG=C",
        "LC_ALL=C",
        "HOME=\(workspace)",
        "TMPDIR=\(workspace)",
    ]
    let argv = SpawnPointers(arguments)
    let envp = SpawnPointers(environment)
    defer {
        argv.release()
        envp.release()
    }

    var pid: pid_t = 0
    let spawnResult = argv.withPointers { argvPointer in
        envp.withPointers { envPointer in
            posix_spawn(
                &pid,
                IsolationBackends.sandboxExecPath,
                &actions,
                &attributes,
                argvPointer,
                envPointer
            )
        }
    }
    if nullFD >= 0 { close(nullFD) }
    close(writeEnd)
    guard spawnResult == 0, pid > 1 else {
        return .failure(.processSpawnFailed)
    }
    // The wait loop polls this fd. A blocking read would ignore cancellation
    // until the child writes or exits, so a failed flag change cannot continue.
    let flagsNow = fcntl(readEnd, F_GETFL)
    guard flagsNow >= 0, fcntl(readEnd, F_SETFL, flagsNow | O_NONBLOCK) >= 0 else {
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

    let outcome = waitForSeatbeltSession(root: pid, readEnd: readEnd, nonce: nonce)
    let dead = waitUntilSessionIsDead(pgid: pid, also: outcome.recordedPIDs.union([pid]))
    guard dead else {
        return .failure(.lifetimeBoundaryFailed)
    }
    if outcome.cancelled {
        return .failure(.cancelled)
    }
    guard outcome.established, let status = outcome.status else {
        return .failure(.seatbeltNotEstablished)
    }
    guard let established = EstablishedIsolation(mode: request.plan.mode, family: .seatbelt) else {
        return .failure(.backendMismatch)
    }
    return .success(
        IsolatedRunResult(
            established: established,
            exitStatus: status,
            session: started.withChild(pid: pid)
        )
    )
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
    nonce: String
) -> SeatbeltWaitOutcome {
    var outcome = SeatbeltWaitOutcome()
    var handshake = Data()
    let expected = Data(nonce.utf8)
    var recorded: Set<pid_t> = [root]
    while true {
        if Task.isCancelled {
            outcome.cancelled = true
        }
        if outcome.established == false {
            handshake.append(contentsOf: readAvailable(readEnd, limit: expected.count))
            if handshake.starts(with: expected), handshake.count >= expected.count {
                outcome.established = true
            }
        }
        recorded.formUnion(visibleSessionPIDs(root: root))
        var status: Int32 = 0
        let waited = waitpid(root, &status, WNOHANG)
        if waited == root {
            outcome.status = exitStatus(status)
        }
        let rootGone = waited == root || (waited < 0 && errno == ECHILD && outcome.status != nil)
        if outcome.cancelled || rootGone {
            recorded.formUnion(visibleSessionPIDs(root: root))
            terminateSession(pgid: root, also: recorded)
            if outcome.established == false {
                handshake.append(contentsOf: readAvailable(readEnd, limit: expected.count))
                if handshake.starts(with: expected), handshake.count >= expected.count {
                    outcome.established = true
                }
            }
            if outcome.status == nil {
                var late: Int32 = 0
                if waitpid(root, &late, WNOHANG) == root {
                    outcome.status = exitStatus(late)
                }
            }
            outcome.recordedPIDs = recorded
            return outcome
        }
        usleep(10_000)
    }
}

private func installHandshakeActions(
    _ actions: inout posix_spawn_file_actions_t?,
    readEnd: Int32,
    writeEnd: Int32
) -> Bool {
    if writeEnd != 3 {
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
    return true
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

private func terminateSession(pgid: pid_t, also pids: Set<pid_t>) {
    if pgid > 1 {
        _ = kill(-pgid, SIGKILL)
    }
    for pid in pids where pid > 1 {
        _ = kill(pid, SIGKILL)
    }
}

private func waitUntilSessionIsDead(pgid: pid_t, also pids: Set<pid_t>) -> Bool {
    for _ in 0..<200 {
        var status: Int32 = 0
        _ = waitpid(pgid, &status, WNOHANG)
        terminateSession(pgid: pgid, also: pids)
        if processGroupIsEmpty(pgid), pids.allSatisfy({ processIsGone($0) }) {
            return true
        }
        usleep(10_000)
    }
    return processGroupIsEmpty(pgid) && pids.allSatisfy { processIsGone($0) }
}

private func processGroupIsEmpty(_ pgid: pid_t) -> Bool {
    guard pgid > 1 else { return false }
    return kill(-pgid, 0) == -1 && errno == ESRCH
}

private func processIsGone(_ pid: pid_t) -> Bool {
    guard pid > 1 else { return true }
    if kill(pid, 0) == 0 {
        return false
    }
    return errno == ESRCH
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
