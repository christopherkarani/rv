#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

#if os(macOS) || os(Linux)
/// libc under names the types below do not shadow with their own methods.
private func closeFile(_ fd: Int32) { _ = close(fd) }
private func listenOn(_ fd: Int32, _ backlog: Int32) -> Int32 { listen(fd, backlog) }
private func connectTo(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    connect(fd, address, length)
}
private func streamSocket() -> Int32 {
    #if canImport(Darwin)
    socket(AF_INET, SOCK_STREAM, 0)
    #else
    socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
}

/// rv's controlling terminal. The command gets the foreground for its run
/// while rv holds it alone, so Ctrl-C and Ctrl-Z reach its group, and rv
/// takes it back when the command stops or exits.
///
/// Modes: on taking it back rv saves the command's modes and restores its
/// own; on handing it back it re-applies the command's, as a shell does for
/// a job it stops and continues.
final class SecretRunTerminal: SecretRunTerminalControl {
    let fd: Int32
    private let saved: termios
    private var commandModes: termios?

    /// rv's controlling terminal, opened as `/dev/tty` whatever stdio is
    /// redirected to (with stdin a pipe the command can still read the
    /// terminal, and its stops must be passed on), or nil when rv has none.
    /// rv may be in the background: it then hands nothing until the shell
    /// gives it the foreground with `fg`. `close` when done.
    static func controlling() -> SecretRunTerminal? {
        let fd = open("/dev/tty", O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var modes = termios()
        guard tcgetpgrp(fd) > 0, tcgetattr(fd, &modes) == 0 else {
            closeFile(fd)
            return nil
        }
        return SecretRunTerminal(fd: fd, saved: modes)
    }

    private init(fd: Int32, saved: termios) {
        self.fd = fd
        self.saved = saved
    }

    func close() {
        closeFile(fd)
    }

    var rvInForeground: Bool { tcgetpgrp(fd) == getpgrp() }

    var foregroundGroup: pid_t? {
        let group = tcgetpgrp(fd)
        return group > 0 ? group : nil
    }

    /// From the kernel's list of rv's group and rv's parent chain. Checked
    /// by membership, not by whether stdout is a pipe: a pipe to a file
    /// reader in another group would read the same.
    var sharesGroup: Bool {
        #if os(macOS)
        var ancestors: Set<pid_t> = []
        var current = getppid()
        while current > 1, ancestors.count < 256, ancestors.insert(current).inserted {
            guard case .found(let info) = ProcessGroupRecovery.lookup(current) else { break }
            current = pid_t(info.pbi_ppid)
        }
        return SecretRunJobControl.sharesGroup(
            members: listedPIDs(proc_listpgrppids, getpgrp()), rv: getpid(), ancestors: ancestors)
        #else
        // The same two facts from `/proc`: one table, one reading of it.
        let table = ProcFSProcessTable()
        return SecretRunJobControl.sharesGroup(
            members: table.groupMembers(getpgrp()) ?? [], rv: getpid(), ancestors: table.ancestors(of: getpid()))
        #endif
    }

    /// `SIGTTOU` must be ignored (as `SecretRunSignals` does): once the
    /// command holds the foreground, rv is a background process.
    func hand(to group: pid_t) -> Bool {
        if var modes = commandModes {
            _ = tcsetattr(fd, TCSANOW, &modes)
        }
        return tcsetpgrp(fd, group) == 0
    }

    func reclaim() {
        var current = termios()
        commandModes = tcgetattr(fd, &current) == 0 ? current : nil
        _ = tcsetpgrp(fd, getpgrp())
        var modes = saved
        _ = tcsetattr(fd, TCSANOW, &modes)
    }

    func stopSelf() {
        _ = kill(getpid(), SIGSTOP)
    }
}

/// While `rv run` probes or supervises: `SIGINT`, `SIGQUIT`, `SIGTERM` and
/// `SIGHUP` sent to rv go to the command's group (through
/// `SecretRunSignalTarget`) instead of ending rv, `SIGTTOU` is ignored so rv
/// can take the terminal back from the background, and `SIGCHLD` is default
/// so the command is not reaped behind rv's back. A signal that lands before
/// the group is targeted is kept, and the launch abandoned.
///
/// Dispositions are process-wide, so every guard shares one installation:
/// the first in sets them, the last out restores what was there before.
final class SecretRunSignals: @unchecked Sendable {
    static let forwarded = [SIGINT, SIGQUIT, SIGTERM, SIGHUP]

    private let forwarding = SecretRunSignalTarget()

    init() {
        SecretRunSignalTable.shared.join(forwarding)
    }

    func target(_ group: pid_t) -> Int32? { forwarding.target(group) }

    /// A signal that arrived before any group was targeted.
    var interrupted: Int32? { forwarding.interrupted }

    /// Forwarded signals rv had ignored before any guard: the command keeps
    /// ignoring them (`nohup`, an asynchronous list in a script).
    var inheritedIgnored: Set<Int32> { SecretRunSignalTable.shared.inheritedIgnored }

