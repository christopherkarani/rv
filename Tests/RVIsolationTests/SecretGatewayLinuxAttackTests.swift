#if os(Linux)
import Glibc
import Foundation
import Testing
@testable import RVIsolation

/// The Linux peer binding against kernel states built to fool it, on the
/// real kernel. Each test states what the check concludes. Assertions are on
/// identity, never on durations; waits have a deadline only so a broken run
/// fails instead of hanging.
///
/// A kernel feature a host refuses (a container's seccomp profile, no IPv6)
/// prints `skipped:`; `RV_LINUX_PEER_STRICT=1` makes that a failure instead,
/// which is how CI proves each test ran on a real VM. The `RV_PROC_REGIME`
/// tests run only inside the environment
/// `Scripts/linux-peer-binding-e2e.sh` builds for them.
@Suite("Secret gateway Linux peer binding under attack", .serialized)
struct SecretGatewayLinuxAttackTests {
    typealias Connection = SecretGatewayLinuxPeerTests.Connection
    typealias Leader = SecretGatewayLinuxPeerTests.Leader
    typealias Forked = SecretGatewayLinuxPeerTests.Forked
    typealias Channel = SecretGatewayLinuxPeerTests.Channel
    typealias Scratch = SecretGatewayLinuxPeerTests.Scratch

    static let strict = ProcessInfo.processInfo.environment["RV_LINUX_PEER_STRICT"] == "1"
    static let regime = ProcessInfo.processInfo.environment["RV_PROC_REGIME"]

    private func unavailable(_ what: String) {
        if Self.strict {
            Issue.record("\(what) is unavailable here, and RV_LINUX_PEER_STRICT=1 requires it")
        } else {
            print("skipped: \(what) is unavailable here")
        }
    }

    private func verdict(_ peer: GatewayPeer, _ leader: pid_t) throws -> GatewayPeerVerdict {
        let group = try #require(ProcessGroupRecovery.capture(pid: leader))
        return GatewayPeerScan.verdict(peer, group: group, in: ProcFSProcessTable())
    }

    private func inode(_ fd: Int32) throws -> UInt64 {
        var info = Glibc.stat()
        try #require(fstat(fd, &info) == 0)
        return UInt64(info.st_ino)
    }

    /// Whether `/proc/<pid>/fd` links socket `inode`.
    private func links(_ inode: UInt64, pid: pid_t) -> Bool {
        guard case .value(let names) = ProcFSReader.directory("/proc/\(pid)/fd") else { return false }
        return names.contains { name in
            guard case .value(let target) = ProcFSReader.link("/proc/\(pid)/fd/\(name)") else { return false }
            return ProcFSParse.socketInode(link: target) == inode
        }
    }

