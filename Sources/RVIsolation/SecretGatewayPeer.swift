#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Whether the process holding the client end of a gateway connection belongs
/// to the runtime a placeholder was leased to.
enum GatewayPeerVerdict: Equatable, Sendable {
    case member
    /// The runtime's process group holds no socket for this connection: the
    /// placeholder was presented from somewhere else.
    case outsider
    /// The kernel could not answer, or the runtime's group is gone.
    case unverifiable
}

/// The client end of one accepted gateway connection. Loopback is shared by
/// every process on the host, so the port pair is what names the client.
struct GatewayPeer: Equatable, Sendable {
    /// The client socket's local port.
    var port: UInt16
    /// The gateway's port: the client socket's remote port.
    var gatewayPort: UInt16

    /// Nil unless both ends are 127.0.0.1, the only address the gateway binds.
    static func of(_ fd: Int32) -> GatewayPeer? {
        guard let remote = address(fd, getpeername), let local = address(fd, getsockname),
            remote.host == loopback, local.host == loopback
        else { return nil }
        return GatewayPeer(port: remote.port, gatewayPort: local.port)
    }

    static let loopback = inet_addr("127.0.0.1")

    private static func address(
        _ fd: Int32, _ call: (Int32, UnsafeMutablePointer<sockaddr>, UnsafeMutablePointer<socklen_t>) -> Int32
    ) -> (host: in_addr_t, port: UInt16)? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { call(fd, $0, &length) }
        }
        guard named == 0, address.sin_family == sa_family_t(AF_INET) else { return nil }
        return (address.sin_addr.s_addr, UInt16(bigEndian: address.sin_port))
    }
}

/// Decides whether a peer belongs to a runtime.
struct GatewayPeerCheck: Sendable {
    var verify: @Sendable (GatewayPeer, ProcessGroupFact) -> GatewayPeerVerdict
    /// For secrets bound to `binaries`: whether every runtime process
    /// holding the peer's socket runs, or descends from, a pinned binary.
    var binaries: @Sendable (GatewayPeer, ProcessGroupFact, [GatewayBinaryPin]) -> GatewayBinaryVerdict =
        { _, _, _ in .unverifiable }

    /// The peer is a member when a process of the runtime holds the client
    /// socket, found by its port pair. The cage denies the `setsid` and
    /// `setpgid` syscalls but allows `posix_spawn`, whose `SETSID` and
    /// `SETPGROUP` flags move a child out of the leader's group (Node's
    /// `detached: true` does this). The same `SETPGROUP` lets any process
    /// in the leader's session join the group, so the group is not
    /// membership. A runtime's processes are its leader, the live
    /// descendants of its leader, and, when the leader leads a session
    /// (terminal runtimes), that session.
    ///
    /// The scan is the same on both hosts; only the kernel reads differ
    /// (`ProcessTable`: libproc on macOS, `/proc` on Linux).
    static let runtime = GatewayPeerCheck(
        verify: { peer, group in
            GatewayPeerScan.verdict(peer, group: group, in: HostProcessTable.make())
        },
        binaries: { peer, group, pins in
            GatewayPeerScan.binaries(peer, group: group, pins: pins, in: HostProcessTable.make())
        })
}

enum GatewayPeerScan {
    /// Bounds the descendant walk; past it the answer is `unverifiable`.
    static let maximumDescendants = 4_096

    static func binaries(
        _ peer: GatewayPeer, group: ProcessGroupFact, pins: [GatewayBinaryPin], in table: some ProcessTable
    ) -> GatewayBinaryVerdict {
        guard let holders = holders(peer, group: group, in: table) else { return .unverifiable }
        // A forked child inherits the socket; every holder must pass.
        var verdict = GatewayBinaryVerdict.allowed
        for holder in holders {
            switch GatewayBinaryScan.verdict(holder: holder, leader: group.pgid.rawValue, pins: pins, in: table) {
            case .allowed: continue
            case .mismatch: verdict = .mismatch
            case .unverifiable: return .unverifiable
            }
        }
        return verdict
    }

