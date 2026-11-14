#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVIsolation
import Testing
@testable import RVMCP

@Suite("MCP strict profile and sandbox hosts")
struct MCPStrictProfileTests {
    private static let strict = #"""
        {"version": 1, "profile": "strict", "defaultDecision": "allow", "servers": [
          {"name": "gh", "command": "gh-mcp", "sandbox": {"hosts": ["api.github.com", "Uploads.GitHub.com"]},
           "tools": {"default": "allow", "allow": ["get_*"], "ask": ["create_*"]}},
          {"name": "linear", "url": "https://mcp.linear.app/mcp"}
        ]}
        """#

    @Test func strictProfileAndHostsRoundTripAndUnlistedToolsDeny() throws {
        let configuration = try MCPConfiguration.decode(Data(Self.strict.utf8)).get()
        #expect(configuration.profile == .strict)
        let gh = try #require(configuration.server(named: "gh"))
        #expect(gh.sandbox == MCPSandboxPolicy(network: false, hosts: ["api.github.com", "uploads.github.com"]))
        #expect(configuration.decision(server: gh, tool: "get_issue") == .allow)
        #expect(configuration.decision(server: gh, tool: "create_issue") == .ask)
        #expect(configuration.decision(server: gh, tool: "delete_repo") == .deny)
        let linear = try #require(configuration.server(named: "linear"))
        #expect(configuration.decision(server: linear, tool: "anything") == .deny)

        let encoded = configuration.encoded().prettyText
        #expect(encoded.contains(#""profile" : "strict""#) || encoded.contains(#""profile": "strict""#))
        #expect(try MCPConfiguration.decode(Data(encoded.utf8)).get() == configuration)

        var standard = configuration
        standard.profile = .standard
        #expect(standard.decision(server: gh, tool: "delete_repo") == .deny)
        #expect(standard.encoded().prettyText.contains("profile") == false)
    }

    /// No-migration contract: a pre-flip file stays byte-valid and trusted,
    /// but its written allow defaults no longer decide anything. Explicit
    /// allow/ask globs still do.
    @Test func writtenAllowDefaultsAreInertWithoutMigration() throws {
        let legacy = #"""
            {"version": 1, "defaultDecision": "allow", "servers": [
              {"name": "s", "command": "x", "tools": {"default": "allow", "allow": ["get_*"], "ask": ["create_*"]}},
              {"name": "r", "url": "https://mcp.example.com/mcp"}
            ]}
            """#
        let configuration = try MCPConfiguration.decode(Data(legacy.utf8)).get()
        let local = try #require(configuration.server(named: "s"))
        #expect(configuration.decision(server: local, tool: "get_issue") == .allow)
        #expect(configuration.decision(server: local, tool: "create_issue") == .ask)
        #expect(configuration.decision(server: local, tool: "delete_repo") == .deny)
        let remote = try #require(configuration.server(named: "r"))
        #expect(configuration.decision(server: remote, tool: "anything") == .deny)
    }

    @Test func plannerRequiresSandboxWithoutOpenNetworkByDefault() throws {
        let configuration = MCPConfiguration(servers: [
            MCPServerDefinition(name: "bare", command: "b"),
            MCPServerDefinition(name: "open", command: "o", sandbox: MCPSandboxPolicy(network: true)),
            MCPServerDefinition(name: "closed", command: "c", sandbox: MCPSandboxPolicy(network: false)),
        ])
        func plan(_ name: String) -> Result<Void, MCPLaunchError> {
            MCPLaunchPlanner.plan(
                servers: [name], configuration: configuration, secrets: SecretsConfiguration(),
                resolver: SecretResolver { _ in .failure(.notFound("none")) }, baseEnvironment: [:],
                requireSandbox: true
            ).map { _ in () }
        }
        guard case .failure = plan("bare"), case .failure = plan("open") else {
            Issue.record("default profile launched an uncaged or open-network server")
            return
        }
        #expect((try? plan("closed").get()) != nil)
    }

    @Test func refusesBadProfilesAndHosts() {
        func problem(_ top: String = "", sandbox: String) -> String? {
            let text = #"{"version": 1\#(top), "servers": [{"name": "s", "command": "x", "sandbox": \#(sandbox)}]}"#
            guard case .failure(let error) = MCPConfiguration.decode(Data(text.utf8)) else { return nil }
            return error.message
        }
        #expect(problem(#", "profile": "lax""#, sandbox: "{}")?.contains(#"profile must be "standard" or "strict""#) == true)
        #expect(problem(sandbox: #"{"hosts": ["https://api.github.com"]}"#)?.contains("not a host name") == true)
        #expect(problem(sandbox: #"{"hosts": ["10.0.0.1"]}"#)?.contains("not a host name") == true)
        #expect(problem(sandbox: #"{"hosts": ["localhost"]}"#)?.contains("not a host name") == true)
        #expect(problem(sandbox: #"{"hosts": ["*.github.com"]}"#)?.contains("not a host name") == true)
        #expect(problem(sandbox: #"{"hosts": "api.github.com"}"#)?.contains("sandbox.hosts must be") == true)
        #expect(problem(sandbox: #"{"hosts": ["api.github.com"], "network": true}"#)?.contains("drop network: true") == true)
        let many = (0...MCPSandboxPolicy.maximumHosts).map { "\"h\($0).example.com\"" }.joined(separator: ",")
        #expect(problem(sandbox: #"{"hosts": [\#(many)]}"#)?.contains("more than \(MCPSandboxPolicy.maximumHosts)") == true)
    }

    @Test func plannerHoldsStrictServersToASandboxWithoutOpenNetwork() throws {
        var configuration = MCPConfiguration(servers: [
            MCPServerDefinition(name: "bare", command: "b"),
            MCPServerDefinition(name: "open", command: "o", sandbox: MCPSandboxPolicy(network: true)),
            MCPServerDefinition(name: "closed", command: "c", sandbox: MCPSandboxPolicy(network: false)),
            MCPServerDefinition(name: "proxied", command: "p", sandbox: MCPSandboxPolicy(network: false, hosts: ["api.example.com"])),
            MCPServerDefinition(name: "remote", remote: MCPRemoteServer(url: try #require(URL(string: "https://mcp.example.com/mcp")))),
        ])
        configuration.profile = .strict
        func plan(_ name: String) -> Result<Void, MCPLaunchError> {
            MCPLaunchPlanner.plan(
                servers: [name], configuration: configuration, secrets: SecretsConfiguration(),
                resolver: SecretResolver { _ in .failure(.notFound("none")) }, baseEnvironment: [:],
                requireSandbox: true
            ).map { _ in () }
        }
        guard case .failure(let bare) = plan("bare"), case .failure(let open) = plan("open") else {
            Issue.record("strict profile launched an uncaged or open-network server")
            return
        }
        #expect(bare.message == #"sandbox: bare needs a sandbox; add "sandbox" to its mcp.json entry"#)
        #expect(open.message == "sandbox: open stays off the network; list the hosts it needs in sandbox.hosts")
        for name in ["closed", "proxied", "remote"] {
            #expect((try? plan(name).get()) != nil, "\(name)")
        }
        configuration.profile = .standard
        guard case .failure = plan("bare") else {
            Issue.record("legacy standard profile must not launch an uncaged server")
            return
        }
    }

    @Test(.timeLimit(.minutes(1))) func profileTextLetsTheCageReachOnlyItsProxy() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-strict-profile-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(
            at: root.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scratch = root.appendingPathComponent("scratch").path
        try! FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        let home = root.appendingPathComponent("home").path
        let policy = MCPSandboxPolicy(network: false, hosts: ["api.example.com"])
        let proxied = try! MCPSandbox.profile(
            policy: policy, scratch: scratch, home: home, configDirectory: home + "/.config/rv",
            temporaryDirectory: root.appendingPathComponent("tmp").path, loopbackPorts: [4321]).get()
        #expect(proxied.contains("(deny network*)\n(allow network-outbound (remote tcp \"localhost:4321\"))"))
        // The proxy port is the only localhost reach the profile grants.
        #expect(proxied.components(separatedBy: "localhost:").count == 2)
        let closed = try! MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false), scratch: scratch, home: home, configDirectory: home + "/.config/rv",
            temporaryDirectory: root.appendingPathComponent("tmp").path).get()
        #expect(closed.contains("(deny network*)") && closed.contains("network-outbound") == false)
    }

    @Test func proxyEnvironmentPointsEveryClientAtTheProxy() {
        let environment = MCPSandbox.proxyEnvironment(
            ["NO_PROXY": "*", "no_proxy": "*", "PATH": "/bin"], port: 4321, credential: "abc")
        for key in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"] {
            #expect(environment[key] == "http://abc@127.0.0.1:4321", "\(key)")
        }
        #expect(environment["NODE_USE_ENV_PROXY"] == "1")
        #expect(environment["NO_PROXY"] == nil && environment["no_proxy"] == nil)
        #expect(environment["PATH"] == "/bin")
    }

    /// A fresh directory under the temp directory, spelled as `realpath`
    /// returns it. Foundation spells the temp directory `/var/folders/...`,
    /// through the `/var` symlink, and a credential path spelled through a
    /// symlink with a missing name makes the profile deny every place that
    /// name could be linked to, the home included: about 830 KB of filters,
    /// which libsandbox refuses as too large (measured on macOS 27).
    static func resolvedTemporaryRoot(_ prefix: String) throws -> URL {
        let temporary = try #require(MCPSandbox.resolveExisting(FileManager.default.temporaryDirectory.path))
        return URL(fileURLWithPath: temporary, isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }

    @Test(.timeLimit(.minutes(1))) func gatewayPortIsTheOnlyLoopbackReachOfAClosedCage() throws {
        let root = try Self.resolvedTemporaryRoot("rv-gateway-profile")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        // profile() runs after apply() created the scratch; a missing one is refused.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("scratch"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home").path
        let text = try MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false), scratch: root.appendingPathComponent("scratch").path,
            home: home, configDirectory: home + "/.config/rv", temporaryDirectory: root.appendingPathComponent("tmp").path,
            loopbackPorts: MCPSandbox.cageNetwork([:], proxy: nil, reach: .secretsGateway(port: 5151)).loopbackPorts).get()
        #expect(text.contains("(deny network*)\n(allow network-outbound (remote tcp \"localhost:5151\"))"))
        #expect(text.components(separatedBy: "localhost:").count == 2)
        #if os(macOS)
        #expect(MCPSandbox.profileCompileError(text) == nil)
        #endif
    }

    /// The link and clone rules in Seatbelt's last-match order: links are
    /// denied, then allowed among the write roots; a clone of a directory
    /// outside the write roots is denied (the kernel copies the whole tree
    /// and Seatbelt checks only its top); every ancestor of a credential
    /// that lies inside a write root is denied a clone and a rename; the
    /// credential deny comes last and covers links and clones. No line
    /// allows a clone. A symlinked credential adds no read deny of its own:
    /// the credential deny names the link and its target, nothing else, so
    /// system libraries and the write roots stay readable.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func linksAndClonesAreRefusedWhereTheyCouldReachACredential(_ symlinkedCredential: Bool) throws {
        let root = try Self.resolvedTemporaryRoot("rv-link-profile")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("scratch"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if symlinkedCredential {
            let keys = root.appendingPathComponent("elsewhere/aws")
            try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
            #expect(symlink(keys.path, home.appendingPathComponent(".aws").path) == 0)
        }
        let resolvedRoot = try #require(MCPSandbox.resolveExisting(root.path))
        let text = try MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false), scratch: root.appendingPathComponent("scratch").path,
            home: home.path, configDirectory: home.path + "/.config/rv",
            temporaryDirectory: root.appendingPathComponent("tmp").path).get()
        let lines = text.split(separator: "\n").map(String.init)
        let writeAllow = try #require(lines.first { $0.hasPrefix("(allow file-write* ") })
        let writeFilters = String(writeAllow.dropFirst("(allow file-write* ".count).dropLast())
        let allowDefault = try #require(lines.firstIndex(of: "(allow default)"))
        let deny = try #require(lines.firstIndex(of: "(deny file-link)"))
        let allow = try #require(lines.firstIndex(of: "(allow file-link " + writeFilters + ")"))
        let directoryClone = try #require(lines.firstIndex(
            of: "(deny file-clone (require-all (vnode-type DIRECTORY) (require-not (require-any " + writeFilters + "))))"))
        // The fake home is under the temp directory, a write root, so its
        // credentials' ancestors there are named one by one.
        let ancestors = try #require(lines.firstIndex { $0.hasPrefix("(deny file-clone file-write-unlink ") })
        let credential = try #require(lines.lastIndex { $0.hasPrefix("(deny file-read* file-write* file-link file-clone ") })
        #expect(allowDefault < deny && deny < allow && allow < directoryClone)
        #expect(directoryClone < ancestors && ancestors < credential)
        #expect(lines[ancestors].contains("(literal \"\(resolvedRoot)/home\")"))
        #expect(lines[ancestors].contains("(literal \"\(resolvedRoot)\")"))
        #expect(lines[ancestors].contains("(literal \"\(resolvedRoot)/elsewhere\")") == symlinkedCredential)
        #expect(lines[ancestors].contains("scratch") == false)
        // One line allows a link, no line allows a clone, and every
        // credential deny covers both.
        #expect(lines.filter { $0.hasPrefix("(allow") && $0.contains("file-link") }.count == 1)
        #expect(lines.filter { $0.contains("file-clone") }.allSatisfy { $0.hasPrefix("(deny ") })
        #expect(lines.filter { $0.hasPrefix("(deny file-read* file-write* ") }
            .allSatisfy { $0.hasPrefix("(deny file-read* file-write* file-link file-clone ") })
        // Reads are denied on the credentials and nowhere else: not every
        // path, and not the home that holds a symlinked one.
        #expect(lines.contains("(deny file-read*)") == false)
        #expect(lines[credential].contains("(subpath \"\(home.path)\")") == false)
        #expect(lines[credential].contains("(subpath \"\(resolvedRoot)/home\")") == false)
        #if os(macOS)
        #expect(MCPSandbox.profileCompileError(text) == nil)
        #endif
    }

    /// More credential ancestors inside the write roots than the profile
    /// names one by one: the profile is refused, never written without them.
    @Test(.timeLimit(.minutes(1))) func tooManyCredentialAncestorsInsideAWriteRootRefuseTheProfile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-deep-profile-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let deep = (0..<(MCPSandbox.maximumCredentialAncestors + 1)).reduce(root) { url, _ in
            url.appendingPathComponent("d", isDirectory: true)
        }
        let home = deep.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("scratch"), withIntermediateDirectories: true)
        let result = MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false), scratch: root.appendingPathComponent("scratch").path,
            home: home.path, configDirectory: home.path + "/.config/rv",
            temporaryDirectory: root.appendingPathComponent("tmp").path)
        guard case .failure(let error) = result else {
            Issue.record("a profile with \(MCPSandbox.maximumCredentialAncestors + 1)+ ancestors was written")
            return
        }
        #expect(error.message.contains("ancestor"), "\(error.message)")
    }

    /// A symlinked directory above a credential, inside a write root, is
    /// named by its own (link) path as well as by where it resolves: a
    /// rename or unlink acts on the link, so naming only its target left
    /// the link free to be swapped for one into the cage. Both shapes: a
    /// credential link whose target runs through a linked directory
    /// (`~/.aws` → `x/aws`, `x` → `y`), and a linked parent (`~/.config` →
    /// `dotfiles/config`, for `~/.config/gh`).
    @Test(.timeLimit(.minutes(1))) func aSymlinkedDirectoryAboveACredentialIsNamedByItsLinkPath() throws {
        let root = try Self.resolvedTemporaryRoot("rv-ancestor-link")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["tmp", "scratch", "home", "y/aws", "dotfiles/config/gh"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let home = root.appendingPathComponent("home")
        try #require(symlink(root.appendingPathComponent("y").path, root.appendingPathComponent("x").path) == 0)
        try #require(symlink(root.appendingPathComponent("x/aws").path, home.appendingPathComponent(".aws").path) == 0)
        try #require(symlink(
            root.appendingPathComponent("dotfiles/config").path, home.appendingPathComponent(".config").path) == 0)
        let text = try MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false), scratch: root.appendingPathComponent("scratch").path,
            home: home.path, configDirectory: home.path + "/.config/rv",
            temporaryDirectory: root.appendingPathComponent("tmp").path).get()
        let ancestors = try #require(text.split(separator: "\n").first { $0.hasPrefix("(deny file-clone file-write-unlink ") })
        for path in ["x", "y", "home/.config", "dotfiles/config", "dotfiles", "home", ""] {
            let full = path.isEmpty ? root.path : root.appendingPathComponent(path).path
            #expect(ancestors.contains("(literal \"\(full)\")"), "\(full)")
        }
        #if os(macOS)
        #expect(MCPSandbox.profileCompileError(text) == nil)
        #endif
    }

    @Test(.timeLimit(.minutes(1))) func hostsAndGatewayEachGetOneLoopbackRule() throws {
        let root = try Self.resolvedTemporaryRoot("rv-gateway-profile")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("scratch"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home").path
        let ports = MCPSandbox.cageNetwork([:], proxy: (4321, "abc"), reach: .secretsGateway(port: 5151)).loopbackPorts
        #expect(ports == [4321, 5151])
        let text = try MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false, hosts: ["api.example.com"]),
            scratch: root.appendingPathComponent("scratch").path, home: home, configDirectory: home + "/.config/rv",
            temporaryDirectory: root.appendingPathComponent("tmp").path, loopbackPorts: ports).get()
        #expect(text.contains(
            "(deny network*)\n(allow network-outbound (remote tcp \"localhost:4321\"))\n"
                + "(allow network-outbound (remote tcp \"localhost:5151\"))"))
        #expect(text.components(separatedBy: "localhost:").count == 3)
        #if os(macOS)
        #expect(MCPSandbox.profileCompileError(text) == nil)
        #endif
    }

    /// What `apply` puts in the cage: the gateway port only for a
    /// placeholder server, and a proxy bypass that names only the gateway's
    /// address only when a `sandbox.hosts` proxy is also set.
    @Test func onlyAPlaceholderCageDialsTheGatewayAndItsRequestsSkipTheProxy() {
        let base = ["PATH": "/bin"]
        let both = MCPSandbox.cageNetwork(base, proxy: (4321, "abc"), reach: .secretsGateway(port: 5151))
        #expect(both.loopbackPorts == [4321, 5151])
        #expect(both.environment["NO_PROXY"] == "127.0.0.1" && both.environment["no_proxy"] == "127.0.0.1")
        #expect(both.environment["HTTPS_PROXY"] == "http://abc@127.0.0.1:4321")
        let gatewayOnly = MCPSandbox.cageNetwork(base, proxy: nil, reach: .secretsGateway(port: 5151))
        #expect(gatewayOnly.loopbackPorts == [5151])
        #expect(gatewayOnly.environment == base)
        let proxyOnly = MCPSandbox.cageNetwork(base, proxy: (4321, "abc"), reach: .standard)
        #expect(proxyOnly.loopbackPorts == [4321])
        #expect(proxyOnly.environment == MCPSandbox.proxyEnvironment(base, port: 4321, credential: "abc"))
        #expect(proxyOnly.environment["NO_PROXY"] == nil && proxyOnly.environment["no_proxy"] == nil)
        let neither = MCPSandbox.cageNetwork(base, proxy: nil, reach: .standard)
        #expect(neither.loopbackPorts.isEmpty)
        #expect(neither.environment == base)
    }
}

#if os(macOS)
@Suite("MCPSandbox hosts (live sandbox-exec)")
struct MCPSandboxHostsLiveTests {
    /// A listening socket on 127.0.0.1:0. Copyable, unlike the OAuth redirect listener.
    final class Loopback: @unchecked Sendable {
        let fd: Int32
        let port: Int

        init?() {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            self.fd = fd
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            var actual = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &actual) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            guard bound == 0, listen(fd, 1) == 0, named == 0 else {
                close(fd)
                return nil
            }
            port = Int(UInt16(bigEndian: actual.sin_port))
        }

        deinit { close(fd) }
    }

    @Test(.timeLimit(.minutes(1))) func cagedServerReachesItsProxyButNothingElse() throws {
        // Under the real home directory, never the checkout: a checkout
        // under /tmp sits inside the cage's writable temp roots by design.
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".rv-cage-test-hosts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let config = home.appendingPathComponent(".config/rv")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let other = try #require(Loopback())
        let script = """
            nc -z -G 2 127.0.0.1 \(other.port) && echo DIRECT_OK
            nc -z -G 2 127.0.0.1 "${HTTPS_PROXY##*:}" && echo PROXY_OK
            /usr/bin/python3 -c 'import socket; socket.getaddrinfo("www.apple.com", 443)' 2>/dev/null && echo DNS_OK
            echo "proxy=$HTTPS_PROXY"
            """
        var definition = MCPServerDefinition(name: "proxied", command: "/bin/sh", args: ["-c", script])
        definition.sandbox = MCPSandboxPolicy(network: false, hosts: ["api.example.com"])
        let launch = MCPUpstreamLaunch(
            server: "proxied", executable: "/usr/bin/env", arguments: ["/bin/sh", "-c", script], environment: ["PATH": "/usr/bin:/bin"])
        // Built from profile() directly: apply() refuses a home that is not
        // the passwd home, and this fixture's home is deliberately fake.
        let scratch = home.appendingPathComponent("Library/Caches/rv-mcp/proxied", isDirectory: true)
        #expect(MCPSandbox.createCheckedDirectory(scratch.path))
        let credential = MCPSandbox.proxyCredential()
        let proxy = EgressProxy(
            policy: EgressHostPolicy(allowedHosts: ["api.example.com"], relaysLoopback: false),
            record: { _ in }, clientCredential: credential)
        let port = try proxy.start().get()
        defer { proxy.stop() }
        let text = try MCPSandbox.profile(
            policy: try #require(definition.sandbox), scratch: scratch.path, home: home.path,
            configDirectory: config.path, temporaryDirectory: NSTemporaryDirectory(), loopbackPorts: [port]).get()
        var caged = launch
        caged.environment = MCPSandbox.proxyEnvironment(launch.environment, port: port, credential: credential)
        caged.executable = MCPSandbox.sandboxExec
        caged.arguments = ["-p", text, launch.executable] + launch.arguments
        caged.workingDirectory = scratch.path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: caged.executable)
        process.arguments = caged.arguments
        process.environment = caged.environment
        if let directory = caged.workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        #expect(output.contains("proxy=http://") && output.contains("@127.0.0.1:"), "\(output)")
        #expect(output.contains("PROXY_OK"), "\(output)")
        #expect(output.contains("DIRECT_OK") == false, "\(output)")
        #expect(output.contains("DNS_OK") == false, "\(output)")
    }

    /// Inside the cage, a file outside every write root cannot be hard
    /// linked into the scratch, and writing the would-be link's name leaves
    /// it unchanged. It can be cloned, as it can be copied: a clone is its
    /// own copy-on-write file, so writing the clone leaves it unchanged too
    /// (Rust's `std::fs::copy` clones first and fails outright on `EPERM`).
    /// A clone out of the scratch into that directory is refused. Links and
    /// clones between files in the scratch work (package managers link and
    /// clone inside their caches). The fake home is under the resolved temp
    /// directory. The outside file cannot be: `seatbeltWriteRoots` makes all
    /// of `/private/var/folders` and `/private/tmp` writable, a fake home's
    /// spare corners included. It is in a fresh 0700 directory under
    /// `/Users/Shared`, which no profile line names, never the real home;
    /// skipped where `/Users/Shared` is not writable.
    @Test(
        .timeLimit(.minutes(1)),
        .enabled(if: access("/Users/Shared", W_OK) == 0, "needs a writable /Users/Shared outside the cage's write roots"))
    func cagedServerCannotLinkOrWriteAFileFromOutsideItsWriteRoots() throws {
        let temporary = try #require(MCPSandbox.resolveExisting(FileManager.default.temporaryDirectory.path))
        let root = URL(fileURLWithPath: temporary, isDirectory: true)
            .appendingPathComponent("rv-cage-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let config = home.appendingPathComponent(".config/rv")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let tmp = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let project = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
            .appendingPathComponent("rv-cage-test-\(UUID().uuidString)", isDirectory: true)
        try #require(mkdir(project.path, 0o700) == 0, "could not create \(project.path): errno \(errno)")
        defer { try? FileManager.default.removeItem(at: project) }
        let outside = project.appendingPathComponent("App.swift")
        try Data("original".utf8).write(to: outside)
        var before = stat()
        try #require(lstat(outside.path, &before) == 0)

        let scratch = home.appendingPathComponent("Library/Caches/rv-mcp/linker", isDirectory: true)
        #expect(MCPSandbox.createCheckedDirectory(scratch.path))
        let text = try MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false), scratch: scratch.path, home: home.path,
            configDirectory: config.path, temporaryDirectory: tmp.path).get()
        // No profile line names `/Users/Shared`: it is not a write root.
        #expect(text.contains("/Users/Shared") == false, "\(text)")
        let script = """
            outside="$1"; s="$2"; project="$3"
            /bin/ln "$outside" "$s/linked" 2> "$s/ln.err" && echo LINK_OUT_OK
            grep -q "Operation not permitted" "$s/ln.err" && echo LINK_OUT_EPERM
            printf changed > "$s/linked"
            /bin/cp -c "$outside" "$s/cloned" && echo CLONE_OUT_OK
            printf changed > "$s/cloned"
            /bin/cp -c "$outside" "$project/escaped" 2> "$s/cp.err" && echo CLONE_ESCAPE_OK
            grep -q "Operation not permitted" "$s/cp.err" && echo CLONE_ESCAPE_EPERM
            /bin/cp "$outside" "$s/copied" && echo COPY_OK
            printf inner > "$s/a"
            /bin/ln "$s/a" "$s/b" && echo LINK_IN_OK
            /bin/cp -c "$s/a" "$s/c" && echo CLONE_IN_OK
            echo DONE
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: MCPSandbox.sandboxExec)
        process.arguments = ["-p", text, "/bin/sh", "-c", script, "sh", outside.path, scratch.path, project.path]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.currentDirectoryURL = scratch
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        // Hard bound: polls, never blocks in `waitid`; killed after 20 s.
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            Issue.record("the caged link probe did not finish")
            return
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        #expect(output.contains("DONE"), "\(output)")
        #expect(output.contains("LINK_OUT_OK") == false, "\(output)")
        #expect(output.contains("LINK_OUT_EPERM"), "\(output)")
        #expect(output.contains("CLONE_OUT_OK"), "\(output)")
        #expect(output.contains("CLONE_ESCAPE_OK") == false, "\(output)")
        #expect(output.contains("CLONE_ESCAPE_EPERM"), "\(output)")
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("escaped").path) == false)
        #expect(output.contains("COPY_OK"), "\(output)")
        #expect(output.contains("LINK_IN_OK"), "\(output)")
        #expect(output.contains("CLONE_IN_OK"), "\(output)")
        #expect(String(decoding: try Data(contentsOf: outside), as: UTF8.self) == "original")
        var after = stat()
        #expect(lstat(outside.path, &after) == 0)
        #expect(after.st_nlink == 1 && after.st_ino == before.st_ino)
        // What the write created in the scratch is its own file, not the outside inode.
        var written = stat()
        #expect(lstat(scratch.appendingPathComponent("linked").path, &written) == 0)
        #expect(written.st_ino != before.st_ino)
        var clone = stat()
        #expect(lstat(scratch.appendingPathComponent("cloned").path, &clone) == 0)
        #expect(clone.st_ino != before.st_ino)
    }
}
#endif
