#if os(macOS)
import Darwin

/// `ProcessTable` from libproc. These are the reads `GatewayPeerScan` made
/// before the scan was shared with Linux, unchanged.
struct LibprocProcessTable: ProcessTable {
    var failedListingIsEmptySession: Bool { true }

    func lookup(_ pid: pid_t) -> ProcessLookup {
        switch ProcessGroupRecovery.lookup(pid) {
        case .found(let info):
            .found(ProcessIdentity(
                pid: info.pbi_pid, parent: info.pbi_ppid, group: info.pbi_pgid,
                startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec))
        case .absent: .absent
        case .unavailable: .unavailable
        }
    }

    func session(of pid: pid_t) -> pid_t? {
        let session = getsid(pid)
        return session < 0 ? nil : session
    }

    /// Never nil: libproc's child listing reports a failure as no children.
    func children(of pid: pid_t) -> [pid_t]? {
        listedPIDs(proc_listchildpids, pid)
    }

    /// Runtimes run as rv's user, and `proc_listpids` counts bytes.
    func userProcesses() -> [pid_t]? {
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
    func holdsSocket(_ pid: pid_t, _ peer: GatewayPeer) -> Bool? {
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

    func executable(_ pid: pid_t) -> ProcessExecutable? {
        GatewayBinaryScan.executablePath(pid).map(ProcessExecutable.path)
    }

    private func isPeerSocket(_ pid: pid_t, _ fd: Int32, _ peer: GatewayPeer) -> Bool {
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