    private func rows(_ path: String) -> [ProcFSParse.SocketRow] {
        guard case .value(let bytes) = ProcFSReader.file(path) else { return [] }
        return ProcFSParse.sockets(bytes) ?? []
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if condition() { return true }
            usleep(20_000)
        }
        return condition()
    }

    /// A leader that only sleeps, holding `inherit` (if any) as descriptor 3.
    private func sleeper(inherit: Int32? = nil) throws -> Leader {
        try Leader("exec /bin/sleep 300", inherit: inherit)
    }

    // MARK: - Sockets no descriptor names

    /// A socket registered with io_uring (`IORING_REGISTER_FILES`) and then
    /// closed: no `fd` link names it, the ring holds it. The check concludes
    /// member, from the ring's `fdinfo`.
    @Test func aSocketRegisteredWithIOUringAndClosedIsStillItsProcesss() throws {
        let connection = try Connection()
        let report = try Channel()
        defer { report.close() }
        let client = connection.client
        let parameters = UnsafeMutableRawPointer.allocate(byteCount: 120, alignment: 8)  // struct io_uring_params
        parameters.initializeMemory(as: UInt8.self, repeating: 0, count: 120)
        let files = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        files.initialize(to: client)
        defer {
            parameters.deallocate()
            files.deallocate()
        }
        let child = try Forked(keeping: [client, report.write]) {
            var result: UInt8 = 0
            let ring = attackSyscall(425, 4, Int(bitPattern: parameters), 0, 0)  // io_uring_setup
            if ring < 0 {
                result = UInt8(truncatingIfNeeded: errno)
            } else if attackSyscall(427, ring, 2, Int(bitPattern: files), 1) < 0 {  // IORING_REGISTER_FILES
                result = UInt8(truncatingIfNeeded: errno)
            } else {
                _ = close(client)
            }
            _ = write(report.write, &result, 1)
            while true { pause() }
        }
        let result = try report.receive()
        guard result == 0 else {
            // Docker's seccomp profile and `kernel.io_uring_disabled` refuse it.
            unavailable("io_uring (errno \(result))")
            return
        }
        #expect(links(try inode(client), pid: child.pid) == false)
        #expect(try verdict(connection.peer, child.pid) == .member)
        let group = try #require(ProcessGroupRecovery.capture(pid: child.pid))
        #expect(GatewayPeerScan.holders(connection.peer, group: group, in: ProcFSProcessTable())?.map(\.pid) == [child.pid])
    }

    /// The client closed its end while the gateway still holds its own: the
    /// row stays, with inode 0, a socket no process holds. Nothing can be
    /// attributed, so the check concludes "cannot tell", not outsider.
    @Test func aClientEndNoProcessHoldsCannotBeAttributed() throws {
        let sockets = try #require(try Loopback())
        defer { sockets.close() }
        let leader = try sleeper()
        _ = Glibc.close(sockets.client)
        let peer = sockets.peer
        let orphaned = waitUntil {
            rows("/proc/self/net/tcp").contains { row in
                row.local.port == peer.port && row.remote.port == peer.gatewayPort && row.inode == 0
            }
        }
        try #require(orphaned, "the closed client end is not in the table with inode 0")
        #expect(try verdict(peer, leader.pid) == .unverifiable)
    }

    // MARK: - Descriptors that change hands

    /// An outsider sends its client socket into a runtime process over a
    /// Unix socket (`SCM_RIGHTS`) and the runtime receives it. The check
    /// concludes member: holding the socket is the criterion, however the
    /// process came to hold it, and the outsider that still holds it too is
    /// not looked at. A runtime that accepts descriptors from outside itself
    /// can be handed a connection this way (a documented limit, as on macOS).
    @Test func aDescriptorPassedIntoTheRuntimeMakesItsReceiverAHolder() throws {
        let connection = try Connection()
        let pair = try UnixPair()
        let report = try Channel()
        defer {
            pair.close()
            report.close()
        }
        let message = DescriptorMessage()
        let child = try Forked(keeping: [pair.far, report.write]) {
            var result: UInt8 = message.receive(over: pair.far) >= 0 ? 0 : 1
            _ = write(report.write, &result, 1)
            while true { pause() }
        }
        #expect(try verdict(connection.peer, child.pid) == .outsider)
        try #require(message.send(connection.client, over: pair.near))
        try #require(try report.receive() == 0)
        #expect(try verdict(connection.peer, child.pid) == .member)
    }

    /// A runtime process sends its client socket to a process outside the
    /// runtime. While the runtime keeps its own descriptor the check
    /// concludes member (the runtime chose to share its connection, as it
    /// could by relaying). Once the runtime closes it, only the outsider
    /// holds the socket and the check concludes outsider.
    @Test func aDescriptorPassedOutOfTheRuntimeIsTheRuntimesOnlyWhileItKeepsItsOwn() throws {
        let connection = try Connection()
        let pair = try UnixPair()
        let report = try Channel()
        let proceed = try Channel()
        defer {
            pair.close()
            report.close()
            proceed.close()
        }
        let message = DescriptorMessage()
        let client = connection.client
        let child = try Forked(keeping: [client, pair.far, report.write, proceed.read]) {
            var result: UInt8 = message.send(client, over: pair.far) ? 0 : 1
            _ = write(report.write, &result, 1)
            _ = read(proceed.read, &result, 1)
            _ = close(client)
            _ = write(report.write, &result, 1)
            while true { pause() }
        }
        try #require(try report.receive() == 0)
        let received = message.receive(over: pair.near)
        try #require(received >= 0)
        defer { _ = Glibc.close(received) }
        #expect(try inode(received) == (try inode(client)))
        #expect(try verdict(connection.peer, child.pid) == .member)
        var go: UInt8 = 1
        try #require(write(proceed.write, &go, 1) == 1)
        _ = try report.receive()
        #expect(links(try inode(client), pid: child.pid) == false)
        #expect(try verdict(connection.peer, child.pid) == .outsider)
    }

    // MARK: - The socket table

    /// A dual-stack client (an `AF_INET6` socket connected to
    /// `::ffff:127.0.0.1`) is listed in `tcp6` with v4-mapped addresses and
    /// not in `tcp`. It is still found, and its holder is a member.
    @Test func aDualStackClientSocketIsFoundInTheIPv6Table() throws {
        guard let sockets = try Loopback(dualStackClient: true) else {
            unavailable("IPv6")
            #expect(access("/proc/self/net/tcp6", F_OK) != 0, "tcp6 exists, so a dual-stack socket should too")
            return
        }
        defer { sockets.close() }
        let client = try inode(sockets.client)
        let peer = sockets.peer
        #expect(rows("/proc/self/net/tcp6").contains {
            $0.inode == client && $0.local == .init(address: ProcFSParse.loopback, port: peer.port)
        })
        #expect(rows("/proc/self/net/tcp").contains { $0.inode == client } == false)
        #expect(ProcFSProcessTable().holdsSocket(getpid(), peer) == true)
        let holder = try sleeper(inherit: sockets.client)
        #expect(try verdict(peer, holder.pid) == .member)
        let other = try sleeper()
        #expect(try verdict(peer, other.pid) == .outsider)
    }

    /// Two listeners share the gateway's port (`SO_REUSEPORT`). A connected
    /// 4-tuple is still one pair of rows, so the connection is attributed as
    /// usual, whichever listener accepted it.
    @Test func listenersSharingAPortDoNotConfuseAConnection() throws {
        let sockets = try #require(try Loopback(sharedListeners: true))
        defer { sockets.close() }
        let peer = sockets.peer
        #expect(rows("/proc/self/net/tcp").filter { $0.local.port == peer.gatewayPort && $0.state == 0x0A }.count == 2)
        #expect(ProcFSProcessTable().holdsSocket(getpid(), peer) == true)
        let holder = try sleeper(inherit: sockets.client)
        #expect(try verdict(peer, holder.pid) == .member)
        let other = try sleeper()
        #expect(try verdict(peer, other.pid) == .outsider)
    }

    /// A process in another network namespace builds a connection with the
    /// same port pair there. Its sockets are not in the gateway's table, and
    /// the gateway's connection is not in its descriptors: outsider.
    @Test(.enabled(if: getuid() == 0, "needs root to make a network namespace"))
    func theSamePortPairInAnotherNetworkNamespaceIsNotTheConnection() throws {
        let connection = try Connection()
        let report = try Channel()
        defer { report.close() }
        let peer = connection.peer
        let interface = UnsafeMutableRawPointer.allocate(byteCount: 40, alignment: 8)  // struct ifreq
        interface.initializeMemory(as: UInt8.self, repeating: 0, count: 40)
        interface.storeBytes(of: UInt8(ascii: "l"), as: UInt8.self)
        interface.storeBytes(of: UInt8(ascii: "o"), toByteOffset: 1, as: UInt8.self)
        interface.storeBytes(of: Int16(IFF_UP), toByteOffset: 16, as: Int16.self)
        defer { interface.deallocate() }
        let child = try Forked(keeping: [report.write]) {
            var result: UInt8 = 0
            if attackUnshare(0x4000_0000) != 0 {  // CLONE_NEWNET
                result = UInt8(truncatingIfNeeded: errno)
            } else {
                let control = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
                let up = attackIoctl(control, 0x8914, interface) == 0  // SIOCSIFFLAGS
                let listener = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
                let client = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
                var gateway = sockaddr_in()
                gateway.sin_family = sa_family_t(AF_INET)
                gateway.sin_addr.s_addr = GatewayPeer.loopback
                gateway.sin_port = peer.gatewayPort.bigEndian
                var source = gateway
                source.sin_port = peer.port.bigEndian
                let size = socklen_t(MemoryLayout<sockaddr_in>.size)
                let connected = withUnsafePointer(to: &gateway) { gatewayPointer in
                    gatewayPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { gatewayAddress in
                        withUnsafePointer(to: &source) { sourcePointer in
                            sourcePointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sourceAddress in
                                bind(listener, gatewayAddress, size) == 0 && listen(listener, 1) == 0
                                    && bind(client, sourceAddress, size) == 0 && connect(client, gatewayAddress, size) == 0
                            }
                        }
                    }
                }
                if up == false || connected == false || accept(listener, nil, nil) < 0 { result = 0xFE }
            }
            _ = write(report.write, &result, 1)
            while true { pause() }
        }
        let result = try report.receive()
        guard result != UInt8(EPERM) else {
            unavailable("unshare(CLONE_NEWNET)")
            return
        }
        try #require(result == 0, "the other namespace's connection could not be made (\(result))")
        // The same rows, in its table, with its own inodes.
        let theirs = rows("/proc/\(child.pid)/net/tcp").filter {
            $0.local.port == peer.port && $0.remote.port == peer.gatewayPort && $0.inode != 0
        }
        #expect(theirs.count == 1)
        #expect(theirs.first?.inode != (try inode(connection.client)))
        #expect(ProcFSProcessTable().holdsSocket(child.pid, peer) == false)
        #expect(try verdict(peer, child.pid) == .outsider)
    }

    // MARK: - Processes

    /// `comm` is the process's to choose: here it closes the parenthesis,
    /// forges the next fields and adds a line. The fields are still read
    /// from the last `)`.
    @Test func aProcessNamedLikeTheFieldsAfterItsNameIsReadCorrectly() throws {
        let report = try Channel()
        defer { report.close() }
        let name = Array(") R 1 1 1\n(x".utf8)
        let child = try Forked(keeping: [report.write]) {
            let fd = open("/proc/self/comm", O_WRONLY)
            var result: UInt8 = fd >= 0 && write(fd, name, name.count) == name.count ? 0 : 1
            _ = write(report.write, &result, 1)
            while true { pause() }
        }
        try #require(try report.receive() == 0)
        guard case .value(let bytes) = ProcFSReader.file("/proc/\(child.pid)/stat") else {
            Issue.record("stat is unreadable")
            return
        }
        #expect(bytes.contains(UInt8(ascii: "\n")) && bytes.dropLast().contains(UInt8(ascii: "\n")))
        let stat = try #require(ProcFSParse.stat(bytes))
        #expect(stat.pid == UInt32(child.pid))
        #expect(stat.parent == UInt32(getpid()))
        #expect(stat.group == UInt32(child.pid))
        guard case .found(let process) = ProcFSProcessTable().lookup(child.pid) else {
            Issue.record("the process is not found")
            return
        }
        #expect(process.parent == UInt32(getpid()))
        #expect(ProcFSProcessTable().children(of: getpid())?.contains(child.pid) == true)
    }

    /// Thousands of descriptors and dozens of threads: the scan still
    /// answers, a smaller allowance cannot tell, and it never answers wrong.
    @Test(.timeLimit(.minutes(1))) func aLargeProcessIsScannedWithinItsAllowanceOrNotAtAll() throws {
        let held = try Connection()
        let other = try Connection()
        let report = try Channel()
        defer { report.close() }
        let client = held.client
        let child = try Forked(keeping: [client, report.write]) {
            var limit = rlimit()
            _ = getrlimit(Int32(RLIMIT_NOFILE.rawValue), &limit)
            limit.rlim_cur = limit.rlim_max < 8_192 ? limit.rlim_max : 8_192
            _ = setrlimit(Int32(RLIMIT_NOFILE.rawValue), &limit)
            var opened = 0
            while opened < 6_000, dup(STDERR_FILENO) >= 0 { opened += 1 }
            var threads = 0
            while threads < 48 {
                var thread = pthread_t()
                if pthread_create(&thread, nil, { _ in while true { pause() } }, nil) != 0 { break }
                threads += 1
            }
            var result: UInt8 = opened >= 3_000 && threads == 48 ? 0 : 1
            _ = write(report.write, &result, 1)
            while true { pause() }
        }
        try #require(try report.receive() == 0, "the child could not open 3000 descriptors and 48 threads")
        // The holder is found in its own table: one pass over its descriptors.
        #expect(ProcFSProcessTable().holdsSocket(child.pid, held.peer) == true)
        // A socket it does not hold costs every thread's table: 49 passes.
        #expect(ProcFSProcessTable().holdsSocket(child.pid, other.peer) == false)
        #expect(ProcFSProcessTable(maximumReads: 50_000).holdsSocket(child.pid, other.peer) == nil)
        #expect(ProcFSProcessTable(maximumReads: 2_000).holdsSocket(child.pid, held.peer) == nil)
        #expect(try verdict(held.peer, child.pid) == .member)
        #expect(try verdict(other.peer, child.pid) == .outsider)
    }

    /// A descendant in a pid namespace of its own is still a process of the
    /// gateway's `/proc`, under the pid the gateway sees: a holder, a member.
    @Test(.enabled(if: getuid() == 0 && FileManager.default.isExecutableFile(atPath: "/usr/bin/unshare"),
        "needs root to make a pid namespace"))
    func aDescendantInItsOwnPidNamespaceIsAMember() throws {
        let scratch = try Scratch()
        let connection = try Connection()
        let leader = try Leader(
            #"/usr/bin/unshare --pid --fork /bin/sleep 300 3<&3 & exec 3<&-; read -r _ < "$1""#,
            arguments: [try scratch.fifo("hold")], inherit: connection.client)
        let group = try #require(ProcessGroupRecovery.capture(pid: leader.pid))
        var inner: pid_t?
        let found = waitUntil {
            let table = ProcFSProcessTable()
            for child in table.children(of: leader.pid) ?? [] {
                for grandchild in table.children(of: child) ?? [] where namespacePids(grandchild) == 2 {
                    inner = grandchild
                }
            }
            return inner != nil
        }
        guard found, let inner else {
            unavailable("unshare --pid")
            return
        }
        #expect(links(try inode(connection.client), pid: leader.pid) == false)
        #expect(GatewayPeerScan.verdict(connection.peer, group: group, in: ProcFSProcessTable()) == .member)
        let holders = GatewayPeerScan.holders(connection.peer, group: group, in: ProcFSProcessTable())
        #expect(holders?.map(\.pid).contains(inner) == true)
    }

    /// How many pid namespaces `pid` has a pid in (`NSpid:` in `status`).
    private func namespacePids(_ pid: pid_t) -> Int {
        guard case .value(let bytes) = ProcFSReader.file("/proc/\(pid)/status") else { return 0 }
        let line = String(decoding: bytes, as: UTF8.self).split(separator: "\n").first { $0.hasPrefix("NSpid:") }
        return (line?.split(whereSeparator: { $0 == "\t" || $0 == " " }).count ?? 1) - 1
    }

    // MARK: - Regimes (Scripts/linux-peer-binding-e2e.sh)

    /// `/proc` mounted with `hidepid`: a descendant running as another user
    /// could be hidden, so no listing is complete and nothing is bound, not
    /// even a connection the leader holds. One process's `stat` still reads.
    @Test(.enabled(if: regime == "hidepid"))
    func aProcMountedToHideProcessesBindsNothing() throws {
        #expect(GatewayPeerBinding.probe(in: ProcFSProcessTable()) == false)
        let connection = try Connection()
        let leader = try sleeper(inherit: connection.client)
        #expect(try verdict(connection.peer, leader.pid) == .unverifiable)
        #expect(ProcFSProcessTable().children(of: getpid()) == nil)
        #expect(ProcFSProcessTable().holdsSocket(getpid(), connection.peer) == nil)
    }

    /// `/proc` mounted with `subset=pid` hides nothing the check reads.
    @Test(.enabled(if: regime == "subset"))
    func aProcMountedWithOnlyTheProcessFilesStillBinds() throws {
        #expect(access("/proc/meminfo", F_OK) != 0, "this is not a subset=pid mount")
        #expect(GatewayPeerBinding.probe(in: ProcFSProcessTable()))
        let connection = try Connection()
        let holder = try sleeper(inherit: connection.client)
        #expect(try verdict(connection.peer, holder.pid) == .member)
        let other = try sleeper()
        #expect(try verdict(connection.peer, other.pid) == .outsider)
    }

    /// This process in a new pid namespace with the old `/proc` still
    /// mounted: `self` is the pid the old namespace knows, not `getpid()`,
    /// and every pid in it means something else. Nothing is read from it.
    @Test(.enabled(if: regime == "foreign"))
    func aProcOfAnotherPidNamespaceAnswersNothing() throws {
        guard case .value(let me) = ProcFSReader.link("/proc/self") else {
            Issue.record("/proc/self is unreadable")
            return
        }
        try #require(me != String(getpid()), "this /proc is this pid namespace's")
        #expect(GatewayPeerBinding.probe(in: ProcFSProcessTable()) == false)
        #expect(ProcFSProcessTable().lookup(getpid()) == .unavailable)
        #expect(ProcFSProcessTable().session(of: getpid()) == nil)
        #expect(ProcessGroupRecovery.capture(pid: getpid()) == nil)
        let connection = try Connection()
        let leader = try sleeper(inherit: connection.client)
        #expect(ProcessGroupRecovery.capture(pid: leader.pid) == nil)
        let group = ProcessGroupFact(pgid: try #require(ValidatedPGID(leader.pid)), startSeconds: 0, startMicroseconds: 0)
        #expect(GatewayPeerScan.verdict(connection.peer, group: group, in: ProcFSProcessTable()) == .unverifiable)
    }

    /// The gateway may read no other process's descriptors: here because an
    /// AppArmor profile without a `ptrace` rule confines this process (a
    /// seccomp or SELinux policy reads the same). Its own are still
    /// readable, so the self-probe passes, and every decision about another
    /// process cannot tell.
    @Test(.enabled(if: regime == "confined"))
    func aGatewayThatMayNotReadOtherProcessesCannotTell() throws {
        let connection = try Connection()
        let leader = try sleeper(inherit: connection.client)
        guard case .unavailable = ProcFSReader.directory("/proc/\(leader.pid)/fd") else {
            Issue.record("another process's descriptors are readable: this run is not confined")
            return
        }
        #expect(GatewayPeerBinding.probe(in: ProcFSProcessTable()))
        #expect(try verdict(connection.peer, leader.pid) == .unverifiable)
        let group = try #require(ProcessGroupRecovery.capture(pid: leader.pid))
        #expect(GatewayPeerScan.holders(connection.peer, group: group, in: ProcFSProcessTable()) == nil)
    }
}

