#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVIsolation
import Synchronization

/// Seatbelt cage for upstream MCP servers that set `sandbox` in mcp.json.
/// Allow-default (so npx/uvx/node work) with writes confined to a scratch
/// directory, temp and package caches, and reads of credential stores and
/// other hosts' MCP configs denied. Not a deny-default runtime cage.
public enum MCPSandbox {
    public static let sandboxExec = "/usr/bin/sandbox-exec"

    static let defaultWritable = ["~/.npm", "~/.cache", "~/Library/Caches"]

    static let deniedReads = [
        "~/.ssh", "~/.aws", "~/.gnupg", "~/.kube", "~/.docker", "~/.config/gh", "~/.config/gcloud", "~/.azure",
        "~/Library/Keychains", "~/Library/Cookies", "~/Library/Application Support/Google/Chrome",
        "~/Library/Application Support/Firefox", "~/Library/Application Support/BraveSoftware",
        "~/.claude.json", "~/.codex", "~/.cursor", "~/.codeium", "~/.gemini", "~/.config/opencode",
        "~/Library/Application Support/Claude", "~/.netrc", "~/.npmrc", "~/.pypirc",
    ]

    /// Allowlist proxies for `sandbox.hosts`; they live as long as `rv mcp serve`.
    static let proxies = Mutex<[EgressProxy]>([])

    /// Stops every proxy this process started; called when serve exits.
    public static func stopProxies() {
        proxies.withLock { running in
            running.forEach { $0.stop() }
            running = []
        }
    }

    /// The proxy credential a caged launch carries in its proxy URL, so the
    /// gateway can scrub it from anything the server echoes back.
    public static func proxyCredential(in environment: [String: String]) -> String? {
        guard let url = environment["HTTPS_PROXY"], url.hasPrefix("http://rv:"),
            let at = url.firstIndex(of: "@")
        else { return nil }
        let credential = String(url[url.index(url.startIndex, offsetBy: "http://rv:".count)..<at])
        return credential.isEmpty ? nil : credential
    }

    /// The planner hook `rv mcp serve` passes to `MCPLaunchPlanner.plan`.
    /// `denied` hears each CONNECT a `sandbox.hosts` proxy refuses.
    public static func apply(
        configDirectory: URL, home: URL, denied: @escaping @Sendable (String, EgressProxyDenial) -> Void = { _, _ in }
    ) -> (MCPServerDefinition, MCPUpstreamLaunch) -> Result<MCPUpstreamLaunch, MCPLaunchError> {
        { definition, launch in
            guard let policy = definition.sandbox else { return .success(launch) }
            #if os(macOS)
            let scratch = home.appendingPathComponent("Library/Caches/rv-mcp/\(definition.name)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                return .failure(.sandbox("could not create \(scratch.path)"))
            }
            var environment = launch.environment
            var proxyPort: Int?
            if policy.hosts.isEmpty == false {
                let server = definition.name
                let credential = proxyCredential()
                let proxy = EgressProxy(
                    policy: EgressHostPolicy(allowedHosts: Set(policy.hosts), relaysLoopback: false),
                    record: { denied(server, $0) }, clientCredential: credential)
                guard case .success(let port) = proxy.start() else {
                    return .failure(.sandbox("could not start the egress proxy for \(server)"))
                }
                proxies.withLock { $0.append(proxy) }
                proxyPort = port
                environment = proxyEnvironment(environment, port: port, credential: credential)
            }
            let profile = profile(
                policy: policy, scratch: scratch.path, home: home.path, configDirectory: configDirectory.path,
                temporaryDirectory: launch.environment["TMPDIR"] ?? NSTemporaryDirectory(), proxyPort: proxyPort)
            var caged = launch
            caged.environment = environment
            caged.executable = sandboxExec
            caged.arguments = ["-p", profile, launch.executable] + launch.arguments
            caged.workingDirectory = scratch.path
            return .success(caged)
            #else
            return .failure(.sandbox("\(definition.name) asks for a sandbox, which rv supports only on macOS"))
            #endif
        }
    }

    /// 32 random bytes, hex. The proxy requires this as `Proxy-Authorization`.
    static func proxyCredential() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// Points HTTP clients at the proxy; Node's fetch needs `NODE_USE_ENV_PROXY`.
    /// The credential is the userinfo of the proxy URL so clients send it as
    /// proxy basic auth. A process that can only dial 127.0.0.1 does not have it.
    public static func proxyEnvironment(_ base: [String: String], port: Int, credential: String) -> [String: String] {
        var environment = base
        let url = "http://rv:\(credential)@127.0.0.1:\(port)"
        for key in ["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY"] {
            environment[key] = url
            environment[key.lowercased()] = url
        }
        environment["NODE_USE_ENV_PROXY"] = "1"
        environment["NO_PROXY"] = nil
        environment["no_proxy"] = nil
        return environment
    }

    public static func profile(
        policy: MCPSandboxPolicy, scratch: String, home: String, configDirectory: String, temporaryDirectory: String,
        proxyPort: Int? = nil
    ) -> String {
        func expand(_ path: String) -> String {
            path.hasPrefix("~/") ? home + path.dropFirst(1) : path
        }
        let writable = [scratch, temporaryDirectory, "/private/tmp", "/private/var/folders", "/dev"]
            + (defaultWritable + policy.writable).map(expand)
        let unreadable = deniedReads.map(expand) + [configDirectory]
        var lines = [
            "(version 1)",
            "(allow default)",
            "(deny file-write*)",
            "(allow file-write* " + paths(writable) + ")",
            "(deny file-read* file-write* " + paths(unreadable) + ")",
        ]
        // `hosts` is the stronger statement: with an allowlist the network is
        // caged to the proxy even if `network` was also set (the decoder
        // already refuses that combination; the profile must not depend on it).
        if policy.network == false || proxyPort != nil {
            lines.append("(deny network*)")
            // Seatbelt network addresses accept only `*` or `localhost` as
            // the host; `127.0.0.1:<port>` fails to compile and the server
            // never starts.
            if let proxyPort { lines.append("(allow network-outbound (remote tcp \"localhost:\(proxyPort)\"))") }
        }
        // No mach-lookup rule for the resolver: verified live on macOS that
        // (deny network*) alone makes getaddrinfo fail inside this profile
        // (the dnssd service deny neither helps nor is needed), and the live
        // cage test probes that a caged process cannot resolve names.
        return lines.joined(separator: "\n")
    }

    /// `subpath` filters on real paths; both spellings are listed when a
    /// prefix is a symlink (`/tmp` → `/private/tmp`).
    static func paths(_ raw: [String]) -> String {
        var seen = Set<String>()
        var filters: [String] = []
        for path in raw {
            for spelling in [path, realPath(path)] where seen.insert(spelling).inserted {
                filters.append("(subpath \"\(escape(spelling))\")")
            }
        }
        return filters.joined(separator: " ")
    }

    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func escape(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