    /// Whether any guard is installed now.
    static var installed: Bool { SecretRunSignalTable.shared.installed }

    /// Before the leader is reaped.
    func release() { forwarding.release() }

    /// Leaves the shared installation; the last one out restores. Idempotent.
    func restore() {
        forwarding.release()
        SecretRunSignalTable.shared.leave(forwarding)
    }
}

/// The one process-wide installation behind every `SecretRunSignals`.
private final class SecretRunSignalTable: @unchecked Sendable {
    static let shared = SecretRunSignalTable()

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "rv.run.signals")
    private var members: [ObjectIdentifier: SecretRunSignalTarget] = [:]
    private var sources: [any DispatchSourceSignal] = []
    private var previous: [(number: Int32, handler: sig_t?)] = []
    private var ignoredBefore: Set<Int32> = []

    var installed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return members.isEmpty == false
    }

    var inheritedIgnored: Set<Int32> {
        lock.lock()
        defer { lock.unlock() }
        return ignoredBefore
    }

    func join(_ target: SecretRunSignalTarget) {
        lock.lock()
        defer { lock.unlock() }
        if members.isEmpty { install() }
        members[ObjectIdentifier(target)] = target
    }

    func leave(_ target: SecretRunSignalTarget) {
        lock.lock()
        defer { lock.unlock() }
        guard members.removeValue(forKey: ObjectIdentifier(target)) != nil, members.isEmpty else { return }
        for source in sources { source.cancel() }
        sources.removeAll()
        #if os(Linux)
        SecretRunSignalRelay.remove()
        #endif
        for entry in previous.reversed() { _ = signal(entry.number, entry.handler) }
        previous.removeAll()
        ignoredBefore.removeAll()
    }

    private func deliver(_ number: Int32) {
        lock.lock()
        let targets = Array(members.values)
        lock.unlock()
        for target in targets { target.deliver(number) }
    }

    /// Under `lock`, by the first member.
    private func install() {
        for number in SecretRunSignals.forwarded + [SIGTTOU] {
            let handler = signal(number, SIG_IGN)
            previous.append((number, handler))
            if Self.ignores(handler) { ignoredBefore.insert(number) }
        }
        previous.append((SIGCHLD, signal(SIGCHLD, SIG_DFL)))
        #if os(macOS)
        for number in SecretRunSignals.forwarded {
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [unowned self] in self.deliver(number) }
            source.resume()
            sources.append(source)
        }
        #else
        // Linux drops an ignored signal before a signal source could read it.
        SecretRunSignalRelay.install(SecretRunSignals.forwarded) { [unowned self] in self.deliver($0) }
        #endif
    }

    private static func ignores(_ handler: sig_t?) -> Bool {
        unsafeBitCast(handler, to: Int.self) == unsafeBitCast(SIG_IGN as sig_t?, to: Int.self)
    }
}

/// One loopback connection rv holds both ends of, for the capability probe.
struct SecretRunLoopback {
    let client: Int32
    let server: Int32
    /// The connection as the gateway would name it from `server`.
    let peer: GatewayPeer

    func close() {
        closeFile(client)
        closeFile(server)
    }

    /// A listener on 127.0.0.1 and an ephemeral port.
    static func listen() -> (fd: Int32, port: UInt16)? {
        let fd = streamSocket()
        guard fd >= 0 else { return nil }
        var address = loopback(port: 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ready = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && listenOn(fd, 2) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard ready else {
            closeFile(fd)
            return nil
        }
        return (fd, UInt16(bigEndian: address.sin_port))
    }

    /// The client end sits at fd 10 or above, so it can never be the fd 3
    /// it is duplicated onto in the probe child.
    static func connect(_ listener: (fd: Int32, port: UInt16)) -> SecretRunLoopback? {
        let opened = streamSocket()
        guard opened >= 0 else { return nil }
        let client = fcntl(opened, F_DUPFD_CLOEXEC, 10)
        closeFile(opened)
        guard client >= 0 else { return nil }
        var address = loopback(port: listener.port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connectTo(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        let server = connected ? accept(listener.fd, nil, nil) : -1
        guard server >= 0, let peer = GatewayPeer.of(server) else {
            closeFile(client)
            if server >= 0 { closeFile(server) }
            return nil
        }
        return SecretRunLoopback(client: client, server: server, peer: peer)
    }

    private static func loopback(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = GatewayPeer.loopback
        return address
    }
}
#else
/// No `rv run` here: nothing is installed and nothing is forwarded.
final class SecretRunSignals: @unchecked Sendable {
    init() {}
    func target(_: pid_t) -> Int32? { nil }
    var interrupted: Int32? { nil }
    var inheritedIgnored: Set<Int32> { [] }
    static var installed: Bool { false }
    func release() {}
    func restore() {}
}
#endif
