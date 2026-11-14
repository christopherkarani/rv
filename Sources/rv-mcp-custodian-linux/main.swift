import CRVPAM
import Foundation
import Glibc
import RVMCP
import Synchronization

// The approvals custodian on Linux (docs/security/mcp-linux-custodian.md).
//
//   rv-mcp-custodian serve [--socket PATH] [--state DIRECTORY]
//       The key daemon. Runs as its own system account, never as root or
//       as a user it signs for. Holds each account's key and ledger and
//       answers `MCPCustodianSocketRequest`s; who may ask what is decided
//       by `MCPCustodianSocketService`.
//   rv-mcp-custodian presence [--socket PATH] [--custodian PATH]
//       The presence helper's listener. Runs as root. Starts one
//       `presence-session` process per connection.
//   rv-mcp-custodian presence-session CUSTODIAN-SOCKET
//       One conversation, on descriptor 3: authenticates the connection's
//       peer with PAM and, if that succeeds, attests it to the key daemon.
//
// The paths are flags because the units that start these name them; the
// client has no such flags (`MCPCustodianSocketClient`).

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("rv-mcp-custodian: \(message)\n".utf8))
    exit(1)
}

func note(_ message: String) {
    FileHandle.standardError.write(Data("rv-mcp-custodian: \(message)\n".utf8))
}

/// `--name value` pairs after the mode; anything else is a usage error.
func options(_ arguments: ArraySlice<String>, allowed: Set<String>) -> [String: String] {
    var values: [String: String] = [:]
    var rest = arguments
    while let name = rest.popFirst() {
        guard allowed.contains(name), let value = rest.popFirst(), values[name] == nil else {
            fail("unexpected argument \(name)")
        }
        values[name] = value
    }
    return values
}

func peer(of fd: Int32) -> MCPCustodianPeer? {
    MCPCustodianPeer(socket: fd)
}

func setTimeouts(_ fd: Int32, receive: time_t, send: time_t) -> Bool {
    var incoming = timeval(tv_sec: receive, tv_usec: 0)
    var outgoing = timeval(tv_sec: send, tv_usec: 0)
    let size = socklen_t(MemoryLayout<timeval>.size)
    return setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &incoming, size) == 0
        && setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &outgoing, size) == 0
}

/// A listening socket at `path` that any account may connect to. The
/// directory is the unit's `RuntimeDirectory`: only this account writes it.
func listen(at path: String) -> Int32 {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { fail("socket path too long: \(path)") }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
    guard fd >= 0 else { fail("socket: \(String(cString: strerror(errno)))") }
    var info = stat()
    if lstat(path, &info) == 0 {
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid(), unlink(path) == 0 else {
            fail("\(path) exists and is not this daemon's own socket")
        }
    }
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
    }
    guard bound, chmod(path, 0o666) == 0, Glibc.listen(fd, 64) == 0 else {
        fail("cannot listen on \(path): \(String(cString: strerror(errno)))")
    }
    return fd
}

/// One accepted connection, close-on-exec, or -1 with `errno` set.
func acceptOne(_ listener: Int32) -> Int32 {
    let fd = accept(listener, nil, nil)
    guard fd >= 0 else { return -1 }
    guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
        close(fd)
        errno = ECONNABORTED
        return -1
    }
    return fd
}

// MARK: - The key daemon

/// Connections one account, and all accounts, may hold open at once: a
/// local account cannot use up the daemon.
let maximumConnections = 64
let maximumConnectionsPerAccount = 8
/// A connection that says nothing for this long is closed. Longer than a
/// proof of presence may take.
let idleSeconds: time_t = 180

