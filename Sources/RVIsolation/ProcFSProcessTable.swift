#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One read under `/proc`. `absent` is a path that is gone (the process
/// exited, the descriptor closed); `unavailable` is anything else the
/// kernel refused or a read that could not be finished.
enum ProcFSRead<Value> {
    case value(Value)
    case absent
    case unavailable
}

/// Plain POSIX reads. Nothing here is Linux-only, so it is tested on macOS
/// against an ordinary directory tree.
enum ProcFSReader {
    /// `/proc/net/tcp` on a busy host is a few MB; past this the read fails.
    static let maximumFileBytes = 64 << 20

    static func file(_ path: String) -> ProcFSRead<[UInt8]> {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return failure(errno) }
        defer { close(fd) }
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count == 0 { return .value(bytes) }
            if count < 0 {
                if errno == EINTR { continue }
                return failure(errno)
            }
            bytes += chunk.prefix(count)
            guard bytes.count <= maximumFileBytes else { return .unavailable }
        }
    }

    /// A link's target, which must be UTF-8.
    static func link(_ path: String) -> ProcFSRead<String> {
        var buffer = [CChar](repeating: 0, count: 4 * 1024 + 1)
        let count = readlink(path, &buffer, buffer.count)
        guard count >= 0 else { return failure(errno) }
        // A full buffer may be a truncated target.
        guard count < buffer.count,
            let target = String(validating: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        else { return .unavailable }
        return .value(target)
    }

    /// The entries of `path`; `unavailable` once there are more than `limit`.
    static func directory(_ path: String, limit: Int = .max) -> ProcFSRead<[String]> {
        guard let stream = opendir(path) else { return failure(errno) }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else { return errno == 0 ? .value(names) : failure(errno) }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: pointer.pointee)) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." {
                guard names.count < limit else { return .unavailable }
                names.append(name)
            }
        }
    }

    /// `ESRCH` is a process that exited after its file was opened.
    static func failure<Value>(_ code: Int32) -> ProcFSRead<Value> {
        code == ENOENT || code == ESRCH ? .absent : .unavailable
    }
}

/// `ProcessTable` from Linux `/proc`, read under `root`.
///
/// Matching a connection to its holders: the gateway's accepted socket is
/// `127.0.0.1:gatewayPort <-> 127.0.0.1:port`. `self/net/tcp` and `tcp6` (the
/// tables of the reader's network namespace, which is the gateway's) are
/// searched for the client end (`port -> gatewayPort`, IPv4 or v4-mapped
/// IPv6), and a candidate process holds it when one of its `fd/*` links
/// reads `socket:[<that inode>]`. See `ProcFSParse.clientInode` for which
/// rows count.
///
/// Fails closed: the scan answers `unverifiable` (via `nil`/`unavailable`
/// here) when `/proc` is not this process's (`self` is not our pid), when it
/// hides other users' processes (`hidepid`), when a table or file is
/// unreadable, malformed or truncated, when a descriptor table cannot be
/// read (`EACCES` from a non-dumpable, setuid or other user's process
/// without `CAP_SYS_PTRACE`, or an LSM ptrace rule; Yama gates only attach,
/// not these reads), and when a process changes or exits between the reads
/// that bracket its descriptor scan. Only a process gone before it is
/// looked at is skipped. A zombie is gone (`lookup` says `absent`), as on
/// macOS, unless other threads of it still run.
///
/// A socket registered with an io_uring instance is held by the ring, not
/// by a descriptor: a process holding the ring holds the socket, read from
/// the ring's `fdinfo` (`ProcFSParse.ringFiles`).
///
/// One table serves one decision: it caches the process listing and the
/// socket inode, which are then as old as that decision. Its work is
/// bounded: it makes at most `maximumReads` reads (files, links and
/// directory entries), and every read past that is `unavailable`, so a
/// host with more processes, threads or descriptors than one decision can
/// look at is a decision that cannot tell.
final class ProcFSProcessTable: ProcessTable {
    /// A descriptor scan is threads times descriptors per process; a listing
    /// is one read per process on the host. A million reads is about a
    /// second of `/proc`.
    static let maximumReads = 1 << 20

    let root: String
    let uid: uid_t
    let selfPID: pid_t
    /// `sysconf(_SC_CLK_TCK)`; nil makes every lookup `unavailable`.
    let hz: UInt64?

    /// Reads left for this decision.
    private var reads: Int
    private lazy var own: Bool = isOwnProc()
    private lazy var visible: Bool = own && hidesNoProcess()
    private lazy var parents: [pid_t: [pid_t]]? = listChildren()
    private var resolved: (peer: GatewayPeer, inode: UInt64?)?

