#if os(Linux)
import Foundation
import Glibc
import RVIsolation
import Synchronization

/// What a proof of presence came to.
public enum MCPCustodianPresence: Equatable, Sendable {
    case proved
    case refused(String)
}

/// Where the owner is asked: their terminal. Nil answers end the proof.
public struct MCPCustodianTerminal: Sendable {
    /// Shows `text` and reads one line; `secret` input is not echoed.
    public var ask: @Sendable (_ text: String, _ secret: Bool) -> String?
    public var show: @Sendable (String) -> Void

    public init(ask: @escaping @Sendable (String, Bool) -> String?, show: @escaping @Sendable (String) -> Void) {
        self.ask = ask
        self.show = show
    }

    /// The process's controlling terminal, or nil when it has none (an
    /// agent's pipe, a service): the owner cannot be asked there.
    public static var controlling: MCPCustodianTerminal? { terminal(at: "/dev/tty") }

    /// The terminal at `path`, or nil when it cannot be opened.
    static func terminal(at path: String) -> MCPCustodianTerminal? {
        let probe = open(path, O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard probe >= 0 else { return nil }
        close(probe)
        return MCPCustodianTerminal(
            ask: { text, secret in
                let fd = open(path, O_RDWR | O_NOCTTY | O_CLOEXEC)
                guard fd >= 0 else { return nil }
                defer { close(fd) }
                var original = termios()
                guard tcgetattr(fd, &original) == 0 else { return nil }
                // Echo goes off before the prompt appears, so nothing typed
                // once the prompt is visible is ever shown; what was typed
                // before it is discarded (TCSAFLUSH). The interrupt keys
                // are read as input, so Ctrl-C cancels here instead of
                // ending rv with the terminal left silent.
                var quiet = original
                quiet.c_lflag &= ~tcflag_t(ISIG)
                if secret {
                    quiet.c_lflag &= ~tcflag_t(ECHO)
                    quiet.c_lflag |= tcflag_t(ECHONL)
                }
                guard tcsetattr(fd, TCSAFLUSH, &quiet) == 0 else { return nil }
                defer { _ = tcsetattr(fd, TCSAFLUSH, &original) }
                _ = text.withCString { write(fd, $0, strlen($0)) }
                var bytes: [UInt8] = []
                var byte: UInt8 = 0
                while true {
                    let count = read(fd, &byte, 1)
                    if count < 0, errno == EINTR { continue }
                    guard count == 1 else { return nil }
                    if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") { break }
                    bytes.append(byte)
                    guard bytes.count <= MCPCustodianSocket.maximumAnswerBytes else { return nil }
                }
                // Ctrl-C, Ctrl-\, Ctrl-Z or Ctrl-D anywhere in the line: cancelled.
                guard bytes.contains(where: { [0x03, 0x04, 0x1A, 0x1C].contains($0) }) == false else { return nil }
                return String(decoding: bytes, as: UTF8.self)
            },
            show: { text in
                let fd = open(path, O_WRONLY | O_NOCTTY | O_CLOEXEC)
                guard fd >= 0 else { return }
                defer { close(fd) }
                _ = (text + "\n").withCString { write(fd, $0, strlen($0)) }
            })
    }
}

/// The client of the approvals custodian on Linux: one connection to the
/// key daemon for the life of the process, and the conversation with the
/// presence helper that unlocks it. The socket paths are fixed, in
/// directories only root can create, and each peer must be the account it
/// should be: nothing a same-user process sets (an environment variable,
/// a file in the home) can point rv at another custodian.
public final class MCPCustodianSocketClient: Sendable {
    public static let shared = MCPCustodianSocketClient(
        path: MCPCustodianSocket.path, presencePath: MCPCustodianSocket.presencePath,
        custodianUID: { accountUID(MCPCustodianSocket.account) }, presenceUID: 0)

    static let exchangeTimeout: time_t = 30
    /// As long as the owner may take to type a password, and a little more.
    static let presenceTimeout: time_t = 150

    let path: String
    let presencePath: String
    let installedBinary: String
    let custodianUID: @Sendable () -> uid_t?
    let presenceUID: uid_t
    private let connection = Mutex<Int32>(-1)

    init(
        path: String, presencePath: String, installedBinary: String = MCPCustodianSocket.installedBinary,
        custodianUID: @escaping @Sendable () -> uid_t?, presenceUID: uid_t
    ) {
        self.path = path
        self.presencePath = presencePath
        self.installedBinary = installedBinary
        self.custodianUID = custodianUID
        self.presenceUID = presenceUID
    }

    deinit {
        let fd = connection.withLock { $0 }
        if fd >= 0 { close(fd) }
    }

    static func accountUID(_ name: String) -> uid_t? {
        guard let entry = getpwnam(name) else { return nil }
        return entry.pointee.pw_uid
    }

    /// Whether a custodian is installed on this host: its socket is there,
    /// or root's copy of it is (it is stopped, or crashed: its socket goes
    /// with it). A custodian that is installed and not answering is
    /// `unavailable`, never a reason to fall back to a key file.
    public var isInstalled: Bool {
        var info = stat()
        if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK { return true }
        return lstat(installedBinary, &info) == 0
    }

