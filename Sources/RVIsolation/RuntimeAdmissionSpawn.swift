#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import Synchronization

enum RuntimeAdmissionDescriptors {
    /// Child writes admission requests here. The handshake pipe stays on fd 3
    /// and is closed before the payload runs.
    static let request: Int32 = 4
    /// Child reads the grant and responses here.
    static let response: Int32 = 5
}

/// Pipe ends for one runtime. The child receives only `requestWrite` and
/// `responseRead`, duplicated onto fds 4 and 5. RV keeps the other two.
struct RuntimeAdmissionPipes {
    var requestRead: Int32 = -1
    var requestWrite: Int32 = -1
    var responseRead: Int32 = -1
    var responseWrite: Int32 = -1

    mutating func open() -> Bool {
        var request: [Int32] = [-1, -1]
        var response: [Int32] = [-1, -1]
        let requestOK = request.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return pipe(base)
        }
        let responseOK = response.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return pipe(base)
        }
        guard requestOK == 0, responseOK == 0 else {
            for fd in request + response where fd >= 0 { close(fd) }
            return false
        }
        requestRead = request[0]
        requestWrite = request[1]
        responseRead = response[0]
        responseWrite = response[1]
        let ends = [requestRead, requestWrite, responseRead, responseWrite]
        guard ends.allSatisfy({ fcntl($0, F_SETFD, FD_CLOEXEC) >= 0 }) else {
            closeRemaining()
            return false
        }
        guard relocate(atLeast: 16) else {
            closeRemaining()
            return false
        }
        // A payload that exits without reading must not raise SIGPIPE in RV.
        #if os(macOS)
        guard fcntl(responseWrite, F_SETNOSIGPIPE, 1) >= 0 else {
            closeRemaining()
            return false
        }
        #endif
        return true
    }

    mutating func closeRemaining() {
        for fd in [requestRead, requestWrite, responseRead, responseWrite] where fd >= 0 {
            close(fd)
        }
        requestRead = -1
        requestWrite = -1
        responseRead = -1
        responseWrite = -1
    }

    private mutating func relocate(atLeast floor: Int32) -> Bool {
        relocate(&requestRead, floor) && relocate(&requestWrite, floor)
            && relocate(&responseRead, floor) && relocate(&responseWrite, floor)
    }

    private func relocate(_ fd: inout Int32, _ floor: Int32) -> Bool {
        guard fd >= 0 else { return false }
        if fd >= floor { return true }
        let moved = fcntl(fd, F_DUPFD_CLOEXEC, floor)
        guard moved >= 0 else { return false }
        close(fd)
        fd = moved
        return true
    }
}

#if os(macOS)
func installAdmissionDescriptors(
    _ actions: inout posix_spawn_file_actions_t?,
    pipes: RuntimeAdmissionPipes
) -> Bool {
    guard posix_spawn_file_actions_adddup2(
        &actions,
        pipes.requestWrite,
        RuntimeAdmissionDescriptors.request
    ) == 0
    else {
        return false
    }
    guard posix_spawn_file_actions_adddup2(
        &actions,
        pipes.responseRead,
        RuntimeAdmissionDescriptors.response
    ) == 0
    else {
        return false
    }
    let sources = [
        pipes.requestRead, pipes.requestWrite, pipes.responseRead, pipes.responseWrite,
    ]
    for fd in sources {
        guard posix_spawn_file_actions_addclose(&actions, fd) == 0 else { return false }
    }
    return true
}
#endif

private let admissionAppendLock = Mutex<Void>(())

func appendAdmissionEvent(_ event: RuntimeAdmissionEvent, to url: URL) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard var data = try? encoder.encode(event) else { return }
    data.append(UInt8(ascii: "\n"))
    let directory = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    admissionAppendLock.withLock { _ in
        let fd = url.path.withCString { path in
            open(path, O_CREAT | O_APPEND | O_WRONLY | O_CLOEXEC, 0o600)
        }
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return }
        defer { _ = flock(fd, LOCK_UN) }
        _ = admissionWriteAll(fd, data)
    }
}

func admissionClose(_ fd: Int32) {
    guard fd >= 0 else { return }
    _ = close(fd)
}

func admissionReadAvailable(_ fd: Int32) -> Data {
    guard fd >= 0 else { return Data() }
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 1024)
    while bytes.count < RuntimeAdmissionCodec.maxBodyBytes + 4 {
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return read(fd, base, raw.count)
        }
        if count > 0 {
            bytes.append(contentsOf: buffer.prefix(count))
            continue
        }
        if count < 0, errno == EINTR { continue }
        break
    }
    return Data(bytes)
}

