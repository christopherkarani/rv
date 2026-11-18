#if os(Linux)
import Foundation
import Glibc
import RVDomain
import RVIsolation

/// The Linux side of `MCPSandbox`: reads the host, builds the plan
/// (`MCPLinuxCage`), and turns the launch into one through
/// `rv-isolation-exec --confine`. The helper applies the Landlock ruleset
/// and the socket filter in the server's process before `exec`; if it
/// cannot, it exits without running the server, so a server that runs is
/// a server that is caged.
extension MCPSandbox {
    /// Where Linux keeps the stores `deniedReads` names under `~/Library`
    /// (keyrings, browser profiles as packaged by the distribution, Snap
    /// and Flatpak, the Claude apps), and the credential files macOS keeps
    /// in the Keychain instead.
    static let linuxDeniedReads = [
        "~/.local/share/keyrings", "~/.local/share/kwalletd", "~/.password-store", "~/.git-credentials",
        "~/.config/git/credentials", "~/.vault-token",
        "~/.config/google-chrome", "~/.config/chromium", "~/.mozilla", "~/.config/BraveSoftware",
        "~/snap/firefox", "~/snap/chromium", "~/.var/app", "~/.config/Claude", "~/.claude/.credentials.json",
        "~/.config/containers/auth.json", "~/.Xauthority",
    ]
    /// Write roots every cage has, as `/private/tmp` and `/dev` on macOS.
    /// Shared with every other program: see `MCPLinuxCage.Plan.shared`.
    static let landlockSharedRoots = ["/tmp", "/dev"]
    static let linuxDefaultWritable = ["~/.npm", "~/.cache"]

    static func linuxScratch(server: String, home: String) -> String {
        home + "/.cache/rv-mcp/" + server
    }

    /// This host's cage, probed once: the helper beside rv, and the
    /// Landlock ABI the kernel reports to it.
    public static let linuxSupport: MCPLinuxCageSupport = probeLinuxSupport(helper: linuxHelper)

