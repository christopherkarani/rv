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
    /// Whether `verify` can ever answer `member` here. Launch paths that
    /// would otherwise hand out placeholders no request could spend (or, on
    /// an unbound gateway, any process could) refuse when this is false.
    var bindsProcessGroups = false

    /// Set where `runtime` has a kernel check behind it. Linux has none yet.
    static var platformBindsProcessGroups: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// The peer is a member when a process of the runtime holds the client
    /// socket, found by its port pair. The cage denies the `setsid` and
    /// `setpgid` syscalls but allows `posix_spawn`, whose `SETSID` and
    /// `SETPGROUP` flags move a child out of the leader's group (Node's
    /// `detached: true` does this). The same `SETPGROUP` lets any process
    /// in the leader's session join the group, so the group is not
    /// membership. A runtime's processes are its leader, the live
    /// descendants of its leader, and, when the leader leads a session
    /// (terminal runtimes), that session.
    static let runtime = GatewayPeerCheck(
        verify: { peer, group in
            #if os(macOS)
            GatewayPeerScan.verdict(peer, group: group)
            #else
            // No libproc; contained launches are refused on Linux before exec,
            // so no runtime there holds a gateway placeholder.
            .unverifiable
            #endif
        },
        binaries: { peer, group, pins in
            #if os(macOS)
            guard let holders = GatewayPeerScan.holders(peer, group: group) else { return .unverifiable }
            // A forked child inherits the socket; every holder must pass.
            var verdict = GatewayBinaryVerdict.allowed
            for holder in holders {
                switch GatewayBinaryScan.verdict(holder: holder, leader: group.pgid.rawValue, pins: pins) {
                case .allowed: continue
                case .mismatch: verdict = .mismatch
                case .unverifiable: return .unverifiable
                }
            }
            return verdict
            #else
            .unverifiable
            #endif
        },
        bindsProcessGroups: platformBindsProcessGroups)
}

#if os(macOS)
enum GatewayPeerScan {
    /// Bounds the descendant walk; past it the answer is `unverifiable`.
    static let maximumDescendants = 4_096

    /// Every runtime process holding the peer's socket: the leader, its
    /// descendants, and the session it leads (group membership alone proves
    /// nothing, as in `verdict`). Nil when any of them could not be read, or
    /// none holds it.
    static func holders(_ peer: GatewayPeer, group: ProcessGroupFact) -> [GatewayHolder]? {
        let leader = group.pgid.rawValue
        guard isLeader(leader, of: group) else { return nil }
        let (parents, complete) = descendants(of: leader)
        guard complete else { return nil }
        var candidates = Set(parents.keys).union([leader])
        if getsid(leader) == leader {
            guard let processes = userProcesses() else { return nil }
            candidates.formUnion(processes.filter { getsid($0) == leader })
        }
        var found: [GatewayHolder] = []
        for pid in candidates.sorted() {
            // Read before the descriptors: the ancestor walk compares it, so
            // a pid reused after this point is not taken for the holder.
            switch ProcessGroupRecovery.lookup(pid) {
            case .absent: continue
            case .unavailable: return nil
            case .found(let info):
                switch holdsSocket(pid, peer) {
                case .some(true):
                    found.append(GatewayHolder(
                        pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec))
                case .some(false): continue
                case .none: return nil
                }
            }
        }
        return found.isEmpty ? nil : found
    }

    static func verdict(_ peer: GatewayPeer, group: ProcessGroupFact) -> GatewayPeerVerdict {
        let leader = group.pgid.rawValue
        // A reused pgid is a different group, and a group whose leader is
        // gone belongs to a runtime that has returned.
        guard isLeader(leader, of: group) else { return .unverifiable }
        var search = Search(peer: peer)
        // Group membership alone proves nothing: a same-session process can
        // join any group with `POSIX_SPAWN_SETPGROUP`. A holder must be the
        // leader, below it, or in the session it leads. Each match is
        // re-checked after the scan, so a pid that exited and was reused
        // mid-scan does not count.
        if search.finds([leader], still: { _ in isLeader(leader, of: group) }) { return .member }
        let (parents, complete) = descendants(of: leader)
        if complete == false { search.incomplete = true }
        if search.finds(Array(parents.keys), still: { parent(of: $0) == parents[$0] }) { return .member }
        if getsid(leader) == leader {
            let session = (userProcesses() ?? []).filter { getsid($0) == leader }
            if search.finds(session, still: { getsid($0) == leader }) { return .member }
        }
        return search.incomplete ? .unverifiable : .outsider
    }