@discardableResult
func admissionWriteAll(_ fd: Int32, _ data: Data) -> Bool {
    guard fd >= 0 else { return false }
    let bytes = [UInt8](data)
    var offset = 0
    while offset < bytes.count {
        let wrote = bytes.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return write(fd, base.advanced(by: offset), bytes.count - offset)
        }
        if wrote > 0 {
            offset += wrote
            continue
        }
        if wrote < 0, errno == EINTR { continue }
        return false
    }
    return true
}

/// Runs an already-authorized argv outside the contained agent.
///
/// This is not a second runtime session and it does not mount another
/// workspace volume. The process is RV's child, under the same Seatbelt
/// profile, and it does not inherit the admission pipes.
func runAdmittedSeatbeltCommand(
    allowed: AllowedAction,
    launch: AdmittedLaunchContext
) -> Result<Int32, RuntimeAdmissionExecutorError> {
    #if os(macOS)
    if Task.isCancelled { return .failure(.cancelled) }
    guard launch.profileSource.contains("(deny file-link)") else {
        return .failure(.notEstablished)
    }
    guard FileManager.default.isExecutableFile(atPath: IsolationBackends.sandboxExecPath) else {
        return .failure(.unavailable)
    }
    switch compileExecutable(allowed: allowed, plan: launch.plan) {
    case .failure:
        return .failure(.compileFailed)
    case .success(let executable):
        return spawnAdmittedCommand(executable.command, launch: launch)
    }
    #else
    _ = allowed
    _ = launch
    return .failure(.unavailable)
    #endif
}

#if os(macOS)
private let admittedHandshakeScript =
    "printf %s \"$1\" >&3 || exit 127; exec 3>&- || exit 127; shift; exec \"$@\""

private func spawnAdmittedCommand(
    _ command: IsolatedCommand,
    launch: AdmittedLaunchContext
) -> Result<Int32, RuntimeAdmissionExecutorError> {
    let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    var handshake: [Int32] = [-1, -1]
    let opened = handshake.withUnsafeMutableBufferPointer { buffer -> Int32 in
        guard let base = buffer.baseAddress else { return -1 }
        return pipe(base)
    }
    guard opened == 0 else { return .failure(.spawnFailed) }
    var readEnd = handshake[0]
    var writeEnd = handshake[1]
    var nullFD: Int32 = -1
    defer {
        if readEnd >= 0 { close(readEnd) }
        if writeEnd >= 0 { close(writeEnd) }
        if nullFD >= 0 { close(nullFD) }
    }
    guard fcntl(readEnd, F_SETFD, FD_CLOEXEC) >= 0,
        fcntl(writeEnd, F_SETFD, FD_CLOEXEC) >= 0,
        moveAdmittedDescriptor(&readEnd, floor: 8),
        moveAdmittedDescriptor(&writeEnd, floor: 8)
    else {
        return .failure(.spawnFailed)
    }
    let openedNull = open("/dev/null", O_RDWR | O_CLOEXEC)
    guard openedNull >= 0 else { return .failure(.spawnFailed) }
    nullFD = openedNull
    guard moveAdmittedDescriptor(&nullFD, floor: 8) else { return .failure(.spawnFailed) }

    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else { return .failure(.spawnFailed) }
    defer { posix_spawnattr_destroy(&attributes) }
    let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
    guard posix_spawnattr_setflags(&attributes, flags) == 0,
        posix_spawnattr_setpgroup(&attributes, 0) == 0
    else {
        return .failure(.spawnFailed)
    }

    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { return .failure(.spawnFailed) }
    defer { posix_spawn_file_actions_destroy(&actions) }
    let chdirOK = launch.workspacePath.withCString { path in
        if #available(macOS 26, *) {
            posix_spawn_file_actions_addchdir(&actions, path)
        } else {
            posix_spawn_file_actions_addchdir_np(&actions, path)
        }
    }
    guard chdirOK == 0,
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 3) == 0,
        posix_spawn_file_actions_addclose(&actions, readEnd) == 0,
        posix_spawn_file_actions_addclose(&actions, writeEnd) == 0,
        posix_spawn_file_actions_adddup2(&actions, nullFD, STDIN_FILENO) == 0,
        posix_spawn_file_actions_adddup2(&actions, nullFD, STDOUT_FILENO) == 0,
        posix_spawn_file_actions_adddup2(&actions, nullFD, STDERR_FILENO) == 0,
        posix_spawn_file_actions_addclose(&actions, nullFD) == 0
    else {
        return .failure(.spawnFailed)
    }

    var arguments = [
        IsolationBackends.sandboxExecPath,
        "-p",
        launch.profileSource,
        "/bin/sh",
        "-c",
        admittedHandshakeScript,
        "rv-admit",
        nonce,
        command.executable,
    ]
    arguments.append(contentsOf: command.arguments)
    let environment = [
        "PATH=/usr/bin:/bin",
        "LANG=C",
        "LC_ALL=C",
        "HOME=\(launch.workspacePath)",
        "TMPDIR=\(launch.workspacePath)",
    ]
    let argv = AdmissionSpawnPointers(arguments)
    let envp = AdmissionSpawnPointers(environment)
    defer {
        argv.release()
        envp.release()
    }
    var pid: pid_t = 0
    let spawned = argv.withPointers { argvPointer in
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
    close(writeEnd)
    writeEnd = -1
    close(nullFD)
    nullFD = -1
    guard spawned == 0, pid > 1 else { return .failure(.spawnFailed) }
    let flagsNow = fcntl(readEnd, F_GETFL)
    guard flagsNow >= 0, fcntl(readEnd, F_SETFL, flagsNow | O_NONBLOCK) >= 0 else {
        killAdmitted(pid)
        _ = waitAdmittedDead(pid)
        return .failure(.spawnFailed)
    }
    return waitForAdmittedPayload(
        root: pid,
        readEnd: readEnd,
        nonce: nonce,
        sessionLeader: launch.sessionLeader
    )
}

