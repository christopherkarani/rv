#if os(Linux)
import Glibc
import Foundation
import Synchronization
import Testing
@testable import RVIsolation

/// The real `/proc` path end to end: this test process, and bash process
/// groups it spawns, against loopback connections it makes. Assertions are
/// on identity, never on durations; every wait has a 20 s deadline only so a
/// broken run fails instead of hanging.
@Suite("Secret gateway Linux peer binding", .serialized)
struct SecretGatewayLinuxPeerTests {
    /// One loopback connection held in this process. `peer` names it as the
    /// gateway would, from the accepted end.
    final class Connection {
        let listener: Int32
        let client: Int32
        let server: Int32
        let peer: GatewayPeer

        init() throws {
            // Locals: a closure may not capture `self` before every member is set.
            let listener = try Self.socket()
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Glibc.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            try #require(bound == 0)
            try #require(listen(listener, 4) == 0)
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
            }
            try #require(named == 0)
            let client = try Self.socket()
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            try #require(connected == 0)
            let server = accept(listener, nil, nil)
            try #require(server >= 0)
            // Close-on-exec, so only a child given it explicitly holds it.
            _ = fcntl(server, F_SETFD, FD_CLOEXEC)
            peer = try #require(GatewayPeer.of(server))
            self.listener = listener
            self.client = client
            self.server = server
        }

        deinit {
            close(client)
            close(server)
            close(listener)
        }