/// One loopback connection with the client or the listeners built unusually.
private struct Loopback {
    var listeners: [Int32]
    let client: Int32
    let server: Int32
    let peer: GatewayPeer

    /// Nil when `dualStackClient` is asked for and the host has no IPv6.
    init?(dualStackClient: Bool = false, sharedListeners: Bool = false) throws {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = GatewayPeer.loopback
        var listeners: [Int32] = []
        for _ in 0..<(sharedListeners ? 2 : 1) {
            let listener = socket(AF_INET, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
            try #require(listener >= 0)
            listeners.append(listener)
            var on: Int32 = 1
            if sharedListeners {
                try #require(setsockopt(listener, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size)) == 0)
            }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let ready = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listener, $0, length) == 0 && listen(listener, 4) == 0 && getsockname(listener, $0, &length) == 0
                }
            }
            try #require(ready)
        }
        let client: Int32
        let connected: Bool
        if dualStackClient {
            client = socket(AF_INET6, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
            guard client >= 0 else {
                try #require(errno == EAFNOSUPPORT)
                listeners.forEach { _ = Glibc.close($0) }
                return nil
            }
            var off: Int32 = 0
            try #require(setsockopt(client, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size)) == 0)
            var mapped = sockaddr_in6()
            mapped.sin6_family = sa_family_t(AF_INET6)
            mapped.sin6_port = address.sin_port
            try #require(inet_pton(AF_INET6, "::ffff:127.0.0.1", &mapped.sin6_addr) == 1)
            connected = withUnsafePointer(to: &mapped) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(client, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
                }
            }
        } else {
            client = socket(AF_INET, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
            try #require(client >= 0)
            connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
        }
        try #require(connected)
        // Whichever listener the kernel chose has it.
        var waiting = listeners.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
        try #require(poll(&waiting, nfds_t(waiting.count), 20_000) >= 1)
        let ready = try #require(waiting.first { $0.revents & Int16(POLLIN) != 0 })
        let server = accept(ready.fd, nil, nil)
        try #require(server >= 0)
        _ = fcntl(server, F_SETFD, FD_CLOEXEC)
        self.listeners = listeners
        self.client = client
        self.server = server
        peer = try #require(GatewayPeer.of(server))
    }

    /// The client may already be closed by the test; closing it again is harmless here.
    func close() {
        _ = Glibc.close(server)
        listeners.forEach { _ = Glibc.close($0) }
    }
}

