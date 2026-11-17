#if os(Linux)
import Foundation
import Glibc
import Testing
@testable import RVMCP

/// Whether this host forbids what the cage's connector does (copying a
/// descriptor from the server): `kernel.yama.ptrace_scope` 3 forbids it
/// to everyone, 2 to everyone but root.
private func hostForbidsTheConnector() -> Bool {
    let text = (try? String(contentsOfFile: "/proc/sys/kernel/yama/ptrace_scope", encoding: .utf8)) ?? "0"
    let scope = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    return scope >= 3 || (scope == 2 && getuid() != 0)
}

/// The Linux cage on the real kernel: a launch built by
/// `MCPSandbox.applyLinux` and run through `rv-isolation-exec --confine`,
/// against a home directory made for the test. Every command has a
/// deadline, so a broken cage fails instead of hanging.
///
/// What the kernel's Landlock does not block is asserted too, per ABI, so
/// the documented limits are the measured ones.
@Suite("MCP Linux sandbox", .serialized)
struct MCPLinuxSandboxTests {
    /// A home with credential stores, rv's configuration, and ordinary
    /// files. Under the build directory: `/tmp` is a write root of every
    /// cage, so nothing protected can live there.
    final class Home {
        let path: String
        let configDirectory: String

        init() throws {
            let base = FileManager.default.currentDirectoryPath + "/.build/rv-mcp-linux-tests"
            let raw = base + "/" + UUID().uuidString
            try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
            path = try #require(MCPSandbox.resolveExisting(raw))
            configDirectory = path + "/.config/rv"
            try write(".ssh/id_ed25519", "SSH-PRIVATE-KEY")
            try write(".aws/credentials", "AWS-SECRET")
            try write(".config/rv/secrets.json", "RV-CONFIG")
            try write(".config/gh/hosts.yml", "GH-TOKEN")
            try write(".config/other/settings", "plain settings")
            try write(".netrc", "NETRC-PASSWORD")
            try write("project/readme.txt", "hello")
            try write("real-gnupg/secring", "GPG-SECRET")
            try FileManager.default.createSymbolicLink(atPath: path + "/.gnupg", withDestinationPath: path + "/real-gnupg")
            try FileManager.default.createSymbolicLink(
                atPath: path + "/key-link", withDestinationPath: path + "/.ssh/id_ed25519")
        }

        deinit { try? FileManager.default.removeItem(atPath: path) }

        func write(_ relative: String, _ text: String) throws {
            let url = URL(fileURLWithPath: path + "/" + relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func read(_ relative: String) -> String? {
            try? String(contentsOfFile: path + "/" + relative, encoding: .utf8)
        }
    }

    struct Outcome {
        var status: Int32
        var output: String
        var errors: String
    }

    private let support = MCPSandbox.linuxSupport

    private var abi: LandlockABI {
        get throws { try #require(support.abi, "this kernel cannot cage: \(support)") }
    }

    /// The caged launch for `script` run by bash, or the refusal.
    private func cage(
        _ home: Home, _ script: String, policy: MCPSandboxPolicy = MCPSandboxPolicy(network: false),
        environment: [String: String] = [:], support: MCPLinuxCageSupport? = nil,
        notices: ((String) -> Void)? = nil
    ) -> Result<MCPUpstreamLaunch, MCPLaunchError> {
        let definition = MCPServerDefinition(name: "probe", command: "bash", sandbox: policy)
        var base = ["PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": home.path]
        for (key, value) in environment { base[key] = value }
        let launch = MCPUpstreamLaunch(
            server: "probe", executable: "/usr/bin/env", arguments: ["bash", "-c", script], environment: base)
        return MCPSandbox.applyLinux(
            definition: definition, launch: launch, policy: policy,
            configDirectory: URL(fileURLWithPath: home.configDirectory), home: URL(fileURLWithPath: home.path),
            accountHome: home.path, support: support ?? self.support,
            notice: { notices?($0) }, denied: { _, _ in })
    }

    /// Runs a launch to its end (at most 60 s).
    private func run(_ launch: MCPUpstreamLaunch, input: String = "") throws -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.environment = launch.environment
        if let directory = launch.workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(60)
        let killer = Thread {
            while process.isRunning, Date() < deadline { usleep(20_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        killer.start()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errors = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Outcome(
            status: process.terminationStatus, output: String(decoding: output, as: UTF8.self),
            errors: String(decoding: errors, as: UTF8.self))
    }

    private func caged(
        _ home: Home, _ script: String, policy: MCPSandboxPolicy = MCPSandboxPolicy(network: false),
        environment: [String: String] = [:]
    ) throws -> Outcome {
        try run(try cage(home, script, policy: policy, environment: environment).get())
    }

    /// `name=ok` or `name=denied` for each probe line the script printed.
    private func results(_ outcome: Outcome) -> [String: String] {
        var results: [String: String] = [:]
        for line in outcome.output.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { results[String(parts[0])] = String(parts[1]) }
        }
        return results
    }

    /// `label=ok` when `command` succeeds in the cage, else `label=denied`.
    private func probe(_ label: String, _ command: String) -> String {
        "if { \(command); } >/dev/null 2>&1; then echo \(label)=ok; else echo \(label)=denied; fi\n"
    }

    /// A listener on 127.0.0.1 this test holds.
    private func listener() throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        try #require(fd >= 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ready = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && listen(fd, 8) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        try #require(ready)
        return (fd, UInt16(bigEndian: address.sin_port))
    }

    // MARK: - Files

    @Test(.timeLimit(.minutes(2)))
    func credentialStoresAndRvsConfigurationAreUnreadableAndTheRestIsNot() throws {
        let home = try Home()
        let script = probe("ssh", "cat ~/.ssh/id_ed25519") + probe("ssh-list", "ls ~/.ssh")
            + probe("aws", "cat ~/.aws/credentials") + probe("rv", "cat ~/.config/rv/secrets.json")
            + probe("rv-list", "ls ~/.config/rv") + probe("gh", "cat ~/.config/gh/hosts.yml")
            + probe("netrc", "cat ~/.netrc") + probe("link", "cat ~/key-link")
            + probe("gnupg-link", "cat ~/.gnupg/secring") + probe("gnupg-target", "cat ~/real-gnupg/secring")
            + probe("project", "cat ~/project/readme.txt") + probe("project-list", "ls ~/project")
            + probe("config-neighbour", "cat ~/.config/other/settings") + probe("system", "cat /etc/passwd")
            + probe("home-list", "ls ~") + probe("home-stat", "test -d ~/.ssh")
        let outcome = try caged(home, script)
        #expect(outcome.status == 0, "\(outcome.errors)")
        #expect(results(outcome) == [
            "ssh": "denied", "ssh-list": "denied", "aws": "denied", "rv": "denied", "rv-list": "denied",
            "gh": "denied", "netrc": "denied", "link": "denied", "gnupg-link": "denied", "gnupg-target": "denied",
            "project": "ok", "project-list": "ok", "config-neighbour": "ok", "system": "ok",
            // A directory that holds a protected path cannot be listed; its entries can be named.
            "home-list": "denied", "home-stat": "ok",
        ])
        #expect(outcome.output.contains("SECRET") == false && outcome.output.contains("PRIVATE") == false)
    }