    init(
        root: String = "/proc", uid: uid_t = getuid(), selfPID: pid_t = getpid(), hz: UInt64? = clockTicks(),
        maximumReads: Int = ProcFSProcessTable.maximumReads
    ) {
        self.root = root
        self.uid = uid
        self.selfPID = selfPID
        self.hz = hz
        reads = maximumReads
    }

    var failedListingIsEmptySession: Bool { false }

    static func clockTicks() -> UInt64? {
        let ticks = sysconf(Int32(_SC_CLK_TCK))
        return ticks > 0 ? UInt64(ticks) : nil
    }

    func lookup(_ pid: pid_t) -> ProcessLookup {
        // Pids under a `/proc` of another pid namespace name other processes.
        guard pid > 0, let hz, own else { return .unavailable }
        switch readStat(pid) {
        case .absent: return .absent
        case .unavailable: return .unavailable
        case .value(let stat):
            if ProcFSParse.exited(stat) {
                // Linux shows a process whose main thread exited as a zombie
                // while its other threads run: alive while `task` lists more
                // than the main thread.
                switch directory("\(root)/\(pid)/task") {
                case .absent: return .absent
                case .unavailable: return .unavailable
                case .value(let threads): if threads.count <= 1 { return .absent }
                }
            }
            guard stat.pid == UInt32(pid), let start = ProcFSParse.start(ticks: stat.startTicks, hz: hz) else {
                return .unavailable
            }
            return .found(ProcessIdentity(
                pid: stat.pid, parent: stat.parent, group: stat.group,
                startSeconds: start.seconds, startMicroseconds: start.microseconds))
        }
    }

    func session(of pid: pid_t) -> pid_t? {
        guard pid > 0, own, case .value(let stat) = readStat(pid), stat.pid == UInt32(pid) else { return nil }
        return pid_t(bitPattern: stat.session)
    }

    /// From one pass over every process's `stat`. Any `stat` that cannot be
    /// read makes the listing incomplete: that process could be a child.
    func children(of pid: pid_t) -> [pid_t]? {
        parents.map { $0[pid] ?? [] }
    }

    func userProcesses() -> [pid_t]? {
        guard let pids = processes() else { return nil }
        var mine: [pid_t] = []
        for pid in pids where pid > 1 {
            // An exited, unreaped process is no one's, as on macOS.
            switch lookup(pid) {
            case .absent: continue
            case .unavailable: return nil
            case .found: break
            }
            switch file("\(root)/\(pid)/status") {
            case .absent: continue
            case .unavailable: return nil
            case .value(let bytes):
                guard let uids = ProcFSParse.uids(status: bytes) else { return nil }
                // Real, effective or saved: a setuid child of this user is
                // kept, so its unreadable descriptors make the scan incomplete.
                if uids.prefix(3).contains(uid) { mine.append(pid) }
            }
        }
        return mine
    }

    func holdsSocket(_ pid: pid_t, _ peer: GatewayPeer) -> Bool? {
        guard let inode = socketInode(peer), case .found(let before) = lookup(pid) else { return nil }
        // The process's table, then each thread's: a thread that unshared its
        // table (`unshare(CLONE_FILES)`) holds what only it has, and a process
        // whose main thread exited keeps its descriptors in the others.
        guard var holds = holds(inode, in: "\(root)/\(pid)") else { return nil }
        if holds == false {
            guard case .value(let threads) = directory("\(root)/\(pid)/task") else { return nil }
            for thread in threads where thread != String(pid) {
                guard let held = self.holds(inode, in: "\(root)/\(pid)/task/\(thread)") else { return nil }
                if held {
                    holds = true
                    break
                }
            }
        }
        // The same process before and after: a pid reused in between, or one
        // that exited mid-scan (perhaps the holder), is not an answer.
        guard case .found(let after) = lookup(pid), after == before else { return nil }
        return holds
    }

    /// Whether the descriptor table under `task` (a process's or a thread's
    /// directory) holds socket `inode`: an `fd` link names it, or an
    /// io_uring instance in the table has it registered. Nil when the table
    /// or a ring could not be read (a thread or process gone mid-scan
    /// included).
    private func holds(_ inode: UInt64, in task: String) -> Bool? {
        guard case .value(let names) = directory(task + "/fd") else { return nil }
        for name in names {
            switch link("\(task)/fd/\(name)") {
            case .absent: continue  // closed since the listing
            case .unavailable: return nil
            case .value(let target):
                if ProcFSParse.socketInode(link: target) == inode { return true }
                guard target == ProcFSParse.ringLink else { continue }
                switch ringHolds(inode, fdinfo: "\(task)/fdinfo/\(name)") {
                case .some(true): return true
                case .some(false): continue
                case .none: return nil
                }
            }
        }
        return false
    }