/// A connected pair of Unix sockets, close-on-exec.
private struct UnixPair {
    let near: Int32
    let far: Int32

    init() throws {
        var ends: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0, &ends) == 0)
        near = ends[0]
        far = ends[1]
    }

    func close() {
        _ = Glibc.close(near)
        _ = Glibc.close(far)
    }
}

/// One byte with one descriptor attached (`SCM_RIGHTS`). Its buffers are
/// allocated up front, so a forked child sends or receives with libc calls
/// alone. Never freed: a test's worth of bytes.
private struct DescriptorMessage {
    /// `struct cmsghdr` (16 bytes on a 64-bit host), one `int`, padding.
    private static let controlBytes = 24
    private let control = UnsafeMutableRawPointer.allocate(byteCount: controlBytes, alignment: 8)
    private let byte = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
    private let vector = UnsafeMutablePointer<iovec>.allocate(capacity: 1)
    private let header = UnsafeMutablePointer<msghdr>.allocate(capacity: 1)

    init() {
        byte.initialize(to: 0)
        vector.initialize(to: iovec(iov_base: UnsafeMutableRawPointer(byte), iov_len: 1))
        header.initialize(to: msghdr())
        header.pointee.msg_iov = vector
        header.pointee.msg_iovlen = 1
        header.pointee.msg_control = control
    }