    /// A connected stream socket whose peer is `uid`, or -1.
    public static func connect(_ path: String, peer uid: uid_t, timeout: time_t) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return -1 }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard fd >= 0 else { return -1 }
        var limit = timeval(tv_sec: timeout, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard connected, setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, size) == 0,
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, size) == 0, MCPCustodianPeer(socket: fd)?.uid == uid
        else {
            close(fd)
            return -1
        }
        return fd
    }

    /// A new, greeted connection to the key daemon, or -1.
    private func open() -> Int32 {
        guard let uid = custodianUID() else { return -1 }
        let opened = Self.connect(path, peer: uid, timeout: Self.exchangeTimeout)
        guard opened >= 0 else { return -1 }
        let hello = MCPCustodianSocketRequest.hello(protocolVersion: MCPCustodianSocket.protocolVersion)
        guard MCPCustodianFrame.write(hello, to: opened),
            case .hello(ok: true, _)? = MCPCustodianFrame.read(MCPCustodianSocketResponse.self, from: opened)
        else {
            close(opened)
            return -1
        }
        return opened
    }

    /// One request on the process's connection, opened and greeted on
    /// first use. The daemon closes a connection that has been idle, and a
    /// restarted daemon has none: a request that fails on a connection
    /// used before is sent once more on a new one, which starts with
    /// nothing unlocked. Any other failure closes the connection.
    func exchange(_ request: MCPCustodianSocketRequest) -> MCPCustodianSocketResponse? {
        connection.withLock { fd in
            func attempt() -> MCPCustodianSocketResponse? {
                guard MCPCustodianFrame.write(request, to: fd) else { return nil }
                return MCPCustodianFrame.read(MCPCustodianSocketResponse.self, from: fd)
            }
            let reused = fd >= 0
            if reused == false { fd = open() }
            guard fd >= 0 else { return nil }
            if let response = attempt() { return response }
            close(fd)
            fd = reused ? open() : -1
            guard fd >= 0 else { return nil }
            if let response = attempt() { return response }
            close(fd)
            fd = -1
            return nil
        }
    }

    /// Asks the owner to authenticate, on `terminal`, so that this
    /// process's connection may sign for a short while. The presence
    /// helper (root) checks the answer with PAM and tells the key daemon;
    /// this process only carries the conversation.
    public func provePresence(reason: String, terminal: MCPCustodianTerminal? = .controlling) -> MCPCustodianPresence {
        guard let terminal else {
            return .refused("this needs you present: run it yourself in a terminal (this process has no terminal)")
        }
        guard case .challenge(let challenge)? = exchange(.challenge) else {
            return .refused("the approvals custodian is not answering (systemctl status rv-mcp-custodian)")
        }
        let helper = Self.connect(presencePath, peer: presenceUID, timeout: Self.presenceTimeout)
        guard helper >= 0 else {
            return .refused("the approvals custodian's presence helper is not answering (systemctl status rv-mcp-presence)")
        }
        defer { close(helper) }
        let prove = MCPPresenceRequest.prove(protocolVersion: MCPCustodianSocket.protocolVersion, challenge: challenge)
        guard MCPCustodianFrame.write(prove, to: helper) else { return .refused("the presence helper hung up") }
        terminal.show(reason)
        while true {
            guard let message = MCPCustodianFrame.read(MCPPresenceResponse.self, from: helper) else {
                return .refused("the presence helper hung up or timed out")
            }
            switch message {
            case .notice(let text):
                terminal.show(MCPDisplayedText.field(text))
            case .prompt(let text, let secret):
                guard let answer = terminal.ask(MCPDisplayedText.field(text), secret),
                    MCPCustodianFrame.write(MCPPresenceRequest.answer(answer), to: helper)
                else { return .refused("authentication was cancelled") }
            case .result(.proved):
                return .proved
            case .result(let failure):
                return .refused(Self.explain(failure))
            }
        }
    }

    static func explain(_ result: MCPPresenceResult) -> String {
        switch result {
        case .proved: "authenticated"
        case .authenticationFailed: "authentication failed"
        case .nothingAsked:
            "this account authenticates without being asked anything (an empty password, or a permissive PAM "
                + "stack for \(MCPCustodianSocket.pamService)), which is not proof you are present"
        case .noAccount: "the approvals custodian does not sign for this account"
        case .busy: "another approval for this account is in progress"
        case .rejected: "the approvals custodian did not accept the proof (it took too long?); try again"
        case .unavailable: "the presence helper could not use PAM or reach the approvals custodian"
        case .badRequest: "the presence helper did not understand this rv (a version mismatch?)"
        }
    }

    /// The signing seam over this client, for the rv configuration in
    /// `scope`. A signature that needs the owner asks for them on the
    /// terminal, once, if the connection is not already unlocked.
    public func transport(
        scope: String, terminal: @escaping @Sendable () -> MCPCustodianTerminal? = { .controlling }
    ) -> MCPCustodianTransport {
        { [self] request in
            var asked = request
            // Verifying never authenticates here, so there is no window
            // left open by an earlier check for this to end: the one the
            // owner opens for an operation is the one its signature uses.
            if case .beginFreshAuth = request { asked = .status }
            var response = exchange(.key(scope: scope, request: asked))
            if case .presenceRequired? = response {
                switch provePresence(reason: "rv: your login password is needed to sign this", terminal: terminal()) {
                case .proved: response = exchange(.key(scope: scope, request: asked))
                case .refused(let why):
                    FileHandle.standardError.write(Data("rv: nothing was signed: \(why)\n".utf8))
                    return nil
                }
            }
            guard case .key(let answer)? = response else { return nil }
            return answer
        }
    }
}
#endif