    @Test(.timeLimit(.minutes(2)))
    func writesStayInsideTheScratchTempCachesAndReviewedPaths() throws {
        let home = try Home()
        try home.write("outbox/.keep", "")
        let script = probe("scratch", "echo x > ./in-scratch") + probe("cwd", "test \"$PWD\" = ~/.cache/rv-mcp/probe")
            + probe("tmp", "echo x > /tmp/rv-mcp-linux-probe-$$ && rm /tmp/rv-mcp-linux-probe-$$")
            + probe("npm", "echo x > ~/.npm/probe") + probe("cache", "echo x > ~/.cache/probe")
            + probe("reviewed", "echo x > ~/outbox/out") + probe("devnull", "echo x > /dev/null")
            + probe("project", "echo x > ~/project/new") + probe("project-append", "echo x >> ~/project/readme.txt")
            + probe("project-remove", "rm ~/project/readme.txt") + probe("home", "echo x > ~/new")
            + probe("mkdir", "mkdir ~/project/dir") + probe("etc", "echo x > /etc/rv-probe")
            + probe("ssh-write", "echo x > ~/.ssh/authorized_keys")
            + probe("hardlink", "ln ~/.ssh/id_ed25519 ./stolen") + probe("rename-in", "mv ~/project/readme.txt ./taken")
            + probe("symlink-read", "ln -s ~/.ssh/id_ed25519 ./l && cat ./l")
        let outcome = try caged(home, script, policy: MCPSandboxPolicy(network: false, writable: ["~/outbox"]))
        #expect(outcome.status == 0, "\(outcome.errors)")
        #expect(results(outcome) == [
            "scratch": "ok", "cwd": "ok", "tmp": "ok", "npm": "ok", "cache": "ok", "reviewed": "ok", "devnull": "ok",
            "project": "denied", "project-append": "denied", "project-remove": "denied", "home": "denied",
            "mkdir": "denied", "etc": "denied", "ssh-write": "denied", "hardlink": "denied", "rename-in": "denied",
            "symlink-read": "denied",
        ])
        #expect(home.read("project/readme.txt") == "hello")
        #expect(home.read("outbox/out") == "x\n")
        #expect(home.read(".cache/rv-mcp/probe/in-scratch") == "x\n")
        #expect(FileManager.default.fileExists(atPath: home.path + "/.ssh/authorized_keys") == false)
    }

    // MARK: - Network

    /// The two calls Landlock's TCP rules cover: `connect` and `bind` are
    /// denied in the cage, and the same script succeeds outside it.
    @Test(.timeLimit(.minutes(2)))
    func aServerWithNoNetworkCannotConnectOrBind() throws {
        let home = try Home()
        let open = try listener()
        defer { close(open.fd) }
        let script = probe("connect", "exec 3<>/dev/tcp/127.0.0.1/\(open.port)")
            + probe("bind", "python3 -c 'import socket; s=socket.socket(); s.bind((\"127.0.0.1\",0)); s.listen(1)'")
        let outcome = try caged(home, script)
        #expect(results(outcome) == ["connect": "denied", "bind": "denied"])
        let control = try run(MCPUpstreamLaunch(
            server: "control", executable: "/bin/bash", arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"]))
        #expect(results(control) == ["connect": "ok", "bind": "ok"])
    }

    /// The ways onto the network that Landlock's two TCP rules do not
    /// cover, each of which works outside the cage on a kernel that has
    /// it: an MPTCP socket, TCP fast open, a socket that listens without
    /// being bound, UDP, ICMP, raw, netlink and packet sockets. The socket
    /// filter refuses every one, on every kernel.
    private let routes = """
        import errno, socket, sys
        port = int(sys.argv[1])
        FASTOPEN = 0x20000000
        def attempt(label, action):
            try:
                action(); print(label + "=ok")
            except OSError as error:
                print(label + "=denied")
        def tcp():
            s = socket.socket(); s.settimeout(5); s.connect(("127.0.0.1", port))
        def mptcp():
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM, 262); s.settimeout(5)
            s.connect(("127.0.0.1", port)); s.send(b"x")
        def fast_open(protocol):
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM, protocol)
            if s.sendto(b"hello", FASTOPEN, ("127.0.0.1", port)) != 5: raise OSError("not sent")
        def fast_open_message():
            s = socket.socket()
            if s.sendmsg([b"hello"], [], FASTOPEN, ("127.0.0.1", port)) != 5: raise OSError("not sent")
        def listen_unbound():
            s = socket.socket(); s.listen(1)
            if s.getsockname()[1] == 0: raise OSError("not listening")
        def udp(family):
            socket.socket(family, socket.SOCK_DGRAM).sendto(b"x", ("::1" if family == socket.AF_INET6 else "127.0.0.1", 9))
        def pair():
            a, b = socket.socketpair(); a.send(b"x")
            if b.recv(1) != b"x": raise OSError("not received")
        attempt("tcp", tcp)
        attempt("mptcp", mptcp)
        attempt("fast-open", lambda: fast_open(0))
        attempt("fast-open-sendmsg", fast_open_message)
        attempt("mptcp-fast-open", lambda: fast_open(262))
        attempt("listen-unbound", listen_unbound)
        attempt("udp", lambda: udp(socket.AF_INET))
        attempt("udp6", lambda: udp(socket.AF_INET6))
        attempt("icmp", lambda: socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_ICMP))
        attempt("raw", lambda: socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_TCP))
        attempt("netlink", lambda: socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, 0))
        attempt("packet", lambda: socket.socket(socket.AF_PACKET, socket.SOCK_RAW, 0))
        attempt("tcp-with-flags", lambda: socket.socket(
            socket.AF_INET, socket.SOCK_STREAM | socket.SOCK_NONBLOCK | socket.SOCK_CLOEXEC, socket.IPPROTO_TCP))
        attempt("socketpair", pair)
        """

    private static let everyRoute = [
        "tcp", "mptcp", "fast-open", "fast-open-sendmsg", "mptcp-fast-open", "listen-unbound", "udp", "udp6", "icmp", "raw",
        "netlink", "packet", "tcp-with-flags",
    ]

    /// `network: false`: no socket that could reach the network exists in
    /// the cage. The same script outside it shows the routes are real on
    /// this host.
    @Test(.timeLimit(.minutes(2)))
    func aServerWithNoNetworkHasNoWayOntoIt() throws {
        let home = try Home()
        let open = try listener()
        defer { close(open.fd) }
        try home.write("project/routes.py", routes)
        let control = results(try run(MCPUpstreamLaunch(
            server: "control", executable: "/usr/bin/env",
            arguments: ["python3", home.path + "/project/routes.py", String(open.port)],
            environment: ["PATH": "/usr/bin:/bin"])))
        // What every host has; MPTCP, fast open and ICMP depend on its settings.
        for route in ["tcp", "listen-unbound", "udp", "netlink", "tcp-with-flags", "socketpair"] {
            #expect(control[route] == "ok", "\(route) does not work outside the cage: \(control)")
        }
        let inside = results(try caged(home, "python3 ~/project/routes.py \(open.port)"))
        for route in Self.everyRoute { #expect(inside[route] == "denied", "\(route): \(inside)") }
        // Two connected sockets of its own are not a way out.
        #expect(inside["socketpair"] == "ok")
        #expect(inside.count == Self.everyRoute.count + 1)
    }

    /// `hosts`: the one port the cage may connect to is the allowlist
    /// proxy's, and the proxy refuses a host that is not listed.
    @Test(.enabled(if: hostForbidsTheConnector() == false, "this host forbids the connector"), .timeLimit(.minutes(2)))
    func aServerWithAnAllowlistReachesOnlyTheProxysPort() throws {
        let home = try Home()
        defer { MCPSandbox.stopProxies(server: "probe") }
        let other = try listener()
        defer { close(other.fd) }
        let script = """
            port="${HTTPS_PROXY##*:}"
            if exec 3<>/dev/tcp/127.0.0.1/$port; then echo proxy=ok; else echo proxy=denied; fi
            printf 'CONNECT not-listed.example:443 HTTP/1.1\\r\\nHost: not-listed.example:443\\r\\n\\r\\n' >&3
            IFS= read -r -t 20 line <&3; echo "unlisted=${line:9:3}"
            if exec 4<>/dev/tcp/127.0.0.1/\(other.port); then echo other=ok; else echo other=denied; fi
            """
        let outcome = try caged(home, script, policy: MCPSandboxPolicy(network: false, hosts: ["allowed.example"]))
        let found = results(outcome)
        #expect(found["proxy"] == "ok")
        #expect(found["other"] == "denied")
        // Without the proxy credential or for an unlisted host: refused by the proxy.
        #expect(found["unlisted"]?.hasPrefix("4") == true, "\(outcome.output) \(outcome.errors)")
    }

    /// `hosts`: plain TCP sockets exist, for the connector to connect to
    /// the proxy. Every way round it is refused: another kind of socket,
    /// fast open (a connection with no `connect`), and listening.
    @Test(.enabled(if: hostForbidsTheConnector() == false, "this host forbids the connector"), .timeLimit(.minutes(2)))
    func aServerWithAnAllowlistHasNoWayRoundTheProxysPort() throws {
        let home = try Home()
        defer { MCPSandbox.stopProxies(server: "probe") }
        let other = try listener()
        defer { close(other.fd) }
        try home.write("project/routes.py", routes)
        // The routes aimed at a listener that is not the proxy, then plain TCP at the proxy.
        let script = "python3 ~/project/routes.py \(other.port)\n"
            + probe("proxy", "exec 3<>/dev/tcp/127.0.0.1/${HTTPS_PROXY##*:}")
        let found = results(try caged(home, script, policy: MCPSandboxPolicy(network: false, hosts: ["allowed.example"])))
        for route in Self.everyRoute where route != "tcp-with-flags" {
            #expect(found[route] == "denied", "\(route): \(found)")
        }
        // A TCP socket can be made, flags and all; where it is connected is the connector's.
        #expect(found["tcp-with-flags"] == "ok" && found["socketpair"] == "ok")
        #expect(found["proxy"] == "ok", "\(found)")
    }

    /// An address of this host that is not loopback, or one that is
    /// nobody's (TEST-NET-1) where the host has none.
    private var addressBeyondLoopback: String {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return "192.0.2.1" }
        defer { freeifaddrs(list) }
        var next = list
        while let entry = next {
            next = entry.pointee.ifa_next
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let found = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                inet_ntop(AF_INET, &pointer.pointee.sin_addr, &text, socklen_t(text.count)) != nil
            }
            if found { return String(decoding: text.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self) }
        }
        return "192.0.2.1"
    }

    /// The allowlist is the proxy on this host and nowhere else: the
    /// proxy's port on another address is refused, not merely unanswered.
    /// Landlock can name only the port, so rv's connector makes each
    /// connection itself, to loopback.
    @Test(.enabled(if: hostForbidsTheConnector() == false, "this host forbids the connector"), .timeLimit(.minutes(2)))
    func theProxysPortOnAnotherAddressIsRefused() throws {
        let home = try Home()
        defer { MCPSandbox.stopProxies(server: "probe") }
        try home.write("project/beyond.py", """
            import errno, os, socket, sys
            port = int(os.environ["HTTPS_PROXY"].rsplit(":", 1)[1])
            def attempt(label, family, address):
                try:
                    s = socket.socket(family, socket.SOCK_STREAM)
                    s.settimeout(3)
                    s.connect(address); print(label + "=ok")
                except socket.timeout:
                    print(label + "=sent")
                except OSError as error:
                    print(label + "=" + errno.errorcode.get(error.errno, str(error.errno)))
            attempt("proxy", socket.AF_INET, ("127.0.0.1", port))
            attempt("proxy-by-ipv6-socket", socket.AF_INET6, ("::ffff:127.0.0.1", port))
            attempt("beyond", socket.AF_INET, (sys.argv[1], port))
            attempt("beyond-by-ipv6-socket", socket.AF_INET6, ("::ffff:" + sys.argv[1], port))
            attempt("beyond-ipv6", socket.AF_INET6, ("2001:db8::1", port))
            attempt("other-port", socket.AF_INET, ("127.0.0.1", port + 1 if port < 65535 else port - 1))
            # Not blocking: the answer is "in progress", and the connection completes.
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM); s.setblocking(False)
            code = s.connect_ex(("127.0.0.1", port))
            import select
            select.select([], [s], [], 5)
            print("proxy-nonblocking=" + ("ok" if code in (0, errno.EINPROGRESS)
                and s.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR) == 0 and s.getpeername()[1] == port else "failed"))
            # Many threads at once: each gets its own answer.
            import threading
            done = []
            def one():
                t = socket.socket(socket.AF_INET, socket.SOCK_STREAM); t.settimeout(5)
                try:
                    t.connect(("127.0.0.1", port)); done.append(t.getpeername()[1] == port)
                except OSError:
                    done.append(False)
            threads = [threading.Thread(target=one) for _ in range(24)]
            [t.start() for t in threads]; [t.join() for t in threads]
            print("proxy-from-threads=" + ("ok" if len(done) == 24 and all(done) else "failed"))
            """)
        let policy = MCPSandboxPolicy(network: false, hosts: ["allowed.example"])
        let outcome = try caged(home, "python3 ~/project/beyond.py \(addressBeyondLoopback)", policy: policy)
        // A host with IPv6 switched off has no such socket, caged or not.
        let probe = socket(AF_INET6, Int32(SOCK_STREAM.rawValue), 0)
        if probe >= 0 { close(probe) }
        func ipv6(_ answer: String) -> String { probe >= 0 ? answer : "EAFNOSUPPORT" }
        #expect(results(outcome) == [
            "proxy": "ok", "proxy-by-ipv6-socket": ipv6("ok"), "proxy-nonblocking": "ok", "proxy-from-threads": "ok",
            "beyond": "EACCES", "beyond-by-ipv6-socket": ipv6("EACCES"), "beyond-ipv6": ipv6("EACCES"),
            "other-port": "EACCES",
        ], "\(outcome.output) \(outcome.errors)")
        #expect(outcome.status == 0, "\(outcome.errors)")
    }

    /// Where the host lets no process copy another's descriptors, the
    /// connector cannot connect anything: the server is not started.
    @Test(.enabled(if: hostForbidsTheConnector(), "needs kernel.yama.ptrace_scope 3, or 2 without root"),
        .timeLimit(.minutes(2)))
    func whereTheHostForbidsTheConnectorAServerWithAnAllowlistIsNotStarted() throws {
        let home = try Home()
        defer { MCPSandbox.stopProxies(server: "probe") }
        let policy = MCPSandboxPolicy(network: false, hosts: ["allowed.example"])
        let outcome = try caged(home, "echo ran > ran", policy: policy)
        #expect(outcome.status == 125 && outcome.errors.contains("kernel.yama.ptrace_scope"), "\(outcome)")
        #expect(home.read(".cache/rv-mcp/probe/ran") == nil)
        // A server with no network needs no connector and runs.
        #expect(try caged(home, "echo ran > ran").status == 0)
        #expect(home.read(".cache/rv-mcp/probe/ran") == "ran\n")
    }

    /// With an allowlist the server is a child of rv's connector: its exit
    /// status, a signal that kills it, and a signal sent to it all pass
    /// through, and a kill of the connector takes the server with it.
    @Test(.enabled(if: hostForbidsTheConnector() == false, "this host forbids the connector"), .timeLimit(.minutes(2)))
    func aServerWithAnAllowlistStillExitsAndIsSignalledAsItself() throws {
        let home = try Home()
        defer { MCPSandbox.stopProxies(server: "probe") }
        let policy = MCPSandboxPolicy(network: false, hosts: ["allowed.example"])
        #expect(try caged(home, "exit 7", policy: policy).status == 7)
        let killed = try run(try cage(home, "kill -SEGV $$", policy: policy).get())
        #expect(killed.status == SIGSEGV, "\(killed)")
        // SIGTERM to the process the gateway holds reaches the server.
        let launch = try cage(
            home, "trap 'echo heard > terminated; exit 9' TERM; echo ready; while :; do sleep 0.05; done", policy: policy
        ).get()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.environment = launch.environment
        if let directory = launch.workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let output = Pipe()
        process.standardOutput = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        try #require(output.fileHandleForReading.availableData.isEmpty == false)
        process.terminate()
        process.waitUntilExit()
        #expect(process.terminationStatus == 9 && home.read(".cache/rv-mcp/probe/terminated") == "heard\n")
        // A server that ignores SIGTERM is killed soon after; one whose
        // connector is killed outright dies with it.
        for signal in [SIGTERM, SIGKILL] {
            let stubborn = Process()
            let launch = try cage(
                home, "trap '' TERM; echo $$; while :; do sleep 0.05; done", policy: policy).get()
            stubborn.executableURL = URL(fileURLWithPath: launch.executable)
            stubborn.arguments = launch.arguments
            stubborn.environment = launch.environment
            let pipe = Pipe()
            stubborn.standardOutput = pipe
            stubborn.standardInput = FileHandle.nullDevice
            try stubborn.run()
            let text = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
            let server = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), "\(text)")
            #expect(server != stubborn.processIdentifier)
            kill(stubborn.processIdentifier, signal)
            let ended = Date().addingTimeInterval(10)
            while stubborn.isRunning, Date() < ended { usleep(20_000) }
            #expect(stubborn.isRunning == false, "signal \(signal) did not end the process the gateway holds")
            kill(stubborn.processIdentifier, SIGKILL)
            stubborn.waitUntilExit()
            let deadline = Date().addingTimeInterval(5)
            while kill(server, 0) == 0, Date() < deadline { usleep(20_000) }
            #expect(kill(server, 0) != 0 && errno == ESRCH, "the server outlived signal \(signal)")
        }
    }

    // MARK: - Privileges and other processes

    @Test(.timeLimit(.minutes(2)))
    func theServerRunsWithNoNewPrivilegesAndCannotReadOtherProcesses() throws {
        let home = try Home()
        let script = "grep -E '^(NoNewPrivs|SigBlk):' /proc/self/status | tr '\\t' ' '\n"
            + probe("own-environ", "cat /proc/self/environ") + probe("outside-environ", "cat /proc/\(getpid())/environ")
            + probe("outside-descriptor", "readlink /proc/\(getpid())/fd/0")
            + probe("outside-memory", "head -c 1 /proc/\(getpid())/mem") + probe("outside-maps", "cat /proc/\(getpid())/maps")
            + probe("outside-arguments", "cat /proc/\(getpid())/cmdline")
        let outcome = try caged(home, script)
        #expect(outcome.output.contains("NoNewPrivs: 1"), "\(outcome.output)")
        // No signal is blocked, whatever the thread that started it blocks.
        #expect(outcome.output.contains("SigBlk: 0000000000000000"), "\(outcome.output)")
        // Landlock lets a caged process trace or read only processes in its
        // own cage. Two things get past it, and are documented limits: any
        // process's arguments are world-readable, and root (CAP_PERFMON)
        // may read another process's environment and memory map.
        let asRoot = getuid() == 0 ? "ok" : "denied"
        #expect(results(outcome) == [
            "own-environ": "ok", "outside-environ": asRoot, "outside-descriptor": "denied", "outside-memory": "denied",
            "outside-maps": asRoot, "outside-arguments": "ok",
        ], "\(outcome.output)")
    }

    /// A setuid-root binary run from the cage does not get root: without
    /// the cage it does, so the binary is a real control.
    @Test(.enabled(if: getuid() == 0 && FileManager.default.isExecutableFile(atPath: "/usr/bin/setpriv"),
        "needs root to make a setuid binary and drop to another user"), .timeLimit(.minutes(2)))
    func aSetuidBinaryGivesTheServerNoPrivileges() throws {
        let helper = try #require(MCPSandbox.linuxHelper)
        let directory = "/tmp/rv-mcp-setuid-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try FileManager.default.copyItem(atPath: "/usr/bin/id", toPath: directory + "/id")
        try #require(chmod(directory, 0o755) == 0 && chown(directory + "/id", 0, 0) == 0 && chmod(directory + "/id", 0o4755) == 0)
        let plan = MCPLinuxCage.Plan(
            readable: ["/usr", "/lib", "/lib64", "/bin", "/etc", directory], writable: [], shared: ["/dev"], proxyPort: nil)
        func effectiveUser(_ arguments: [String]) throws -> String {
            let outcome = try run(MCPUpstreamLaunch(
                server: "setuid", executable: "/usr/bin/setpriv",
                arguments: ["--reuid", "65534", "--regid", "65534", "--clear-groups"] + arguments, environment: [:]))
            return outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #expect(try effectiveUser([directory + "/id", "-u"]) == "0")
        #expect(try effectiveUser(
            [helper] + plan.arguments(executable: directory + "/id", argv: ["id", "-u"])) == "65534")
    }

    // MARK: - What the kernel leaves open, measured

    /// Another program's socket is never reached: below ABI 9 the server
    /// can make no Unix socket at all (the filter), from ABI 9 Landlock
    /// confines the ones it makes. What only Landlock mediates (signals,
    /// device `ioctl`) follows this kernel's ABI.
    @Test(.timeLimit(.minutes(2)))
    func otherProgramsSocketsAreNeverReachedAndTheRestFollowsTheABI() throws {
        let home = try Home()
        let abi = try self.abi
        // A Unix socket and an abstract socket held outside the cage, and a
        // process outside it to signal.
        let directory = "/tmp/rv-mcp-gap-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let name = "rv-mcp-gap-\(UUID().uuidString)"
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        holder.arguments = ["python3", "-c", """
            import socket, sys, time
            a = socket.socket(socket.AF_UNIX); a.bind(sys.argv[1] + "/sock"); a.listen(4)
            b = socket.socket(socket.AF_UNIX); b.bind("\\0" + sys.argv[2]); b.listen(4)
            c = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM); c.bind(sys.argv[1] + "/datagram")
            d = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM); d.bind("\\0" + sys.argv[2] + "-datagram")
            print("ready", flush=True); time.sleep(120)
            """, directory, name]
        let ready = Pipe()
        holder.standardOutput = ready
        try holder.run()
        defer {
            // Not SIGTERM: a child of a test thread inherits its blocked signals.
            kill(holder.processIdentifier, SIGKILL)
            holder.waitUntilExit()
        }
        try #require(ready.fileHandleForReading.availableData.isEmpty == false)
        let python = """
            import os, signal, socket, sys
            def attempt(label, action):
                try:
                    action(); print(label + "=ok")
                except OSError:
                    print(label + "=denied")
            def unix(address):
                s = socket.socket(socket.AF_UNIX); s.connect(address)
            def own():
                path = os.path.join(os.getcwd(), "own.sock")
                a = socket.socket(socket.AF_UNIX); a.bind(path); a.listen(1)
                socket.socket(socket.AF_UNIX).connect(path)
            def pair():
                a, b = socket.socketpair(); a.send(b"x"); b.recv(1)
            # A connected pair needs no socket(): a datagram one can still
            # address anyone, and a stream one must not be connectable again.
            def datagram(address):
                a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM); a.sendto(b"x", address)
            def again(address):
                a, b = socket.socketpair(); b.close(); a.connect(address)
            def ioctl():
                import fcntl, termios
                with open("/dev/null", "r+b", buffering=0) as device:
                    try:
                        fcntl.ioctl(device, termios.TCGETS, bytes(64))
                    except OSError as error:
                        # Not a terminal: reaching the driver at all is the access.
                        if error.errno != 25: raise
            attempt("pathname-unix", lambda: unix(sys.argv[1] + "/sock"))
            attempt("abstract-unix", lambda: unix("\\0" + sys.argv[2]))
            attempt("own-unix", own)
            attempt("socketpair", pair)
            attempt("datagram-pair-to-pathname", lambda: datagram(sys.argv[1] + "/datagram"))
            attempt("datagram-pair-to-abstract", lambda: datagram("\\0" + sys.argv[2] + "-datagram"))
            attempt("stream-pair-connected-again", lambda: again(sys.argv[1] + "/sock"))
            attempt("signal", lambda: os.kill(int(sys.argv[3]), 0))
            attempt("device-ioctl", ioctl)
            attempt("chmod-protected", lambda: os.chmod(os.path.expanduser("~/.ssh/id_ed25519"), 0o644))
            """
        try home.write("project/gaps.py", python)
        let outcome = try caged(
            home, "python3 ~/project/gaps.py \(directory) \(name) \(holder.processIdentifier)")
        func expected(_ gap: MCPLinuxCageGap) -> String { MCPLinuxCageGap.open(at: abi).contains(gap) ? "ok" : "denied" }
        #expect(results(outcome) == [
            // Held by another program, in /tmp and in the abstract namespace.
            "pathname-unix": "denied", "abstract-unix": "denied",
            // A socket of its own, in its own directory, where Landlock can confine it.
            "own-unix": abi >= .pathnameUnixSockets ? "ok" : "denied", "socketpair": "ok",
            "datagram-pair-to-pathname": "denied", "datagram-pair-to-abstract": "denied",
            "stream-pair-connected-again": "denied",
            "signal": expected(.signals), "device-ioctl": expected(.deviceIoctl),
            // Landlock does not mediate a change of mode, owner or times: a
            // documented limit. The key stays unreadable to the server.
            "chmod-protected": "ok",
        ], "ABI \(abi): \(outcome.output) \(outcome.errors)")
        #expect(chmod(home.path + "/.ssh/id_ed25519", 0o600) == 0)
    }

    // MARK: - Real servers

    /// Set by CI: these fetch real servers from the npm and PyPI registries.
    static let realServers = ProcessInfo.processInfo.environment["RV_MCP_REAL_SERVERS"] == "1"

    /// Starts a caged server, performs the MCP handshake over stdio, asks
    /// for its tools, and returns their names (at most 3 minutes).
    private func tools(of launch: MCPUpstreamLaunch) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.environment = launch.environment
        if let directory = launch.workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        defer {
            try? stdin.fileHandleForWriting.close()
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        let killer = Thread {
            let deadline = Date().addingTimeInterval(180)
            while process.isRunning, Date() < deadline { usleep(50_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        killer.start()
        func send(_ json: String) { stdin.fileHandleForWriting.write(Data((json + "\n").utf8)) }
        send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"rv-test","version":"0"}}}"#)
        var buffer = Data()
        var initialized = false
        while true {
            let chunk = stdout.fileHandleForReading.availableData
            guard chunk.isEmpty == false else { break }  // the server exited
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = buffer[buffer.index(after: newline)...]
                guard let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                if message["id"] as? Int == 1, initialized == false {
                    initialized = true
                    send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
                    send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
                }
                if message["id"] as? Int == 2, let result = message["result"] as? [String: Any],
                    let tools = result["tools"] as? [[String: Any]]
                {
                    return tools.compactMap { $0["name"] as? String }
                }
            }
        }
        Issue.record("the server exited or timed out before listing its tools")
        return []
    }

    private var hostPath: String { ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin" }

    /// PATH and HOME, plus the host's extra CA bundle where it has one (a
    /// network that intercepts TLS), which a real mcp.json would set in `env`.
    private func serverEnvironment(_ home: Home) -> [String: String] {
        var environment = ["PATH": hostPath, "HOME": home.path]
        for name in ["NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE"] {
            if let value = ProcessInfo.processInfo.environment[name] { environment[name] = value }
        }
        return environment
    }

    /// A Node server started the way users start them: `npx -y <package>`,
    /// fetched from the registry through the allowlist proxy, caged.
    @Test(.enabled(if: realServers), .timeLimit(.minutes(5)))
    func aNodeServerStartedWithNpxRunsInTheCage() throws {
        let home = try Home()
        defer { MCPSandbox.stopProxies(server: "files") }
        let policy = MCPSandboxPolicy(network: false, hosts: ["registry.npmjs.org"])
        let definition = MCPServerDefinition(name: "files", command: "npx", sandbox: policy)
        let launch = MCPUpstreamLaunch(
            server: "files", executable: "/usr/bin/env",
            arguments: ["npx", "-y", "@modelcontextprotocol/server-filesystem@2.3.0", home.path + "/project"],
            environment: serverEnvironment(home))
        let caged = try MCPSandbox.applyLinux(
            definition: definition, launch: launch, policy: policy,
            configDirectory: URL(fileURLWithPath: home.configDirectory), home: URL(fileURLWithPath: home.path),
            accountHome: home.path, notice: { _ in }, denied: { _, _ in }
        ).get()
        let names = try tools(of: caged)
        #expect(names.contains("read_file") || names.contains("read_text_file"), "\(names)")
        #expect(names.contains("list_directory"), "\(names)")
    }

    /// A Python server (the reference `mcp-server-time`), installed into a
    /// virtual environment outside the cage and run inside it, off the network.
    @Test(.enabled(if: realServers), .timeLimit(.minutes(5)))
    func aPythonServerRunsInTheCage() throws {
        let home = try Home()
        let environment = FileManager.default.currentDirectoryPath + "/.build/rv-mcp-linux-tests/python-server"
        if FileManager.default.isExecutableFile(atPath: environment + "/bin/mcp-server-time") == false {
            let setup = try run(MCPUpstreamLaunch(
                server: "setup", executable: "/bin/sh",
                arguments: ["-c", "python3 -m venv \"$1\" && \"$1/bin/pip\" install --quiet mcp-server-time==2026.11.11", "sh", environment],
                environment: serverEnvironment(home)))
            try #require(setup.status == 0, "could not install the Python server: \(setup.errors)")
        }
        let policy = MCPSandboxPolicy(network: false)
        let definition = MCPServerDefinition(name: "time", command: environment + "/bin/python", sandbox: policy)
        let launch = MCPUpstreamLaunch(
            server: "time", executable: "/usr/bin/env",
            arguments: [environment + "/bin/python", "-m", "mcp_server_time"],
            environment: serverEnvironment(home))
        let caged = try MCPSandbox.applyLinux(
            definition: definition, launch: launch, policy: policy,
            configDirectory: URL(fileURLWithPath: home.configDirectory), home: URL(fileURLWithPath: home.path),
            accountHome: home.path, notice: { _ in }, denied: { _, _ in }
        ).get()
        let names = try tools(of: caged)
        #expect(names.contains("get_current_time"), "\(names)")
    }

    // MARK: - Refusals

    @Test func aHostThatCannotCageRefusesAndSaysWhy() throws {
        let home = try Home()
        for (support, text) in [
            (MCPLinuxCageSupport.unavailable(.helperMissing), "rv-isolation-exec is not installed"),
            (.unavailable(.noLandlock), "has no Landlock"),
            (.unavailable(.tooOld(try #require(LandlockABI(3)))), "ABI 3"),
            (.unavailable(.probeFailed), "could not report"),
            (.unavailable(.noSocketFilter), "seccomp"),
        ] {
            guard case .failure(.sandbox(let reason)) = cage(home, "true", support: support) else {
                Issue.record("\(support) built a launch")
                continue
            }
            #expect(reason.contains(text) && reason.contains("will not run it uncaged"), "\(reason)")
        }
        #expect(FileManager.default.fileExists(atPath: home.path + "/.cache/rv-mcp") == false)
    }

    /// This host has both halves of the cage, so serve requires it of
    /// every local server.
    @Test func thisHostCagesAndTheGatewayRequiresIt() throws {
        _ = try abi
        #expect(MCPSandbox.enforced)
    }

    /// A loader variable in the server's environment would act in the
    /// helper, which runs before the cage: refused, never passed on.
    @Test(arguments: ["LD_PRELOAD", "LD_LIBRARY_PATH", "LD_AUDIT", "GLIBC_TUNABLES"])
    func aLoaderVariableInTheServersEnvironmentIsRefused(name: String) throws {
        let home = try Home()
        guard case .failure(.sandbox(let reason)) = cage(home, "true", environment: [name: "/tmp/x.so"]) else {
            Issue.record("\(name) reached the helper")
            return
        }
        #expect(reason.contains(name) && reason.contains("before the sandbox applies"), "\(reason)")
        #expect(FileManager.default.fileExists(atPath: home.path + "/.cache/rv-mcp") == false)
    }

    /// The helper checks the floor again in the server's own process: a
    /// request for an ABI the kernel does not have runs nothing.
    @Test(.timeLimit(.minutes(2)))
    func theHelperRunsNothingBelowTheFloorItIsGiven() throws {
        let home = try Home()
        let helper = try #require(MCPSandbox.linuxHelper)
        let marker = home.path + "/project/ran"
        let plan = MCPLinuxCage.Plan(
            readable: ["/usr", "/bin", "/lib", "/lib64"], writable: [home.path + "/project"], shared: [], proxyPort: nil)
        var arguments = plan.arguments(executable: "/usr/bin/touch", argv: ["touch", marker])
        try #require(arguments[0...1] == ["--confine", "4"])
        arguments[1] = "999"
        let outcome = try run(MCPUpstreamLaunch(server: "floor", executable: helper, arguments: arguments, environment: [:]))
        #expect(outcome.status == 125)
        #expect(outcome.errors.contains("needs ABI 999"))
        #expect(FileManager.default.fileExists(atPath: marker) == false)
    }

    @Test(.timeLimit(.minutes(2)), arguments: [
        ["--confine"], ["--confine", "4"], ["--confine", "3", "--", "/usr/bin/true", "true"],
        ["--confine", "x", "--", "/usr/bin/true", "true"], ["--confine", "4", "--", "true", "true"],
        ["--confine", "4", "--", "/usr/bin/true"], ["--confine", "4", "--read"],
        ["--confine", "4", "--read", "relative", "--", "/usr/bin/true", "true"],
        ["--confine", "4", "--write", "/no/such/dir", "--", "/usr/bin/true", "true"],
        ["--confine", "4", "--temp", "/no/such/dir", "--", "/usr/bin/true", "true"],
        ["--confine", "4", "--temp", "relative", "--", "/usr/bin/true", "true"],
        ["--confine", "4", "--temp", "--", "/usr/bin/true", "true"],
        ["--confine", "4", "--tcp", "0", "--", "/usr/bin/true", "true"],
        ["--confine", "4", "--tcp", "65536", "--", "/usr/bin/true", "true"],
        ["--confine", "4", "--tcp", "80x", "--", "/usr/bin/true", "true"],
        // One proxy, one port.
        ["--confine", "4", "--tcp", "8080", "--tcp", "8081", "--", "/usr/bin/true", "true"],
        // A port, then something that is not a request: nothing is started to connect.
        ["--confine", "4", "--tcp", "8080", "--read", "relative", "--", "/usr/bin/true", "true"],
        ["--confine", "4", "--tcp", "8080", "--", "relative", "true"],
        ["--confine", "4", "--bogus", "x", "--", "/usr/bin/true", "true"],
    ])
    func theHelperRefusesARequestItDoesNotUnderstand(arguments: [String]) throws {
        let helper = try #require(MCPSandbox.linuxHelper)
        let outcome = try run(MCPUpstreamLaunch(server: "bad", executable: helper, arguments: arguments, environment: [:]))
        #expect(outcome.status == 125)
        #expect(outcome.errors.hasPrefix("rv mcp: the server was not started: "))
    }

    @Test func aWritablePathThatWouldExposeAStoreOrIsNotTheReviewedDirectoryIsRefused() throws {
        let home = try Home()
        try FileManager.default.createSymbolicLink(atPath: home.path + "/out-link", withDestinationPath: home.path + "/project")
        for (writable, text) in [
            ("~/.ssh", "would expose"), ("~/.config", "would expose"), ("~/.ssh/sub", "does not exist"),
            ("/", "would expose"), ("~/missing", "does not exist"), ("~/out-link", "was not the path reviewed"),
        ] {
            guard case .failure(.sandbox(let reason)) =
                cage(home, "true", policy: MCPSandboxPolicy(network: false, writable: [writable]))
            else {
                Issue.record("\(writable) was accepted as writable")
                continue
            }
            #expect(reason.contains(text), "\(writable): \(reason)")
        }
        guard case .failure(.sandbox(let reason)) = cage(home, "true", environment: ["TMPDIR": home.path + "/project"]) else {
            Issue.record("a TMPDIR outside /tmp was accepted")
            return
        }
        #expect(reason.contains("was not the path reviewed"))
    }

    @Test func aHomeThatIsNotTheAccountsIsRefused() throws {
        let home = try Home()
        let definition = MCPServerDefinition(name: "probe", command: "true", sandbox: MCPSandboxPolicy(network: false))
        let launch = MCPUpstreamLaunch(server: "probe", executable: "/usr/bin/env", arguments: ["true"], environment: [:])
        let result = MCPSandbox.applyLinux(
            definition: definition, launch: launch, policy: MCPSandboxPolicy(network: false),
            configDirectory: URL(fileURLWithPath: home.configDirectory), home: URL(fileURLWithPath: home.path),
            accountHome: "/root-of-someone-else", notice: { _ in }, denied: { _, _ in })
        guard case .failure(.sandbox(let reason)) = result else {
            Issue.record("a home that is not the account's was accepted")
            return
        }
        #expect(reason.contains("was not the path reviewed"))
    }

    @Test func startingACagedServerSaysWhatAnOlderKernelLeavesOpen() throws {
        let home = try Home()
        let abi = try self.abi
        var lines: [String] = []
        _ = try cage(home, "true", notices: { lines.append($0) }).get()
        // One line where this kernel's Landlock leaves something open; none where it does not.
        #expect(lines == [MCPLinuxCage.notice(server: "probe", abi: abi)].compactMap { $0 })
        #expect(lines.isEmpty == MCPLinuxCageGap.open(at: abi).isEmpty)
    }
}
#endif