    func send(_ descriptor: Int32, over socket: Int32) -> Bool {
        control.storeBytes(of: 20, as: Int.self)  // cmsg_len: header and one int
        control.storeBytes(of: SOL_SOCKET, toByteOffset: 8, as: Int32.self)
        control.storeBytes(of: 1, toByteOffset: 12, as: Int32.self)  // SCM_RIGHTS
        control.storeBytes(of: descriptor, toByteOffset: 16, as: Int32.self)
        header.pointee.msg_controllen = Self.controlBytes
        return sendmsg(socket, header, 0) == 1
    }

    /// The received descriptor, or -1.
    func receive(over socket: Int32) -> Int32 {
        header.pointee.msg_controllen = Self.controlBytes
        guard recvmsg(socket, header, 0) == 1, header.pointee.msg_controllen >= 20,
            control.load(fromByteOffset: 8, as: Int32.self) == SOL_SOCKET,
            control.load(fromByteOffset: 12, as: Int32.self) == 1
        else { return -1 }
        return control.load(fromByteOffset: 16, as: Int32.self)
    }
}

/// libc, declared with fixed arguments so a forked child can call it.
@_silgen_name("syscall")
private func attackSyscall(_ number: Int, _ first: Int, _ second: Int, _ third: Int, _ fourth: Int) -> Int

@_silgen_name("unshare")
private func attackUnshare(_ flags: Int32) -> Int32

@_silgen_name("ioctl")
private func attackIoctl(_ descriptor: Int32, _ request: UInt, _ argument: UnsafeMutableRawPointer) -> Int32
#endif