func serve(socketPath: String, state: String) -> Never {
    guard geteuid() != 0 else { fail("the key daemon does not run as root; run it as the \(MCPCustodianSocket.account) account") }
    umask(0o077)
    var info = stat()
    guard lstat(state, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0
    else { fail("\(state) must be a directory only this account can enter") }
    let service = Mutex(MCPCustodianSocketService(storage: MCPCustodianStore(directory: URL(fileURLWithPath: state)).storage))
    let held = Mutex<[UInt32: Int]>([:])
    let listener = listen(at: socketPath)
    note("serving \(socketPath) as uid \(geteuid())")
    var next: UInt64 = 0
    while true {
        let fd = acceptOne(listener)
        if fd < 0 {
            if errno == EINTR || errno == ECONNABORTED { continue }
            fail("accept: \(String(cString: strerror(errno)))")
        }
        guard let peer = peer(of: fd), setTimeouts(fd, receive: idleSeconds, send: 10) else {
            close(fd)
            continue
        }
        let admitted = held.withLock { counts -> Bool in
            guard counts.values.reduce(0, +) < maximumConnections,
                counts[peer.uid, default: 0] < maximumConnectionsPerAccount
            else { return false }
            counts[peer.uid, default: 0] += 1
            return true
        }
        guard admitted else {
            close(fd)
            continue
        }
        next += 1
        let id = next
        service.withLock { $0.open(id, peer: peer) }
        Thread.detachNewThread {
            while let request = MCPCustodianFrame.read(MCPCustodianSocketRequest.self, from: fd) {
                guard let response = service.withLock({ $0.handle(id, request, now: .now) }),
                    MCPCustodianFrame.write(response, to: fd)
                else { break }
            }
            service.withLock { $0.close(id) }
            held.withLock { counts in
                counts[peer.uid] = counts[peer.uid].flatMap { $0 > 1 ? $0 - 1 : nil }
            }
            close(fd)
        }
    }
}

// MARK: - The presence helper

/// Proofs in progress at once, and one per account.
let maximumSessions = 8
/// One conversation's whole life, password typing included.
let sessionSeconds: UInt32 = 150

func presence(socketPath: String, custodian: String) -> Never {
    guard geteuid() == 0 else { fail("the presence helper checks passwords with PAM and must run as root") }
    guard let own = realpath("/proc/self/exe", nil) else { fail("cannot find this executable") }
    let executable = String(cString: own)
    let listener = listen(at: socketPath)
    note("presence helper serving \(socketPath)")
    var sessions: [pid_t: UInt32] = [:]
    while true {
        let fd = acceptOne(listener)
        if fd < 0 {
            if errno == EINTR || errno == ECONNABORTED { continue }
            fail("accept: \(String(cString: strerror(errno)))")
        }
        // Sessions that ended since the last connection.
        var status: Int32 = 0
        while case let ended = waitpid(-1, &status, WNOHANG), ended > 0 { sessions[ended] = nil }
        guard let peer = peer(of: fd), setTimeouts(fd, receive: time_t(sessionSeconds), send: 10) else {
            close(fd)
            continue
        }
        guard sessions.count < maximumSessions, sessions.values.contains(peer.uid) == false else {
            _ = MCPCustodianFrame.write(MCPPresenceResponse.result(.busy), to: fd)
            close(fd)
            continue
        }
        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, fd, 3)
        let arguments = ["rv-mcp-custodian", "presence-session", custodian]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        var environment: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/sbin:/usr/bin:/sbin:/bin"), nil]
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, nil, &argv, &environment)
        posix_spawn_file_actions_destroy(&actions)
        argv.forEach { free($0) }
        environment.forEach { free($0) }
        if spawned == 0 {
            sessions[pid] = peer.uid
        } else {
            _ = MCPCustodianFrame.write(MCPPresenceResponse.result(.unavailable), to: fd)
        }
        close(fd)
    }
}

/// The conversation's state, reached from the PAM callback through its
/// context pointer. One per process.
struct Conversation {
    var fd: Int32
}

/// PAM's messages, carried to the client and its answers back.
func converse(
    _ context: UnsafeMutableRawPointer?, _ kind: Int32, _ text: UnsafePointer<CChar>?,
    _ answer: UnsafeMutablePointer<CChar>?, _ size: Int
) -> Int32 {
    guard let context, let text, let answer else { return 1 }
    let fd = context.assumingMemoryBound(to: Conversation.self).pointee.fd
    let shown = String(decoding: String(cString: text).utf8.prefix(MCPCustodianSocket.maximumPromptBytes), as: UTF8.self)
    switch Int(kind) {
    case Int(RV_PAM_ERROR.rawValue), Int(RV_PAM_INFO.rawValue):
        return MCPCustodianFrame.write(MCPPresenceResponse.notice(shown), to: fd) ? 0 : 1
    case Int(RV_PAM_SECRET.rawValue), Int(RV_PAM_VISIBLE.rawValue):
        let prompt = MCPPresenceResponse.prompt(text: shown, secret: Int(kind) == Int(RV_PAM_SECRET.rawValue))
        guard MCPCustodianFrame.write(prompt, to: fd),
            case .answer(let typed)? = MCPCustodianFrame.read(MCPPresenceRequest.self, from: fd)
        else { return 1 }
        let bytes = Array(typed.utf8)
        guard bytes.count < size, bytes.count <= MCPCustodianSocket.maximumAnswerBytes, bytes.contains(0) == false else {
            return 1
        }
        for (index, byte) in bytes.enumerated() { answer[index] = CChar(bitPattern: byte) }
        answer[bytes.count] = 0
        return 0
    default:
        return 1
    }
}