    static func probeLinuxSupport(helper: String?) -> MCPLinuxCageSupport {
        guard let helper else { return .resolve(helperInstalled: false, report: nil) }
        // From `/`: what the kernel can do does not depend on where rv was
        // started, and a directory this user may not enter (a service's,
        // another account's checkout) would keep the helper from starting.
        guard
            let outcome = BoundedProcess.run(
                helper, ["--landlock-abi"], environment: [:], timeout: 10, workingDirectory: "/"),
            outcome.status == 0
        else { return .resolve(helperInstalled: true, report: nil) }
        let text = String(decoding: outcome.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return .resolve(helperInstalled: true, report: text)
    }

    /// A directory's entries and what each is, without following links.
    static func listEntries(_ directory: String) -> [MCPLinuxCage.Entry]? {
        guard let stream = opendir(directory) else { return nil }
        defer { closedir(stream) }
        var entries: [MCPLinuxCage.Entry] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else { return errno == 0 ? entries : nil }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: pointer.pointee)) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            var info = stat()
            // Gone since the listing: nothing to grant.
            guard lstat(directory == "/" ? "/" + name : directory + "/" + name, &info) == 0 else { continue }
            let kind: MCPLinuxCage.EntryKind =
                switch info.st_mode & S_IFMT {
                case S_IFDIR: .directory
                case S_IFREG: .file
                case S_IFLNK: .symlink
                default: .other
                }
            entries.append(MCPLinuxCage.Entry(name: name, kind: kind))
        }
    }

    /// The paths no caged server reads: each store and rv's own
    /// configuration, as spelled and as resolved, so a link at `~/.ssh`
    /// does not leave its target readable.
    static func linuxProtectedPaths(home: String, configDirectory: String) -> Set<String> {
        var protected: Set<String> = []
        // The runtime directory holds the session's sockets and tokens
        // (container and X authority files among them).
        for path in (deniedReads + linuxDeniedReads).map({ $0.hasPrefix("~/") ? home + $0.dropFirst(1) : $0 })
            + [configDirectory, "/run/user/\(getuid())"]
        {
            protected.insert(lexicalAbsolute(path))
            protected.insert(lexicalAbsolute(deniedRealPath(path)))
        }
        return protected
    }

    static func linuxRefusal(_ server: String, _ reason: String) -> MCPLaunchError {
        .sandbox("\(MCPDisplayedText.field(server)) cannot be sandboxed: \(reason); `rv mcp serve` will not run it uncaged")
    }

    /// The helper beside rv, or nil.
    static var linuxHelper: String? { SecretRunLauncher.path() }

    /// `accountHome` is the home the review's `~` stands for (the account's,
    /// from the password database); tests name a temporary one.
    static func applyLinux(
        definition: MCPServerDefinition, launch: MCPUpstreamLaunch, policy: MCPSandboxPolicy, configDirectory: URL,
        home: URL, accountHome: String? = passwdHome(), support: MCPLinuxCageSupport = MCPSandbox.linuxSupport,
        helper: String? = MCPSandbox.linuxHelper, notice: (String) -> Void,
        denied: @escaping @Sendable (String, EgressProxyDenial) -> Void,
        enforcement: MCPSandboxEnforcement = .enforce,
        audited: @escaping @Sendable (String, EgressProxyDenial) -> Bool = { _, _ in false }
    ) -> Result<MCPUpstreamLaunch, MCPLaunchError> {
        let server = definition.name
        let abi: LandlockABI
        switch support {
        case .unavailable(let unavailable): return .failure(linuxRefusal(server, unavailable.reason))
        case .confines(let admitted): abi = admitted
        }
        guard let helper else {
            return .failure(linuxRefusal(server, MCPLinuxCageSupport.Unavailable.helperMissing.reason))
        }
        // The helper is the first thing to run with this environment, uncaged.
        if let name = launch.environment.keys.sorted().first(where: MCPLinuxCage.isLoaderVariable) {
            return .failure(linuxRefusal(server, MCPLinuxCage.Refusal.loaderVariable(name).reason))
        }
        // `~` in the review is the account home; a serve-time HOME that is
        // another directory is a tree the review did not name.
        guard let homePath = resolveExisting(home.path), let accountHome, resolveExisting(accountHome) == homePath else {
            return .failure(.sandbox(
                "\(MCPDisplayedText.field(home.path)) resolves to a directory that was not the path reviewed"))
        }

        // The write roots: all must be the directories the review named, not
        // links to others. The helper opens each without following a link.
        if let temporary = launch.environment["TMPDIR"] {
            let resolved = resolveExisting(temporary)
            guard let resolved, resolved == "/tmp" || resolved.hasPrefix("/tmp/") else {
                let shown = MCPDisplayedText.field(resolved ?? temporary)
                return .failure(.sandbox(
                    "\(MCPDisplayedText.field(temporary)) resolves to \(shown), which was not the path reviewed"))
            }
        }
        let defaults = linuxDefaultWritable.map { homePath + $0.dropFirst(1) }
        for path in defaults where resolveExisting(path) == nil {
            // What npx and uvx would create on first use; a cage cannot
            // grant a directory that is not there yet.
            guard mkdir(path, 0o755) == 0 || errno == EEXIST else {
                return .failure(.sandbox(scratchCreationFailure(path)))
            }
        }
        // After `~/.cache` exists: the scratch is created under ancestors held from here.
        let scratch = linuxScratch(server: server, home: homePath)
        guard let pinned = pinExistingAncestors(scratch) else {
            return .failure(.sandbox(scratchCreationFailure(scratch)))
        }
        let requested = policy.writable.map { $0.hasPrefix("~/") ? homePath + $0.dropFirst(1) : $0 }
        for path in landlockSharedRoots + defaults + requested {
            guard let resolved = resolveExisting(path) else {
                return .failure(.sandbox(
                    "sandbox.writable \(MCPDisplayedText.field(path)) does not exist; create it, then run `rv mcp serve`"))
            }
            guard resolved == lexicalAbsolute(path) else {
                return .failure(.sandbox(
                    "\(MCPDisplayedText.field(path)) resolves to \(MCPDisplayedText.field(resolved)), "
                        + "which was not the path reviewed"))
            }
        }
        let writable = [scratch] + requested.map(lexicalAbsolute)
        let shared = landlockSharedRoots + defaults.map(lexicalAbsolute)

        let protected = linuxProtectedPaths(home: homePath, configDirectory: configDirectory.path)
        if let conflict = MCPLinuxCage.writableConflict(writable + shared, protected: protected) {
            return .failure(linuxRefusal(server, conflict.reason))
        }
        let readable: [String]
        switch MCPLinuxCage.readable(protecting: protected, list: listEntries) {
        case .failure(let refusal): return .failure(linuxRefusal(server, refusal.reason))
        case .success(let paths): readable = paths
        }

        var environment = launch.environment
        var proxyPort: UInt16?
        if policy.hosts.isEmpty == false {
            let credential = proxyCredential()
            let proxy = hostsProxy(
                server: server, hosts: policy.hosts, enforcement: enforcement, credential: credential,
                denied: denied, audited: audited)
            guard case .success(let port) = proxy.start(), let tcp = UInt16(exactly: port), tcp != 0 else {
                return .failure(.sandbox("could not start the egress proxy for \(server)"))
            }
            track(proxy, server: server)
            proxyPort = tcp
            environment = proxyEnvironment(environment, port: port, credential: credential)
        }
        guard createPinned(scratch, pinned: pinned), resolveExisting(scratch) == scratch else {
            return .failure(.sandbox(scratchCreationFailure(scratch)))
        }

        let plan = MCPLinuxCage.Plan(
            readable: readable, writable: writable, shared: shared, proxyPort: proxyPort)
        if let line = MCPLinuxCage.notice(server: server, abi: abi) { notice(line) }
        var caged = launch
        caged.environment = environment
        caged.executable = helper
        caged.arguments = plan.arguments(executable: launch.executable, argv: [launch.executable] + launch.arguments)
        caged.workingDirectory = scratch
        return .success(caged)
    }
}
#endif
