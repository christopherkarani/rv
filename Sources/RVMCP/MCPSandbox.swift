#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

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

    /// The planner hook `rv mcp serve` passes to `MCPLaunchPlanner.plan`.
    public static func apply(
        configDirectory: URL, home: URL
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
            let profile = profile(
                policy: policy, scratch: scratch.path, home: home.path, configDirectory: configDirectory.path,
                temporaryDirectory: launch.environment["TMPDIR"] ?? NSTemporaryDirectory())
            var caged = launch
            caged.executable = sandboxExec
            caged.arguments = ["-p", profile, launch.executable] + launch.arguments
            caged.workingDirectory = scratch.path
            return .success(caged)
            #else
            return .failure(.sandbox("\(definition.name) asks for a sandbox, which rv supports only on macOS"))
            #endif
        }
    }

    public static func profile(
        policy: MCPSandboxPolicy, scratch: String, home: String, configDirectory: String, temporaryDirectory: String
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
        if policy.network == false {
            lines.append("(deny network*)")
        }
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