    /// Every runtime process holding the peer's socket: the leader, its
    /// descendants, and the session it leads (group membership alone proves
    /// nothing, as in `verdict`). Nil when any of them could not be read, or
    /// none holds it.
    static func holders(_ peer: GatewayPeer, group: ProcessGroupFact, in table: some ProcessTable) -> [GatewayHolder]? {
        let leader = group.pgid.rawValue
        guard isLeader(leader, of: group, in: table) else { return nil }
        let (parents, complete) = descendants(of: leader, in: table)
        guard complete else { return nil }
        var candidates = Set(parents.keys).union([leader])
        if table.session(of: leader) == leader {
            guard let processes = table.userProcesses() else { return nil }
            candidates.formUnion(processes.filter { table.session(of: $0) == leader })
        }
        var found: [GatewayHolder] = []
        for pid in candidates.sorted() {
            // Read before the descriptors: the ancestor walk compares it, so
            // a pid reused after this point is not taken for the holder.
            switch table.lookup(pid) {
            case .absent: continue
            case .unavailable: return nil
            case .found(let info):
                switch table.holdsSocket(pid, peer) {
                case .some(true):
                    found.append(GatewayHolder(
                        pid: pid, startSeconds: info.startSeconds, startMicroseconds: info.startMicroseconds))
                case .some(false): continue
                case .none: return nil
                }
            }
        }
        return found.isEmpty ? nil : found
    }

    static func verdict(_ peer: GatewayPeer, group: ProcessGroupFact, in table: some ProcessTable) -> GatewayPeerVerdict {
        let leader = group.pgid.rawValue
        // A reused pgid is a different group, and a group whose leader is
        // gone belongs to a runtime that has returned.
        guard isLeader(leader, of: group, in: table) else { return .unverifiable }
        var search = Search(peer: peer)
        // Group membership alone proves nothing: a same-session process can
        // join any group with `POSIX_SPAWN_SETPGROUP`. A holder must be the
        // leader, below it, or in the session it leads. Each match is
        // re-checked after the scan, so a pid that exited and was reused
        // mid-scan does not count.
        if search.finds([leader], in: table, still: { _ in isLeader(leader, of: group, in: table) }) { return .member }
        let (parents, complete) = descendants(of: leader, in: table)
        if complete == false { search.incomplete = true }
        if search.finds(Array(parents.keys), in: table, still: { parent(of: $0, in: table) == parents[$0] }) {
            return .member
        }
        if table.session(of: leader) == leader {
            let listed = table.userProcesses()
            if listed == nil, table.failedListingIsEmptySession == false { search.incomplete = true }
            let session = (listed ?? []).filter { table.session(of: $0) == leader }
            if search.finds(session, in: table, still: { table.session(of: $0) == leader }) { return .member }
        }
        return search.incomplete ? .unverifiable : .outsider
    }

    /// Whether `pid` is still the process `group` recorded as its leader.
    private static func isLeader(_ pid: pid_t, of group: ProcessGroupFact, in table: some ProcessTable) -> Bool {
        guard case .found(let info) = table.lookup(pid) else { return false }
        return info.group == UInt32(pid)
            && Int64(info.startSeconds) == group.startSeconds
            && Int64(info.startMicroseconds) == group.startMicroseconds
    }

    private struct Search {
        let peer: GatewayPeer
        var scanned: Set<pid_t> = []
        var incomplete = false

        mutating func finds(_ pids: [pid_t], in table: some ProcessTable, still member: (pid_t) -> Bool) -> Bool {
            for pid in pids where scanned.insert(pid).inserted {
                switch table.holdsSocket(pid, peer) {
                case .some(true): if member(pid) { return true }
                case .some(false): continue
                case .none: incomplete = true
                }
            }
            return false
        }
    }

    /// Child to parent for every live descendant of `root`; false when the
    /// walk hit its bound or a listing failed.
    private static func descendants(of root: pid_t, in table: some ProcessTable) -> (parents: [pid_t: pid_t], complete: Bool) {
        var parents: [pid_t: pid_t] = [:]
        var pending = [root]
        while let parent = pending.popLast() {
            guard let children = table.children(of: parent) else { return (parents, false) }
            for child in children where child != root && parents[child] == nil {
                guard parents.count < maximumDescendants else { return (parents, false) }
                parents[child] = parent
                pending.append(child)
            }
        }
        return (parents, true)
    }

    private static func parent(of pid: pid_t, in table: some ProcessTable) -> pid_t? {
        guard case .found(let info) = table.lookup(pid) else { return nil }
        return pid_t(info.parent)
    }
}