private func moveAdmittedDescriptor(_ fd: inout Int32, floor: Int32) -> Bool {
    guard fd >= 0 else { return false }
    if fd >= floor { return true }
    let moved = fcntl(fd, F_DUPFD_CLOEXEC, floor)
    guard moved >= 0 else { return false }
    close(fd)
    fd = moved
    return true
}

private func waitForAdmittedPayload(
    root: pid_t,
    readEnd: Int32,
    nonce: String,
    sessionLeader: pid_t
) -> Result<Int32, RuntimeAdmissionExecutorError> {
    let expected = Data(nonce.utf8)
    var handshake = Data()
    var established = false
    var status: Int32?
    while true {
        let cancel = Task.isCancelled
        if established == false {
            handshake.append(admissionReadAvailable(readEnd))
            if handshake.starts(with: expected), handshake.count >= expected.count {
                established = true
            }
        }
        if status == nil {
            var waited = Int32(0)
            let result = waitpid(root, &waited, WNOHANG)
            if result == root {
                status = admittedExitStatus(waited)
            }
        }
        let rootGone = status != nil || (kill(root, 0) == -1 && errno == ESRCH)
        if cancel || rootGone {
            if established == false {
                handshake.append(admissionReadAvailable(readEnd))
                if handshake.starts(with: expected), handshake.count >= expected.count {
                    established = true
                }
            }
            killAdmitted(root)
            guard waitAdmittedDead(root) else { return .failure(.spawnFailed) }
            if cancel, established == false || status == nil {
                return .failure(.cancelled)
            }
            guard established, let status else { return .failure(.notEstablished) }
            return .success(status)
        }
        // This wait blocks the session reaper. Stop when the contained process
        // has exited so its group can be killed without waiting out the command.
        if sessionLeaderHasExited(sessionLeader) {
            killAdmitted(root)
            guard waitAdmittedDead(root) else { return .failure(.spawnFailed) }
            return .failure(.cancelled)
        }
        usleep(10_000)
    }
}

/// `WNOWAIT` observes the leader without reaping it. The session loop still
/// owns that `waitpid`. A zombie is enough: `kill(pid, 0)` stays true until
/// the leader is reaped, which cannot happen while this wait is running.
func sessionLeaderHasExited(_ pid: pid_t) -> Bool {
    guard pid > 1 else { return false }
    var info = siginfo_t()
    memset(&info, 0, MemoryLayout<siginfo_t>.size)
    let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
    if result != 0 { return false }
    return info.si_pid == pid
}

private func killAdmitted(_ pid: pid_t) {
    guard pid > 1 else { return }
    _ = kill(-pid, SIGKILL)
    _ = kill(pid, SIGKILL)
}

private func waitAdmittedDead(_ pid: pid_t) -> Bool {
    guard pid > 1 else { return true }
    for _ in 0..<200 {
        var status: Int32 = 0
        _ = waitpid(pid, &status, WNOHANG)
        killAdmitted(pid)
        if kill(pid, 0) == -1, errno == ESRCH,
            kill(-pid, 0) == -1, errno == ESRCH
        {
            return true
        }
        usleep(10_000)
    }
    return kill(pid, 0) == -1 && errno == ESRCH && kill(-pid, 0) == -1 && errno == ESRCH
}

private func admittedExitStatus(_ status: Int32) -> Int32 {
    let waited = status & 0o177
    if waited == 0 { return (status >> 8) & 0xff }
    if waited != 0o177 { return waited }
    return status
}

private struct AdmissionSpawnPointers {
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
        for pointer in storage { free(pointer) }
    }
}
#endif
