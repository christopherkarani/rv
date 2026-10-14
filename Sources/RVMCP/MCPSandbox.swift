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
    /// Paths `profile` allows even when `policy.writable` is empty.
    static let seatbeltWriteRoots = ["/private/tmp", "/private/var/folders", "/dev"]

    /// Write paths a present sandbox still allows. Trust and import show this
    /// list. `~` is this home when `home` is set, so the review names the
    /// directory serve will expand. Temp is only `/private/tmp` and
    /// `/private/var/folders`, not whatever `TMPDIR` is at serve.
    public static func disclosedWritePaths(
        server name: String, policy: MCPSandboxPolicy, home: String? = nil
    ) -> [String] {
        func show(_ path: String) -> String {
            guard let home, path.hasPrefix("~/") else { return path }
            return home + String(path.dropFirst(1))
        }
        let scratch = show("~/Library/Caches/rv-mcp/\(name)")
        return [scratch] + seatbeltWriteRoots + defaultWritable.map(show) + policy.writable
    }

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
            let temporary = launch.environment["TMPDIR"] ?? NSTemporaryDirectory()
            if let widened = unreviewedWrite(
                policy: policy, scratch: scratch.path, home: home.path, temporaryDirectory: temporary)
            {
                return .failure(.sandbox(widened))
            }
            if let widened = unreviewedHome(home.path) {
                return .failure(.sandbox(widened))
            }
            do {
                try FileManager.default.createDirectory(
                    at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                return .failure(.sandbox("could not create \(scratch.path)"))
            }
            switch profile(
                policy: policy, scratch: scratch.path, home: home.path, configDirectory: configDirectory.path,
                temporaryDirectory: temporary)
            {
            case .failure(let error): return .failure(error)
            case .success(let text):
                var caged = launch
                caged.executable = sandboxExec
                caged.arguments = ["-p", text, launch.executable] + launch.arguments
                caged.workingDirectory = scratch.path
                return .success(caged)
            }
            #else
            return .failure(.sandbox("\(definition.name) asks for a sandbox, which rv supports only on macOS"))
            #endif
        }
    }

    public static func profile(
        policy: MCPSandboxPolicy, scratch: String, home: String, configDirectory: String, temporaryDirectory: String
    ) -> Result<String, MCPLaunchError> {
        func expand(_ path: String) -> String {
            path.hasPrefix("~/") ? home + path.dropFirst(1) : path
        }
        let writable = [scratch, temporaryDirectory] + seatbeltWriteRoots
            + (defaultWritable + policy.writable).map(expand)
        if let widened = unreviewedWrite(
            policy: policy, scratch: scratch, home: home, temporaryDirectory: temporaryDirectory)
        {
            return .failure(.sandbox(widened))
        }
        let unreadable = deniedReads.map(expand) + [configDirectory]
        var lines = [
            "(version 1)",
            "(allow default)",
            "(deny file-write*)",
            "(allow file-write* " + paths(writable, denyTargets: false) + ")",
            "(deny file-read* file-write* " + paths(unreadable, denyTargets: true) + ")",
        ]
        if policy.network == false {
            lines.append("(deny network*)")
        }
        return .success(lines.joined(separator: "\n"))
    }

    /// The real path when it is not the path the review named. `/tmp` and
    /// `/private/tmp` are the same directory. Any other symlink target is refused.
    static func unreviewedWrite(
        policy: MCPSandboxPolicy, scratch: String, home: String, temporaryDirectory: String
    ) -> String? {
        func expand(_ path: String) -> String {
            path.hasPrefix("~/") ? home + path.dropFirst(1) : path
        }
        if let widened = unreviewedTemporary(temporaryDirectory) {
            return widened
        }
        let writable = [scratch, temporaryDirectory] + seatbeltWriteRoots
            + (defaultWritable + policy.writable).map(expand)
        return unreviewedWrite(paths: writable)
    }

    /// `TMPDIR` is a write root only when it is `/private/tmp`,
    /// `/private/var/folders`, or a directory inside one of those. A concrete
    /// path the review never named is refused.
    static func unreviewedTemporary(_ path: String) -> String? {
        let resolved = tmpAlias(realPath(path))
        let roots = ["/private/tmp", "/private/var/folders"]
        if roots.contains(where: { resolved == $0 || resolved.hasPrefix($0 + "/") }) {
            return nil
        }
        return "\(MCPDisplayedText.field(path)) resolves to \(MCPDisplayedText.field(realPath(path))), which was not the path reviewed"
    }

    /// `~` in the review is the account home. A serve-time `HOME` that points
    /// somewhere else is a write root the review did not name.
    static func unreviewedHome(_ home: String) -> String? {
        guard let passwd = passwdHome() else {
            return "\(MCPDisplayedText.field(home)) resolves to a directory that was not the path reviewed"
        }
        let resolved = realPath(home)
        if sameReviewedDirectory(resolved, realPath(passwd)) { return nil }
        return "\(MCPDisplayedText.field(home)) resolves to \(MCPDisplayedText.field(resolved)), which was not the path reviewed"
    }

    static func passwdHome() -> String? {
        guard let entry = getpwuid(geteuid()), let dir = entry.pointee.pw_dir else { return nil }
        let home = String(cString: dir)
        return home.isEmpty ? nil : home
    }

    static func unreviewedWrite(paths writable: [String]) -> String? {
        for path in writable {
            let resolved = realPath(path)
            if sameReviewedDirectory(path, resolved) { continue }
            return "\(MCPDisplayedText.field(path)) resolves to \(MCPDisplayedText.field(resolved)), which was not the path reviewed"
        }
        return nil
    }

    /// Same directory, including the `/tmp` → `/private/tmp` alias. A symlink
    /// to a different tree is not the same directory.
    static func sameReviewedDirectory(_ reviewed: String, _ resolved: String) -> Bool {
        if reviewed == resolved { return true }
        return tmpAlias(reviewed) == tmpAlias(resolved)
    }

    static func tmpAlias(_ path: String) -> String {
        if path == "/tmp" { return "/private/tmp" }
        if path.hasPrefix("/tmp/") { return "/private/tmp/" + path.dropFirst("/tmp/".count) }
        return path
    }

    /// Allow filters add a resolved spelling only when it is the same
    /// directory. Deny filters also add a different real path, so a symlink
    /// at `~/.ssh` or the config directory does not leave the target readable.
    static func paths(_ raw: [String], denyTargets: Bool) -> String {
        var seen = Set<String>()
        var filters: [String] = []
        for path in raw {
            let resolved = realPath(path)
            let spellings = (denyTargets || sameReviewedDirectory(path, resolved)) ? [path, resolved] : [path]
            for spelling in spellings where seen.insert(spelling).inserted {
                filters.append("(subpath \"\(escape(spelling))\")")
            }
        }
        return filters.joined(separator: " ")
    }

    static func realPath(_ path: String) -> String {
        if let resolved = resolveExisting(path) { return resolved }
        return resolvingMissingSuffix(path)
    }

    /// The leaf does not exist yet. Resolve the nearest existing ancestor so
    /// a parent symlink cannot hide the directory `createDirectory` would make.
    static func resolvingMissingSuffix(_ path: String) -> String {
        var suffix: [String] = []
        var current = path
        while true {
            let url = URL(fileURLWithPath: current)
            let parent = url.deletingLastPathComponent().path
            let leaf = url.lastPathComponent
            if parent == current || leaf.isEmpty || leaf == "/" { return path }
            suffix.append(leaf)
            if let resolved = resolveExisting(parent) {
                return suffix.reversed().reduce(resolved) { base, part in
                    URL(fileURLWithPath: base).appendingPathComponent(part).path
                }
            }
            current = parent
        }
    }

    static func resolveExisting(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func escape(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
