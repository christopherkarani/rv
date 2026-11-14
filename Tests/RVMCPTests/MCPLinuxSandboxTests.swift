#if os(Linux)
import Foundation
import Glibc
import Testing
@testable import RVMCP

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
        network: MCPLinuxCage.NetworkLimit = .disclose, notices: ((String) -> Void)? = nil
    ) -> Result<MCPUpstreamLaunch, MCPLaunchError> {
        let definition = MCPServerDefinition(name: "probe", command: "bash", sandbox: policy)
        var base = ["PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": home.path]
        for (key, value) in environment { base[key] = value }
        let launch = MCPUpstreamLaunch(
            server: "probe", executable: "/usr/bin/env", arguments: ["bash", "-c", script], environment: base)
        return MCPSandbox.applyLinux(
            definition: definition, launch: launch, policy: policy,
            configDirectory: URL(fileURLWithPath: home.configDirectory), home: URL(fileURLWithPath: home.path),
            accountHome: home.path, support: support ?? self.support, network: network,
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

    /// Why `MCPLinuxCage.networkLimit` refuses: TCP that passes neither of
    /// those two calls. Which route a kernel build leaves open varies
    /// (MPTCP `connect` and TCP fast open are each denied on some), so
    /// each is tried outside the cage first: the cage may deny a route,
    /// never open one. `listen` without `bind` is open in every cage, and
    /// where the host has MPTCP and fast open, at least one way out is
    /// too. If a kernel
    /// closes these, this fails and the limits in
    /// docs/security/mcp-linux-sandbox.md change.
    @Test(.timeLimit(.minutes(2)))
    func tcpThatPassesNeitherConnectNorBindIsNotAllDenied() throws {
        let home = try Home()
        let open = try listener()
        defer { close(open.fd) }
        let python = """
            import socket, sys
            port = int(sys.argv[1])
            FASTOPEN = 0x20000000
            def attempt(label, action):
                try:
                    action(); print(label + "=ok")
                except OSError:
                    print(label + "=denied")
            def mptcp():
                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM, 262)
                s.connect(("127.0.0.1", port)); s.send(b"x")
            def fast_open(protocol):
                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM, protocol)
                if s.sendto(b"hello", FASTOPEN, ("127.0.0.1", port)) != 5: raise OSError("not sent")
            def listen_unbound():
                s = socket.socket(); s.listen(1)
                if s.getsockname()[1] == 0: raise OSError("not listening")
            attempt("mptcp", mptcp)
            attempt("fast-open", lambda: fast_open(0))
            attempt("mptcp-fast-open", lambda: fast_open(262))
            attempt("listen-unbound", listen_unbound)
            """
        try home.write("project/routes.py", python)
        let control = results(try run(MCPUpstreamLaunch(
            server: "control", executable: "/usr/bin/env",
            arguments: ["python3", home.path + "/project/routes.py", String(open.port)],
            environment: ["PATH": "/usr/bin:/bin"])))
        #expect(control["listen-unbound"] == "ok", "\(control)")
        let inside = results(try caged(home, "python3 ~/project/routes.py \(open.port)"))
        #expect(Set(inside.keys) == Set(control.keys))
        for (route, outcome) in inside where outcome == "ok" {
            #expect(control[route] == "ok", "\(route) is open in the cage and not outside it")
        }
        #expect(inside["listen-unbound"] == "ok", "\(inside)")
        // MPTCP fast open is the one route open on every build measured;
        // it needs MPTCP and fast open both enabled on the host.
        if control["mptcp-fast-open"] == "ok" {
            #expect(["mptcp", "fast-open", "mptcp-fast-open"].contains { inside[$0] == "ok" }, "\(inside)")
        }
    }

    /// `hosts`: the one port the cage may connect to is the allowlist
    /// proxy's, and the proxy refuses a host that is not listed.
    @Test(.timeLimit(.minutes(2)))
    func aServerWithAnAllowlistReachesOnlyTheProxysPort() throws {
        let home = try Home()
        defer { MCPSandbox.stopProxies() }
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
        let home = try Home()
        let helper = try #require(MCPSandbox.linuxHelper)
        let directory = "/tmp/rv-mcp-setuid-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try FileManager.default.copyItem(atPath: "/usr/bin/id", toPath: directory + "/id")
        try #require(chmod(directory, 0o755) == 0 && chown(directory + "/id", 0, 0) == 0 && chmod(directory + "/id", 0o4755) == 0)
        let plan = MCPLinuxCage.Plan(
            readable: ["/usr", "/lib", "/lib64", "/bin", "/etc", directory], writable: [], shared: ["/dev"], tcpPorts: [])
        func effectiveUser(_ arguments: [String]) throws -> String {
            let outcome = try run(MCPUpstreamLaunch(
                server: "setuid", executable: "/usr/bin/setpriv",
                arguments: ["--reuid", "65534", "--regid", "65534", "--clear-groups"] + arguments, environment: [:]))
            return outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #expect(try effectiveUser([directory + "/id", "-u"]) == "0")
        #expect(try effectiveUser(
            [helper] + plan.arguments(executable: directory + "/id", argv: ["id", "-u"])) == "65534")
        _ = home
    }

    // MARK: - What the kernel leaves open, measured

    /// The documented limits, as this kernel has them: each channel is open
    /// below the ABI that closes it and closed from it on.
    @Test(.timeLimit(.minutes(2)))
    func eachChannelIsOpenOnlyBelowTheABIThatClosesIt() throws {
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
            def udp():
                s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.sendto(b"x", ("127.0.0.1", 9))
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
            attempt("signal", lambda: os.kill(int(sys.argv[3]), 0))
            attempt("udp", udp)
            attempt("device-ioctl", ioctl)
            attempt("chmod-protected", lambda: os.chmod(os.path.expanduser("~/.ssh/id_ed25519"), 0o644))
            """
        try home.write("project/gaps.py", python)
        let outcome = try caged(
            home, "python3 ~/project/gaps.py \(directory) \(name) \(holder.processIdentifier)")
        func expected(_ gap: MCPLinuxCageGap) -> String { MCPLinuxCageGap.open(at: abi).contains(gap) ? "ok" : "denied" }
        #expect(results(outcome) == [
            // The socket is in /tmp, held by another program.
            "pathname-unix": expected(.pathnameUnixSockets),
            "abstract-unix": expected(.abstractSocketsAndSignals), "signal": expected(.abstractSocketsAndSignals),
            "udp": expected(.udp), "device-ioctl": expected(.deviceIoctl),
            // Landlock does not mediate a change of mode, owner or times: a
            // documented limit. The key stays unreadable to the server.
            "chmod-protected": "ok",
        ], "ABI \(abi): \(outcome.output) \(outcome.errors)")
        #expect(chmod(home.path + "/.ssh/id_ed25519", 0o600) == 0)
    }

    // MARK: - Real servers

    /// Set by CI and `Scripts/linux-mcp-sandbox-e2e.sh`: these fetch real
    /// servers from the npm and PyPI registries.
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
        defer { MCPSandbox.stopProxies() }
        let policy = MCPSandboxPolicy(network: false, hosts: ["registry.npmjs.org"])
        let definition = MCPServerDefinition(name: "files", command: "npx", sandbox: policy)
        let launch = MCPUpstreamLaunch(
            server: "files", executable: "/usr/bin/env",
            arguments: ["npx", "-y", "@modelcontextprotocol/server-filesystem@2.3.0", home.path + "/project"],
            environment: serverEnvironment(home))
        let caged = try MCPSandbox.applyLinux(
            definition: definition, launch: launch, policy: policy,
            configDirectory: URL(fileURLWithPath: home.configDirectory), home: URL(fileURLWithPath: home.path),
            accountHome: home.path, network: .disclose, notice: { _ in }, denied: { _, _ in }
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
            accountHome: home.path, network: .disclose, notice: { _ in }, denied: { _, _ in }
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
        ] {
            guard case .failure(.sandbox(let reason)) = cage(home, "true", support: support) else {
                Issue.record("\(support) built a launch")
                continue
            }
            #expect(reason.contains(text) && reason.contains("will not run it uncaged"), "\(reason)")
        }
        #expect(FileManager.default.fileExists(atPath: home.path + "/.cache/rv-mcp") == false)
    }

    /// The release's answer to a network limit Landlock cannot hold: no
    /// server starts, and the host says it has no sandbox.
    @Test func aPolicyThatLimitsTheNetworkIsRefusedByDefault() throws {
        let home = try Home()
        let abi = try self.abi
        #expect(MCPLinuxCage.networkLimit == .refuse)
        for policy in [MCPSandboxPolicy(network: false), MCPSandboxPolicy(network: false, hosts: ["example.com"])] {
            guard case .failure(.sandbox(let reason)) = cage(home, "true", policy: policy, network: MCPLinuxCage.networkLimit)
            else {
                Issue.record("a server was planned under a network limit the kernel cannot hold")
                continue
            }
            #expect(reason.contains("cannot keep a server off the network") && reason.contains("MPTCP")
                && reason.contains("ABI \(abi)") && reason.contains("will not run it uncaged"), "\(reason)")
        }
        #expect(FileManager.default.fileExists(atPath: home.path + "/.cache/rv-mcp") == false)
        #expect(MCPSandbox.enforced == false)
        #expect(MCPSandbox.unavailability.contains("cannot keep a server off the network"))
        // Not a missing helper or an old kernel: nothing here says to fix one.
        for support in [MCPLinuxCageSupport.unavailable(.helperMissing), .unavailable(.noLandlock)] {
            guard case .failure(.sandbox(let reason)) = cage(home, "true", support: support, network: .refuse) else {
                Issue.record("\(support) built a launch")
                continue
            }
            #expect(reason.contains("on any kernel") && reason.contains("reinstall") == false, "\(reason)")
        }
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
            readable: ["/usr", "/bin", "/lib", "/lib64"], writable: [home.path + "/project"], shared: [], tcpPorts: [])
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
            accountHome: "/root-of-someone-else", network: .disclose, notice: { _ in }, denied: { _, _ in })
        guard case .failure(.sandbox(let reason)) = result else {
            Issue.record("a home that is not the account's was accepted")
            return
        }
        #expect(reason.contains("was not the path reviewed"))
    }

    @Test func startingACagedServerSaysWhatTheKernelLeavesOpen() throws {
        let home = try Home()
        let abi = try self.abi
        var lines: [String] = []
        _ = try cage(home, "true", notices: { lines.append($0) }).get()
        #expect(lines == [MCPLinuxCage.notice(server: "probe", abi: abi)])
        #expect(lines.first?.contains("ABI \(abi)") == true && lines.first?.contains("MPTCP") == true)
    }
}
#endif