    /// Whether `pid` is still the process `group` recorded as its leader.
    private static func isLeader(_ pid: pid_t, of group: ProcessGroupFact) -> Bool {
        guard case .found(let info) = ProcessGroupRecovery.lookup(pid) else { return false }
        return info.pbi_pgid == UInt32(pid)
            && Int64(info.pbi_start_tvsec) == group.startSeconds
            && Int64(info.pbi_start_tvusec) == group.startMicroseconds
    }

    private struct Search {
        let peer: GatewayPeer
        var scanned: Set<pid_t> = []
        var incomplete = false

        mutating func finds(_ pids: [pid_t], still member: (pid_t) -> Bool) -> Bool {
            for pid in pids where scanned.insert(pid).inserted {
                switch GatewayPeerScan.holdsSocket(pid, peer) {
                case .some(true): if member(pid) { return true }
                case .some(false): continue
                case .none: incomplete = true
                }
            }
            return false
        }
    }

    /// Child to parent for every live descendant of `root`; false when the
    /// walk hit its bound.
    private static func descendants(of root: pid_t) -> (parents: [pid_t: pid_t], complete: Bool) {
        var parents: [pid_t: pid_t] = [:]
        var pending = [root]
        while let parent = pending.popLast() {
            for child in listedPIDs(proc_listchildpids, parent) where child != root && parents[child] == nil {
                guard parents.count < maximumDescendants else { return (parents, false) }
                parents[child] = parent
                pending.append(child)
            }
        }
        return (parents, true)
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        guard case .found(let info) = ProcessGroupRecovery.lookup(pid) else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// This user's processes. Runtimes run as rv's user, and `proc_listpids`
    /// counts bytes.
    private static func userProcesses() -> [pid_t]? {
        let uid = getuid()
        let estimate = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard estimate > 0 else { return nil }
        let stride = MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: Int(estimate) / stride + 64)
        let bytes = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY), uid, $0.baseAddress, Int32($0.count)) }
        guard bytes > 0 else { return nil }
        return pids.prefix(min(Int(bytes) / stride, pids.count)).filter { $0 > 1 }
    }

    /// Nil when this process's descriptors could not be read; an exited
    /// process holds nothing.
    private static func holdsSocket(_ pid: pid_t, _ peer: GatewayPeer) -> Bool? {
        errno = 0
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return errno == ESRCH ? false : nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        errno = 0
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return errno == ESRCH ? false : nil }
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            if isPeerSocket(pid, fd.proc_fd, peer) { return true }
        }
        return false
    }

    private static func isPeerSocket(_ pid: pid_t, _ fd: Int32, _ peer: GatewayPeer) -> Bool {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.stride)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
            info.psi.soi_family == AF_INET, info.psi.soi_kind == Int32(SOCKINFO_TCP)
        else { return false }
        let inet = info.psi.soi_proto.pri_tcp.tcpsi_ini
        // A connected 4-tuple exists once on the host while the gateway holds
        // its end, so a match is the other end of this connection.
        return inet.insi_vflag & UInt8(INI_IPV4) != 0
            && UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_lport)) == peer.port
            && UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_fport)) == peer.gatewayPort
            && inet.insi_laddr.ina_46.i46a_addr4.s_addr == GatewayPeer.loopback
            && inet.insi_faddr.ina_46.i46a_addr4.s_addr == GatewayPeer.loopback
    }
}
#endif