        private static func socket() throws -> Int32 {
            let fd = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
            try #require(fd >= 0)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            return fd
        }
    }

    /// `/bin/bash -c script bash arguments…`, leading a new process group,
    /// with `inherit` (if any) as its descriptor 3.
    final class Leader {
        let pid: pid_t

        init(_ script: String, arguments: [String] = [], inherit: Int32? = nil) throws {
            var actions = posix_spawn_file_actions_t()
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            if let inherit {
                // dup2 onto itself would keep close-on-exec.
                try #require(inherit != 3)
                try #require(posix_spawn_file_actions_adddup2(&actions, inherit, 3) == 0)
            }
            var attributes = posix_spawnattr_t()
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            try #require(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0)
            try #require(posix_spawnattr_setpgroup(&attributes, 0) == 0)
            var argv: [UnsafeMutablePointer<CChar>?] = (["/bin/bash", "-c", script, "bash"] + arguments).map { strdup($0) }
                + [nil]
            defer { argv.forEach { free($0) } }
            var spawned: pid_t = 0
            try #require(posix_spawn(&spawned, "/bin/bash", &actions, &attributes, &argv, environ) == 0)
            pid = spawned
        }

        private var reaped = false

        /// Waits for the leader; its pid is then never signalled again.
        func reap() -> Int32? {
            var status: Int32 = 0
            guard waitpid(pid, &status, 0) == pid else { return nil }
            reaped = true
            return status
        }

        deinit {
            guard reaped == false else { return }
            kill(-pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
    }

    final class Scratch {
        let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-linux-peer-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        func fifo(_ name: String) throws -> String {
            let path = directory.appendingPathComponent(name).path
            try #require(mkfifo(path, 0o600) == 0)
            return path
        }

        func path(_ name: String) -> String { directory.appendingPathComponent(name).path }
    }

    /// A forked copy of this process, leading a new process group, that
    /// closes every descriptor above 2 but `keep` and runs `body`. Between
    /// fork and `body` the child makes only libc calls on values set up
    /// before the fork; `body` must do the same.
    final class Forked {
        let pid: pid_t
        private var reaped = false

        init(keeping keep: [Int32], _ body: () -> Never) throws {
            var limit = rlimit()
            try #require(getrlimit(Int32(RLIMIT_NOFILE.rawValue), &limit) == 0)
            let top = Int32(clamping: min(limit.rlim_cur, 1 << 16))
            let child = linuxPeerFork()
            try #require(child >= 0)
            if child == 0 {
                _ = setpgid(0, 0)
                var fd: Int32 = 3
                while fd < top {
                    var kept = false
                    var index = 0
                    while index < keep.count {
                        if keep[index] == fd { kept = true }
                        index += 1
                    }
                    if kept == false { _ = close(fd) }
                    fd += 1
                }
                body()
            }
            // Also from here, so the group exists before the caller looks.
            _ = setpgid(child, child)
            pid = child
        }

        /// The wait status once the child has exited; nil if it is still
        /// running after the deadline.
        func reap() -> Int32? {
            var status: Int32 = 0
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if waitpid(pid, &status, WNOHANG) == pid {
                    reaped = true
                    return status
                }
                usleep(20_000)
            }
            return nil
        }

        deinit {
            guard reaped == false else { return }
            kill(-pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
    }

    /// One pipe, both ends close-on-exec.
    struct Channel {
        let read: Int32
        let write: Int32

        init() throws {
            var ends: [Int32] = [-1, -1]
            try #require(pipe(&ends) == 0)
            read = ends[0]
            write = ends[1]
            _ = fcntl(read, F_SETFD, FD_CLOEXEC)
            _ = fcntl(write, F_SETFD, FD_CLOEXEC)
        }

        func close() {
            _ = Glibc.close(read)
            _ = Glibc.close(write)
        }

        /// One byte, waiting at most 20 s.
        func receive() throws -> UInt8 {
            var state = pollfd(fd: read, events: Int16(POLLIN), revents: 0)
            try #require(poll(&state, 1, 20_000) == 1)
            var byte: UInt8 = 0
            try #require(Glibc.read(read, &byte, 1) == 1)
            return byte
        }
    }

    /// The `/proc/<pid>/stat` the kernel shows now.
    private func procStat(_ pid: pid_t) -> ProcFSParse.Stat? {
        guard case .value(let bytes) = ProcFSReader.file("/proc/\(pid)/stat") else { return nil }
        return ProcFSParse.stat(bytes)
    }

    private func entries(_ path: String) -> [String]? {
        guard case .value(let names) = ProcFSReader.directory(path) else { return nil }
        return names
    }

    /// Whether a descriptor table under `/proc` links socket `inode`.
    private func links(_ inode: UInt64, in table: String) -> Bool {
        (entries(table) ?? []).contains { name in
            guard case .value(let target) = ProcFSReader.link(table + "/" + name) else { return false }
            return ProcFSParse.socketInode(link: target) == inode
        }
    }

    private func inode(_ fd: Int32) throws -> UInt64 {
        var info = Glibc.stat()
        try #require(fstat(fd, &info) == 0)
        return UInt64(info.st_ino)
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if condition() { return true }
            usleep(20_000)
        }
        return condition()
    }

    /// Writes once a reader has the FIFO open (never blocks).
    private func send(_ text: String, to fifo: String) throws {
        var fd: Int32 = -1
        try #require(waitUntil {
            fd = open(fifo, O_WRONLY | O_NONBLOCK)
            return fd >= 0
        })
        defer { close(fd) }
        let bytes = Array(text.utf8)
        try #require(write(fd, bytes, bytes.count) == bytes.count)
    }

    /// The leader's children, once it has one.
    private func children(of leader: pid_t) throws -> [pid_t] {
        var found: [pid_t] = []
        try #require(waitUntil {
            found = ProcFSProcessTable().children(of: leader) ?? []
            return found.isEmpty == false
        })
        return found
    }

    // MARK: - The table reads this process

    @Test func theTableReadsThisProcessAsTheKernelDoes() throws {
        let table = ProcFSProcessTable()
        guard case .found(let me) = table.lookup(getpid()) else {
            Issue.record("this process is not readable")
            return
        }
        #expect(me.pid == UInt32(getpid()))
        #expect(me.parent == UInt32(getppid()))
        #expect(me.group == UInt32(getpgrp()))
        #expect(table.session(of: getpid()) == getsid(0))
        #expect(table.userProcesses()?.contains(getpid()) == true)
        let executable = try #require(table.executable(getpid()))
        guard case .file(let path, let running) = executable else {
            Issue.record("expected a /proc/self/exe identity")
            return
        }
        let pinned = try GatewayBinaryPin.pin(path).get()
        #expect(pinned.matches(executable))
        #expect(pinned.sameFile(running))
    }

    // MARK: - Membership

    /// The leader holds the client socket on fd 3 and its forked child
    /// inherits it: both are holders, and each must pass a binary binding.
    @Test func theLeaderAndItsForkedChildBothHoldTheSharedSocket() throws {
        let scratch = try Scratch()
        let connection = try Connection()
        let leader = try Leader(#"/bin/sleep 300 & read -r _ < "$1""#, arguments: [try scratch.fifo("hold")],
            inherit: connection.client)
        let group = try #require(ProcessGroupRecovery.capture(pid: leader.pid))
        let child = try #require(try children(of: leader.pid).first)

        #expect(GatewayPeerScan.verdict(connection.peer, group: group, in: ProcFSProcessTable()) == .member)
        let holders = try #require(GatewayPeerScan.holders(connection.peer, group: group, in: ProcFSProcessTable()))
        #expect(holders.map(\.pid) == [leader.pid, child].sorted())

        // Whether or not the child has exec'd sleep yet, bash is its parent.
        let bash = try GatewayBinaryPin.pin("/bin/bash").get()
        let sleep = try GatewayBinaryPin.pin("/bin/sleep").get()
        #expect(GatewayPeerScan.binaries(connection.peer, group: group, pins: [bash], in: ProcFSProcessTable())
            == .allowed)
        #expect(GatewayPeerScan.binaries(connection.peer, group: group, pins: [sleep], in: ProcFSProcessTable())
            == .mismatch)
    }

    @Test func aConnectionTheRuntimeDoesNotHoldIsAnOutsider() throws {
        let scratch = try Scratch()
        let connection = try Connection()
        let leader = try Leader(#"/bin/sleep 300 & read -r _ < "$1""#, arguments: [try scratch.fifo("hold")])
        let group = try #require(ProcessGroupRecovery.capture(pid: leader.pid))
        _ = try children(of: leader.pid)
        #expect(GatewayPeerScan.verdict(connection.peer, group: group, in: ProcFSProcessTable()) == .outsider)
        var stale = group
        stale.startMicroseconds += 1
        #expect(GatewayPeerScan.verdict(connection.peer, group: stale, in: ProcFSProcessTable()) == .unverifiable)
    }

    /// Listed by the scan, then gone before its descriptors were read: it
    /// could have been the holder. A fresh scan no longer lists it.
    @Test func aChildThatExitsMidScanIsUnverifiableNotOutsider() throws {
        let scratch = try Scratch()
        let connection = try Connection()
        let leader = try Leader(#"/bin/sleep 300 & read -r _ < "$1""#, arguments: [try scratch.fifo("hold")])
        let group = try #require(ProcessGroupRecovery.capture(pid: leader.pid))
        let child = try #require(try children(of: leader.pid).first)
        let table = ProcFSProcessTable()
        #expect(table.children(of: leader.pid) == [child])
        kill(child, SIGKILL)
        // Reaped by bash, or a zombie: either way the table reports it gone.
        try #require(waitUntil { ProcFSProcessTable().lookup(child) == .absent })
        #expect(GatewayPeerScan.verdict(connection.peer, group: group, in: table) == .unverifiable)
        #expect(GatewayPeerScan.verdict(connection.peer, group: group, in: ProcFSProcessTable()) == .outsider)
    }

    // MARK: - Through the gateway

    /// The runtime's own request is served; the same placeholder from this
    /// process (outside the runtime) is refused as misuse.
    @Test func theGatewayServesItsRuntimeAndRefusesTheHost() throws {
        let scratch = try Scratch()
        let go = try scratch.fifo("go")
        let out = scratch.path("out")
        let upstream = RecordingUpstream(status: 200)
        let audit = AuditRecords()
        let gateway = SecretGateway(transport: upstream.transport, peers: .runtime, audit: audit.record)
        defer { gateway.stop() }
        let port = try gateway.start().get()
        let script = #"""
            read -r port placeholder < "$1"
            exec 3<>"/dev/tcp/127.0.0.1/$port"
            printf 'GET /s/OPENAI_API_KEY/models HTTP/1.1\r\nAuthorization: Bearer %s\r\n\r\n' "$placeholder" >&3
            IFS= read -r line <&3
            printf '%s' "${line:9:3}" > "$2"
            read -r _ < "$1"
            """#
        let leader = try Leader(script, arguments: [go, out])
        let group = try #require(ProcessGroupRecovery.capture(pid: leader.pid))
        let placeholder = SecretPlaceholder.mint(prefix: "sk-")
        gateway.register(placeholder, entry: SecretGateway.Entry(
            secret: "OPENAI_API_KEY", prefix: "sk-", value: try #require(SecretValue("sk-live-REAL-0123456789")),
            upstream: try #require(URL(string: "https://api.example.com/v1")), fingerprint: "abcd", runtime: "R1",
            surfaces: [.header], processGroup: group))
        try send("\(port) \(placeholder.text)\n", to: go)
        var status = ""
        try #require(waitUntil {
            status = (try? String(contentsOfFile: out, encoding: .utf8)) ?? ""
            return status.count == 3
        })
        #expect(status == "200")
        #expect(upstream.requests.count == 1)

        let response = try gatewayExchange(port: port,
            "GET /s/OPENAI_API_KEY/models HTTP/1.1\r\nAuthorization: Bearer \(placeholder.text)\r\n\r\n")
        #expect(response.status == 403)
        #expect(audit.items.withLock { $0.last?.refusal?.code } == "runtimeMismatch")
        #expect(upstream.requests.count == 1)
    }

    // MARK: - Group recovery

    @Test func aRecordedGroupIsKilledOnlyWhileItsLeaderIsTheSameProcess() throws {
        let leader = try Leader("exec /bin/sleep 300")
        let fact = try #require(ProcessGroupRecovery.capture(pid: leader.pid))
        let reused = RecordedProcessGroup(
            runtime: UUID(), pgid: fact.pgid, startSeconds: fact.startSeconds,
            startMicroseconds: fact.startMicroseconds &+ 1)
        guard case .success = ProcessGroupRecovery.terminate(reused) else {
            Issue.record("a different start time is a different process: nothing to stop")
            return
        }
        #expect(kill(leader.pid, 0) == 0)
        let owned = RecordedProcessGroup(
            runtime: UUID(), pgid: fact.pgid, startSeconds: fact.startSeconds,
            startMicroseconds: fact.startMicroseconds)
        guard case .success = ProcessGroupRecovery.terminate(owned) else {
            Issue.record("the recorded group was not stopped")
            return
        }
        let status = try #require(leader.reap())
        #expect(status & 0x7F == SIGKILL)
    }

    /// Linux shows a process whose main thread exited as a zombie while its
    /// other threads run. It is still the group: found, kept in the tree,
    /// a member through the thread's descriptors, and stopped by recovery
    /// (which once read it as gone and reported success without a signal).
    @Test func aProcessWhoseMainThreadExitedIsAliveAMemberAndStopped() throws {
        let connection = try Connection()
        let child = try Forked(keeping: [connection.client]) {
            var thread = pthread_t()
            _ = pthread_create(&thread, nil, { _ in while true { pause() } }, nil)
            pthread_exit(nil)
        }
        try #require(waitUntil {
            guard let state = procStat(child.pid), ProcFSParse.exited(state) else { return false }
            return entries("/proc/\(child.pid)/task")?.count == 2
        })
        let table = ProcFSProcessTable()
        guard case .found(let leader) = table.lookup(child.pid) else {
            Issue.record("a process with a running thread read as gone")
            return
        }
        #expect(leader.group == UInt32(child.pid))
        #expect(table.children(of: getpid())?.contains(child.pid) == true)
        // Its descriptors are only in the running thread's table.
        #expect(links(try inode(connection.client), in: "/proc/\(child.pid)/fd") == false)
        let group = try #require(ProcessGroupRecovery.capture(pid: child.pid))
        #expect(GatewayPeerScan.verdict(connection.peer, group: group, in: ProcFSProcessTable()) == .member)
        // No main thread, no `exe` link: a binary binding cannot tell.
        #expect(table.executable(child.pid) == nil)
        let bash = try GatewayBinaryPin.pin("/bin/bash").get()
        #expect(GatewayPeerScan.binaries(connection.peer, group: group, pins: [bash], in: ProcFSProcessTable())
            == .unverifiable)

        let recorded = RecordedProcessGroup(
            runtime: UUID(), pgid: group.pgid, startSeconds: group.startSeconds,
            startMicroseconds: group.startMicroseconds)
        guard case .success = ProcessGroupRecovery.terminate(recorded) else {
            Issue.record("the group was not stopped")
            return
        }
        // Dead, unreaped, no thread left: now it is gone.
        #expect(ProcFSProcessTable().lookup(child.pid) == .absent)
        let status = try #require(child.reap(), "terminate reported success but the process still runs")
        #expect(status & 0x7F == SIGKILL)
    }

    /// A thread that took its own descriptor table (`unshare(CLONE_FILES)`)
    /// keeps the socket after the process's table closed it: it is the holder.
    @Test func aThreadWithItsOwnDescriptorTableHoldsTheSocket() throws {
        let connection = try Connection()
        let report = try Channel()
        let inner = try Channel()
        defer {
            report.close()
            inner.close()
        }
        let signal = UnsafeMutableRawPointer(bitPattern: Int(inner.write))
        let client = connection.client
        let child = try Forked(keeping: [client, report.write, inner.read, inner.write]) {
            var thread = pthread_t()
            _ = pthread_create(&thread, nil, { argument in
                let channel = Int32(truncatingIfNeeded: Int(bitPattern: argument))
                var result: UInt8 = 0
                // CLONE_FILES (<sched.h> declares it only under _GNU_SOURCE).
                if linuxPeerUnshare(0x0000_0400) != 0 { result = UInt8(truncatingIfNeeded: errno == 0 ? 0x7F : errno) }
                _ = write(channel, &result, 1)
                while true { pause() }
            }, signal)
            var result: UInt8 = 0xFF
            _ = read(inner.read, &result, 1)
            if result == 0 { _ = close(client) }
            _ = write(report.write, &result, 1)
            while true { pause() }
        }
        let result = try report.receive()
        if result == UInt8(EPERM) {
            // Docker's default seccomp profile refuses `unshare` without CAP_SYS_ADMIN.
            print("skipped: unshare(CLONE_FILES) is refused here (EPERM)")
            return
        }
        try #require(result == 0, "unshare failed with errno \(result)")
        let socket = try inode(client)
        #expect(links(socket, in: "/proc/\(child.pid)/fd") == false)
        #expect((entries("/proc/\(child.pid)/task") ?? []).contains { links(socket, in: "/proc/\(child.pid)/task/\($0)/fd") })
        #expect(ProcFSProcessTable().holdsSocket(child.pid, connection.peer) == true)
        let group = try #require(ProcessGroupRecovery.capture(pid: child.pid))
        #expect(GatewayPeerScan.verdict(connection.peer, group: group, in: ProcFSProcessTable()) == .member)
    }

    /// A child running as another user (uid 65534) whose descriptors this
    /// root process may not read: Docker drops `CAP_SYS_PTRACE`, so the read
    /// is `EACCES`. It might hold the socket, so an empty scan cannot say
    /// outsider; a holder found earlier (the leader) still makes a member,
    /// but the full holder set needed for a binary binding cannot be read.
    @Test(.enabled(if: getuid() == 0 && FileManager.default.isExecutableFile(atPath: "/usr/bin/setpriv"),
        "needs root to drop to another uid with setpriv"),
        arguments: [false, true])
    func aChildOfAnotherUserWhoseDescriptorsAreUnreadable(leaderHolds: Bool) throws {
        let scratch = try Scratch()
        let connection = try Connection()
        let leader = try Leader(
            #"/usr/bin/setpriv --reuid=65534 --regid=65534 --clear-groups /bin/sleep 300 & read -r _ < "$1""#,
            arguments: [try scratch.fifo("hold")], inherit: leaderHolds ? connection.client : nil)
        let group = try #require(ProcessGroupRecovery.capture(pid: leader.pid))
        let child = try #require(try children(of: leader.pid).first)
        try #require(waitUntil {
            guard case .value(let status) = ProcFSReader.file("/proc/\(child)/status") else { return false }
            return ProcFSParse.uids(status: status)?.first == 65534
        })
        let refused: Bool
        switch ProcFSReader.directory("/proc/\(child)/fd") {
        case .value: refused = false
        case .unavailable: refused = true
        case .absent:
            Issue.record("the child exited")
            return
        }
        let bash = try GatewayBinaryPin.pin("/bin/bash").get()
        let verdict = GatewayPeerScan.verdict(connection.peer, group: group, in: ProcFSProcessTable())
        let binaries = GatewayPeerScan.binaries(connection.peer, group: group, pins: [bash], in: ProcFSProcessTable())
        switch (leaderHolds, refused) {
        case (true, true):
            #expect(verdict == .member)
            #expect(binaries == .unverifiable)
        case (true, false):
            #expect(verdict == .member)
            // The child holds it too and runs sleep (bash is its parent).
            #expect(binaries == .allowed)
        case (false, true):
            #expect(verdict == .unverifiable)
            #expect(binaries == .unverifiable)
        case (false, false):
            #expect(verdict == .outsider)
            #expect(binaries == .unverifiable)
        }
    }

    @Test func pidfdsOpenOnThisKernel() throws {
        guard case .descriptor(let descriptor) = PidFD.open(getpid()) else {
            Issue.record("pidfd_open is unavailable; group recovery falls back to identity-checked kill")
            return
        }
        defer { close(descriptor) }
        #expect(PidFD.signal(descriptor, 0))
        let leader = try Leader("exit 0")
        _ = try #require(leader.reap())
        #expect(PidFD.open(leader.pid) == .gone)
    }
}

/// The libc symbols; the children above call nothing Swift-level.
@_silgen_name("fork")
private func linuxPeerFork() -> pid_t

@_silgen_name("unshare")
private func linuxPeerUnshare(_ flags: Int32) -> Int32
#endif