    /// Whether the io_uring instance described by `fdinfo` has socket
    /// `inode` registered. Nil when its files cannot be read, or one of them
    /// is another ring (whose own files this does not follow).
    private func ringHolds(_ inode: UInt64, fdinfo: String) -> Bool? {
        switch file(fdinfo) {
        case .absent: return false  // closed since the listing
        case .unavailable: return nil
        case .value(let bytes):
            guard let files = ProcFSParse.ringFiles(fdinfo: bytes) else { return nil }
            if files.contains(where: { ProcFSParse.socketInode(link: $0) == inode }) { return true }
            return files.contains { Array($0) == Array(ProcFSParse.ringLink.utf8) } ? nil : false
        }
    }

    func executable(_ pid: pid_t) -> ProcessExecutable? {
        guard case .found(let before) = lookup(pid) else { return nil }
        let link = "\(root)/\(pid)/exe"
        // `stat` follows the link to the file the process runs, deleted or not.
        guard case .value(let path) = self.link(link), let running = GatewayBinaryPin.identity(link),
            case .found(let after) = lookup(pid), after == before
        else { return nil }
        return .file(path: path, running: running)
    }

    private func readStat(_ pid: pid_t) -> ProcFSRead<ProcFSParse.Stat> {
        switch file("\(root)/\(pid)/stat") {
        case .absent: return .absent
        case .unavailable: return .unavailable
        case .value(let bytes): return ProcFSParse.stat(bytes).map { .value($0) } ?? .unavailable
        }
    }

    /// Every pid under `root`, or nil when `root` is not a `/proc` that shows
    /// this process and every other.
    private func processes() -> [pid_t]? {
        guard visible, case .value(let names) = directory(root) else { return nil }
        return names.compactMap { name in
            guard name.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
                let pid = pid_t(name), pid > 0
            else { return nil }
            return pid
        }
    }

    private func listChildren() -> [pid_t: [pid_t]]? {
        guard let pids = processes() else { return nil }
        var map: [pid_t: [pid_t]] = [:]
        for pid in pids where pid > 1 {
            switch lookup(pid) {
            case .absent: continue
            case .unavailable: return nil
            case .found(let process): map[pid_t(bitPattern: process.parent), default: []].append(pid)
            }
        }
        return map
    }

    /// `self` must be this process: a `/proc` of another pid namespace
    /// numbers processes differently, so nothing read from it is about the
    /// pids this process knows.
    private func isOwnProc() -> Bool {
        guard case .value(let me) = link("\(root)/self") else { return false }
        return me == String(selfPID)
    }

    /// The mount must not hide processes: then a listing is not every process.
    private func hidesNoProcess() -> Bool {
        guard case .value(let mounts) = file("\(root)/self/mountinfo") else { return false }
        return ProcFSParse.hidesProcesses(mountinfo: mounts, mountPoint: root) == false
    }

    // MARK: - Bounded reads

    /// Takes `count` reads from this decision's allowance; false once it is spent.
    private func spend(_ count: Int = 1) -> Bool {
        reads -= count
        return reads >= 0
    }

    private func file(_ path: String) -> ProcFSRead<[UInt8]> {
        spend() ? ProcFSReader.file(path) : .unavailable
    }

    private func link(_ path: String) -> ProcFSRead<String> {
        spend() ? ProcFSReader.link(path) : .unavailable
    }

    /// One read for the directory and one for each entry.
    private func directory(_ path: String) -> ProcFSRead<[String]> {
        guard spend() else { return .unavailable }
        let listed = ProcFSReader.directory(path, limit: reads)
        if case .value(let names) = listed { _ = spend(names.count) }
        return listed
    }

    private func socketInode(_ peer: GatewayPeer) -> UInt64? {
        if let resolved, resolved.peer == peer { return resolved.inode }
        let inode = readSocketInode(peer)
        resolved = (peer, inode)
        return inode
    }

    private func readSocketInode(_ peer: GatewayPeer) -> UInt64? {
        guard visible, case .value(let tcp) = file("\(root)/self/net/tcp"),
            let rows = ProcFSParse.sockets(tcp)
        else { return nil }
        var rows6: [ProcFSParse.SocketRow] = []
        switch file("\(root)/self/net/tcp6") {
        case .absent: break  // IPv6 disabled
        case .unavailable: return nil
        case .value(let bytes):
            guard let parsed = ProcFSParse.sockets(bytes) else { return nil }
            rows6 = parsed
        }
        return ProcFSParse.clientInode(rows + rows6, port: peer.port, gatewayPort: peer.gatewayPort)
    }
}