/// Tells the key daemon the owner of `uid` answered `challenge`.
func attest(challenge: String, uid: UInt32, custodian: String) -> MCPPresenceResult {
    guard let account = getpwnam(MCPCustodianSocket.account) else { return .unavailable }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(custodian.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return .unavailable }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
    guard fd >= 0 else { return .unavailable }
    defer { close(fd) }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
    }
    // The daemon on the other end must be the custodian's account.
    guard connected, setTimeouts(fd, receive: 10, send: 10), peer(of: fd)?.uid == account.pointee.pw_uid,
        MCPCustodianFrame.write(
            MCPCustodianSocketRequest.hello(protocolVersion: MCPCustodianSocket.protocolVersion), to: fd),
        case .hello(ok: true, _)? = MCPCustodianFrame.read(MCPCustodianSocketResponse.self, from: fd),
        MCPCustodianFrame.write(MCPCustodianSocketRequest.attest(challenge: challenge, uid: uid), to: fd),
        case .attested(let accepted)? = MCPCustodianFrame.read(MCPCustodianSocketResponse.self, from: fd)
    else { return .unavailable }
    return accepted ? .proved : .rejected
}

func presenceSession(custodian: String) -> Never {
    let fd: Int32 = 3
    alarm(sessionSeconds)
    func finish(_ result: MCPPresenceResult) -> Never {
        _ = MCPCustodianFrame.write(MCPPresenceResponse.result(result), to: fd)
        exit(result == .proved ? 0 : 1)
    }
    guard geteuid() == 0 else { finish(.unavailable) }
    // The account is the connection's peer, as the kernel names it.
    guard let peer = peer(of: fd) else { finish(.unavailable) }
    guard case .prove(let version, let challenge)? = MCPCustodianFrame.read(MCPPresenceRequest.self, from: fd),
        version == MCPCustodianSocket.protocolVersion, MCPCustodianSocket.isValid(challenge: challenge)
    else { finish(.badRequest) }
    guard peer.uid != 0, let entry = getpwuid(peer.uid), let name = entry.pointee.pw_name else { finish(.noAccount) }
    let user = String(cString: name)
    var conversation = Conversation(fd: fd)
    var answers: Int32 = 0
    let outcome = withUnsafeMutablePointer(to: &conversation) { context in
        rv_pam_authenticate(MCPCustodianSocket.pamService, user, converse, context, &answers)
    }
    switch outcome {
    case Int32(RV_PAM_AUTHENTICATED.rawValue):
        // Accepted without the owner typing anything: no proof of presence.
        guard answers > 0 else { finish(.nothingAsked) }
        finish(attest(challenge: challenge, uid: peer.uid, custodian: custodian))
    case Int32(RV_PAM_REFUSED.rawValue):
        finish(.authenticationFailed)
    default:
        finish(.unavailable)
    }
}

// MARK: - Entry

signal(SIGPIPE, SIG_IGN)
let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "serve":
    let values = options(arguments.dropFirst(), allowed: ["--socket", "--state"])
    serve(
        socketPath: values["--socket"] ?? MCPCustodianSocket.path,
        state: values["--state"] ?? "/var/lib/rv-mcp-custodian")
case "presence":
    let values = options(arguments.dropFirst(), allowed: ["--socket", "--custodian"])
    presence(
        socketPath: values["--socket"] ?? MCPCustodianSocket.presencePath,
        custodian: values["--custodian"] ?? MCPCustodianSocket.path)
case "presence-session":
    guard arguments.count == 2, let custodian = arguments.last else { fail("usage: presence-session CUSTODIAN-SOCKET") }
    presenceSession(custodian: custodian)
default:
    fail("usage: rv-mcp-custodian serve|presence [options]")
}
