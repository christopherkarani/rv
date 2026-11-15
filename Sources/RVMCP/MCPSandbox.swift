#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVIsolation
import Synchronization

/// What a caged server may dial on loopback besides its `sandbox.hosts` proxy.
public enum MCPCageReach: Sendable, Equatable {
    case standard
    /// The secrets gateway its placeholders are spent through.
    case secretsGateway(port: Int)
}

/// Seatbelt cage for upstream MCP servers that set `sandbox` in mcp.json.
/// Allow-default (so npx/uvx/node work) with writes confined to a scratch
/// directory, temp and package caches, and reads of credential stores and
/// other hosts' MCP configs denied. Not a deny-default runtime cage.
public enum MCPSandbox {
    public static let sandboxExec = "/usr/bin/sandbox-exec"

    /// Whether serve cages local servers on this host: Seatbelt on macOS;
    /// on Linux, Landlock and a seccomp socket filter on a kernel that has
    /// both (6.7 or later) with `rv-isolation-exec` installed. Elsewhere
    /// bare servers run uncaged, and sandboxed ones, or every local one
    /// under an organization's `requireSandbox`, are refused.
    #if os(macOS)
    public static let enforced = true
    #elseif os(Linux)
    public static let enforced = MCPLinuxCage.isRequired(linuxSupport)
    #else
    public static let enforced = false
    #endif

    /// Why this host has no cage, for the messages that refuse without one.
    public static var unavailability: String {
        #if os(Linux)
        if case .unavailable(let unavailable) = linuxSupport { return unavailable.reason }
        #endif
        return "it needs macOS, or Linux 6.7 or later"
    }

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
        #if os(Linux)
        return [show("~/.cache/rv-mcp/\(name)")] + landlockSharedRoots + linuxDefaultWritable.map(show) + policy.writable
        #else
        let scratch = show("~/Library/Caches/rv-mcp/\(name)")
        return [scratch] + seatbeltWriteRoots + defaultWritable.map(show) + policy.writable
        #endif
    }

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
        guard let url = environment["HTTPS_PROXY"], url.hasPrefix("http://"),
            let at = url.firstIndex(of: "@")
        else { return nil }
        let credential = String(url[url.index(url.startIndex, offsetBy: "http://".count)..<at])
        return credential.isEmpty ? nil : credential
    }

    /// The planner hook `rv mcp serve` passes to `MCPLaunchPlanner.plan`.
    /// `denied` hears each CONNECT a `sandbox.hosts` proxy refuses.
    /// `enforced` is whether this platform can build the cage; without it
    /// a server that asks for one is refused, never run bare.
    /// `notice` hears what rv says about a cage it built (on Linux, what
    /// the kernel's Landlock leaves open); it goes to stderr by default.
    public static func apply(
        configDirectory: URL, home: URL, enforced: Bool = MCPSandbox.enforced,
        notice: @escaping @Sendable (String) -> Void = { MCPGatewayRuntime.writeStderrLine($0 + "\n") },
        denied: @escaping @Sendable (String, EgressProxyDenial) -> Void = { _, _ in }
    ) -> (MCPServerDefinition, MCPUpstreamLaunch, MCPCageReach) -> Result<MCPUpstreamLaunch, MCPLaunchError> {
        { definition, launch, reach in
            guard let policy = definition.sandbox else { return .success(launch) }
            guard enforced else { return .failure(.sandbox(MCPPlatformSupport.sandboxUnenforced(server: definition.name))) }
            #if os(macOS)
            let scratch = home.appendingPathComponent("Library/Caches/rv-mcp/\(definition.name)", isDirectory: true)
            let temporary = launch.environment["TMPDIR"] ?? NSTemporaryDirectory()
            guard let pinned = pinExistingAncestors(scratch.path) else {
                return .failure(.sandbox(scratchCreationFailure(scratch.path)))
            }
            if let widened = unreviewedWrite(
                policy: policy, scratch: scratch.path, home: home.path, temporaryDirectory: temporary,
                scratchMustExist: false)
            {
                return .failure(.sandbox(widened))
            }
            if let widened = unreviewedHome(home.path) {
                return .failure(.sandbox(widened))
            }
            var proxied: (port: Int, credential: String)?
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
                proxied = (port, credential)
            }
            let network = cageNetwork(launch.environment, proxy: proxied, reach: reach)
            guard createPinned(scratch.path, pinned: pinned) else {
                return .failure(.sandbox(scratchCreationFailure(scratch.path)))
            }
            switch profile(
                policy: policy, scratch: scratch.path, home: home.path, configDirectory: configDirectory.path,
                temporaryDirectory: temporary, loopbackPorts: network.loopbackPorts)
            {
            case .failure(let error): return .failure(error)
            case .success(let text):
                // A profile sandbox-exec refuses would surface only as the
                // server's process exiting; name the cause before launch.
                if let reason = profileCompileError(text) {
                    return .failure(profileFailure(server: definition.name, reason: reason))
                }
                var caged = launch
                caged.environment = network.environment
                caged.executable = sandboxExec
                caged.arguments = ["-p", text, launch.executable] + launch.arguments
                caged.workingDirectory = scratch.path
                return .success(caged)
            }
            #elseif os(Linux)
            return applyLinux(
                definition: definition, launch: launch, policy: policy, configDirectory: configDirectory, home: home,
                notice: notice, denied: denied)
            #else
            return .failure(.sandbox(MCPPlatformSupport.sandboxUnenforced(server: definition.name)))
            #endif
        }
    }

    /// 32 random bytes, hex. The proxy requires this as `Proxy-Authorization`.
    static func proxyCredential() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// Points HTTP clients at the proxy; Node's fetch needs `NODE_USE_ENV_PROXY`.
    /// The credential is the userinfo of the proxy URL — the token-as-username
    /// convention the egress proxy parses — so clients send it as proxy basic
    /// auth. A process that can only dial 127.0.0.1 does not have it.
    public static func proxyEnvironment(_ base: [String: String], port: Int, credential: String) -> [String: String] {
        var environment = base
        let url = "http://\(credential)@127.0.0.1:\(port)"
        for key in ["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY"] {
            environment[key] = url
            environment[key.lowercased()] = url
        }
        environment["NODE_USE_ENV_PROXY"] = "1"
        environment["NO_PROXY"] = nil
        environment["no_proxy"] = nil
        return environment
    }

    /// A caged server's environment and the loopback ports it may dial: its
    /// `sandbox.hosts` proxy, if it has one, and for placeholders the secrets
    /// gateway. The egress proxy does not relay loopback, so with both a
    /// base-URL request to the gateway must skip the proxy: `NO_PROXY` names
    /// the gateway's address, and nothing else.
    static func cageNetwork(
        _ base: [String: String], proxy: (port: Int, credential: String)?, reach: MCPCageReach
    ) -> (environment: [String: String], loopbackPorts: [Int]) {
        var environment = base
        var ports: [Int] = []
        if let proxy {
            environment = proxyEnvironment(environment, port: proxy.port, credential: proxy.credential)
            ports.append(proxy.port)
        }
        switch reach {
        case .standard: break
        case .secretsGateway(let port):
            if proxy != nil {
                environment["NO_PROXY"] = "127.0.0.1"
                environment["no_proxy"] = "127.0.0.1"
            }
            ports.append(port)
        }
        return (environment, ports)
    }

    public static func profile(
        policy: MCPSandboxPolicy, scratch: String, home: String, configDirectory: String, temporaryDirectory: String,
        loopbackPorts: [Int] = []
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
        let writeAllow = paths(writable, denyTargets: false)
        guard let ancestors = credentialAncestors(unreadable, insideWriteRoots: writable) else {
            return .failure(.sandbox(
                "more than \(maximumCredentialAncestors) credential ancestors lie inside the write roots"))
        }
        let credentialDeny = "(deny file-read* file-write* file-link file-clone "
            + paths(unreadable, denyTargets: true) + symlinkDenies(unreadable) + ")"
        // `file-write*` does not cover `file-link` or `file-clone`, which
        // `(allow default)` would otherwise allow everywhere. A hard link
        // needs both of its ends allowed (checked live on macOS 27), so links
        // are allowed only among the write roots: package managers link
        // inside their caches.
        //
        // A file clone needs read on its source, so a credential file is
        // covered by the credential deny. A directory clone is checked only
        // at its top directory, and the kernel copies every file under it,
        // denied ones too: cloning `~/.config` would copy `~/.config/gh`. So
        // a directory outside the write roots is never cloned. File-by-file
        // copies and clones (`cp -c`, uv, Rust's `std::fs::copy`, Node's
        // `fs.cpSync`) are unaffected; only a raw `clonefile(2)` of such a
        // directory is refused. A credential ancestor inside a write root
        // (a home under the temp directory, a target under a cache) is named
        // one by one, refused a clone and a rename, so the credential is
        // neither copied nor moved out from under its deny. One that is
        // missing is refused a create too: a symlink, a link or directory
        // renamed onto it, or a hard link there would hold the credential
        // once its owner writes it. A plain `mkdir` there is refused with
        // them, since Seatbelt checks it as the same create as a directory
        // renamed in (probed); making one that exists still fails EEXIST.
        //
        // A hard link an uncaged process planted under a write root is not
        // seen by any path rule.
        var lines = [
            "(version 1)",
            "(allow default)",
            "(deny file-write*)",
            "(deny file-link)",
            "(allow file-write* " + writeAllow + ")",
            "(allow file-link " + writeAllow + ")",
            "(deny file-clone (require-all (vnode-type DIRECTORY) (require-not (require-any " + writeAllow + "))))",
        ]
        if ancestors.isEmpty == false {
            lines.append("(deny file-clone file-write-unlink file-write-create file-link " + ancestorFilters(ancestors) + ")")
        }
        lines.append(credentialDeny)
        // `KERN_PROCARGS2` hands a same-uid caller the exec-time arguments and
        // environment of any process that is not a platform binary: rv puts
        // a server's `secrets` there, and serve's own holds the host's
        // tokens. The kernel consults both a sysctl check (the name carries
        // the pid, so only a prefix matches) and a pidinfo check; refusing
        // both for every process outside this sandbox instance refuses the
        // read, while the server's own and its children's still work
        // (measured on macOS 27; `(target others)` alone did not refuse it).
        lines.append("(deny sysctl-read (sysctl-name-prefix \"kern.procargs\"))")
        lines.append("(deny process-info-pidinfo (require-not (target same-sandbox)))")
        // `hosts` is the stronger statement: with an allowlist the network is
        // caged to the proxy even if `network` was also set (the decoder
        // already refuses that combination; the profile must not depend on it).
        if policy.network == false || loopbackPorts.isEmpty == false {
            lines.append("(deny network*)")
            // Seatbelt network addresses accept only `*` or `localhost` as
            // the host; `127.0.0.1:<port>` fails to compile and the server
            // never starts.
            for port in loopbackPorts { lines.append("(allow network-outbound (remote tcp \"localhost:\(port)\"))") }
        }
        // No mach-lookup rule for the resolver: verified live on macOS that
        // (deny network*) alone makes getaddrinfo fail inside this profile
        // (the dnssd service deny neither helps nor is needed), and the live
        // cage test probes that a caged process cannot resolve names.
        return .success(lines.joined(separator: "\n"))
    }

    /// Shown when the scratch path cannot be pinned or created. The path is
    /// fielded once here. Callers that already field a reason do not use this.
    static func scratchCreationFailure(_ path: String) -> String {
        "could not create \(MCPDisplayedText.field(path))"
    }

    /// The real path when it is not the path the review named. `/tmp` and
    /// `/private/tmp` are the same directory. Any other symlink target is refused.
    static func unreviewedWrite(
        policy: MCPSandboxPolicy, scratch: String, home: String, temporaryDirectory: String,
        scratchMustExist: Bool = true
    ) -> String? {
        func expand(_ path: String) -> String {
            path.hasPrefix("~/") ? home + path.dropFirst(1) : path
        }
        // createPinned records the leaf it created and that leaf's parent.
        // Moving the leaf inode into a planted rv-mcp/<server> keeps the
        // inode and changes the parent. A path that is simply gone is the
        // same swap with nothing planted there.
        if let recorded = createdLeafIdentity(scratch), leafIdentity(scratch) != recorded {
            let resolved = realPath(scratch)
            return "\(MCPDisplayedText.field(scratch)) resolves to \(MCPDisplayedText.field(resolved)), which was not the path reviewed"
        }
        if scratchMustExist, resolveExisting(scratch) == nil {
            // profile() runs after createPinned: a scratch that is not there
            // was never created under the held ancestors (or was swapped
            // away), so it is not a write root rv reviewed. apply()'s
            // pre-creation check passes scratchMustExist: false; the paths
            // check below still refuses a missing path that resolves through
            // a symlinked ancestor to a different tree.
            let resolved = realPath(scratch)
            if sameReviewedDirectory(scratch, resolved) {
                return "\(MCPDisplayedText.field(scratch)) resolves to \(MCPDisplayedText.field(resolved)), which was not the path reviewed"
            }
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
    /// path the review never named is refused. A path C `realpath` cannot
    /// resolve is refused too: a missing middle component must not be glued
    /// back on, `..` and all, and emitted as an allow.
    static func unreviewedTemporary(_ path: String) -> String? {
        guard let existing = resolveExisting(path) else {
            return "\(MCPDisplayedText.field(path)) resolves to \(MCPDisplayedText.field(path)), which was not the path reviewed"
        }
        let resolved = tmpAlias(existing)
        let roots = ["/private/tmp", "/private/var/folders"]
        if roots.contains(where: { resolved == $0 || resolved.hasPrefix($0 + "/") }) {
            return nil
        }
        return "\(MCPDisplayedText.field(path)) resolves to \(MCPDisplayedText.field(existing)), which was not the path reviewed"
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
        return tmpAlias(directorySpelling(reviewed)) == tmpAlias(directorySpelling(resolved))
    }

    /// Directory spellings compared without a trailing slash:
    /// `NSTemporaryDirectory()` keeps one and `realpath` drops it.
    private static func directorySpelling(_ path: String) -> String {
        var spelling = path
        while spelling.count > 1, spelling.hasSuffix("/") { spelling.removeLast() }
        return spelling
    }

    static func tmpAlias(_ path: String) -> String {
        if path == "/tmp" { return "/private/tmp" }
        if path.hasPrefix("/tmp/") { return "/private/tmp/" + path.dropFirst("/tmp/".count) }
        // /var is the same firmlink: Foundation spells the per-user temp
        // root /var/folders/... on some systems and /private/var/folders/...
        // on others, and realpath always lands on the latter.
        if path == "/var" { return "/private/var" }
        if path.hasPrefix("/var/") { return "/private/var/" + path.dropFirst("/var/".count) }
        return path
    }

    /// Allow filters add a resolved spelling only when it is the same
    /// directory. Deny filters also add a different real path, so a symlink
    /// at `~/.ssh` or the config directory does not leave the target readable.
    static func paths(_ raw: [String], denyTargets: Bool) -> String {
        // Scalar identity, not String equality. Swift treats NFC and NFD as
        // the same string, and a catalog name in the other form would be dropped.
        var seen = Set<[UInt32]>()
        func fresh(_ text: String) -> Bool {
            seen.insert(text.unicodeScalars.map(\.value)).inserted
        }
        var filters: [String] = []
        for path in raw {
            let resolved = denyTargets ? deniedRealPath(path) : realPath(path)
            var spellings = (denyTargets || sameReviewedDirectory(path, resolved)) ? [path, resolved] : [path]
            if denyTargets {
                var expanded: [String] = []
                var roots = spellings + seatbeltSpellings(resolved)
                for opening in missingSymlinkOpenings(path) {
                    roots.append(opening)
                    roots.append(contentsOf: seatbeltSpellings(opening))
                }
                for spelling in roots {
                    for form in unicodeForms(spelling) {
                        expanded.append(contentsOf: seatbeltSpellings(form))
                    }
                }
                spellings = expanded
            }
            for spelling in spellings where fresh(spelling) {
                filters.append("(subpath \(seatbeltString(escape(spelling), raw: false)))")
                if denyTargets {
                    let pattern = "(regex \(seatbeltString(seatbeltPathPattern(spelling), raw: true)))"
                    if fresh(pattern) { filters.append(pattern) }
                }
            }
        }
        return filters.joined(separator: " ")
    }

    static func realPath(_ path: String) -> String {
        if let resolved = resolveExisting(path) { return resolved }
        return resolvingMissingSuffix(path)
    }

    /// The path Seatbelt will check. A dangling symlink uses `readlink` so the
    /// target is denied even when that directory does not exist yet.
    static func deniedRealPath(_ path: String) -> String {
        if let resolved = resolveExisting(path) { return resolved }
        if let target = absoluteLinkTarget(path) {
            if let resolved = resolveExisting(target) { return resolved }
            return resolvingMissingSuffix(target)
        }
        return resolvingMissingSuffix(path)
    }

    static func absoluteLinkTarget(_ path: String) -> String? {
        guard let raw = readLink(path) else { return nil }
        if raw.hasPrefix("/") { return raw }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return URL(fileURLWithPath: parent).appendingPathComponent(raw).path
    }

    /// Spellings Seatbelt may check for one path: `/tmp` and `/private/tmp`,
    /// `/var` and `/private/var`, and the Data-volume firmlink of an absolute
    /// path (`/opt`, `/private`, `/Users`, and the rest).
    static func seatbeltSpellings(_ path: String) -> [String] {
        var spellings: [String] = []
        func add(_ value: String) {
            if spellings.contains(value) == false { spellings.append(value) }
        }
        add(path)
        if path == "/tmp" || path.hasPrefix("/tmp/") {
            add("/private" + path)
        } else if path == "/private/tmp" || path.hasPrefix("/private/tmp/") {
            add("/tmp" + path.dropFirst("/private/tmp".count))
        }
        if path == "/var" || path.hasPrefix("/var/") {
            add("/private" + path)
        } else if path == "/private/var" || path.hasPrefix("/private/var/") {
            add(String(path.dropFirst("/private".count)))
        }
        let firm = "/System/Volumes/Data"
        for spelling in Array(spellings) {
            if spelling == firm || spelling.hasPrefix(firm + "/") {
                add(String(spelling.dropFirst(firm.count)))
            } else if spelling.hasPrefix("/") {
                add(firm + spelling)
            }
        }
        return spellings
    }

    /// The leaf does not exist yet. Walk the path the kernel walks: follow a
    /// symlink, then let `..` mean that directory's parent. Popping `..` in
    /// the string first turns `jump/../private/tmp/...` into a home path and
    /// leaves the `/private/tmp` allow in front of the real target.
    /// A component that does not exist yet is collapsed only in the suffix,
    /// so `no-such/../future-keys` is still `future-keys`. `URL` is not used:
    /// a last component of `..` must not grow the path.
    static func resolvingMissingSuffix(_ path: String) -> String {
        guard path.hasPrefix("/") else { return lexicalAbsolute(path) }
        return resolvingWalk(path, followsLeft: 32)
    }

    private static func resolvingWalk(_ path: String, followsLeft: Int) -> String {
        var current = "/"
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < parts.count {
            let part = parts[index]
            index += 1
            if part == "." { continue }
            if part == ".." {
                current = parentDirectory(current)
                continue
            }
            let next = current == "/" ? "/" + part : current + "/" + part
            if let link = readLink(next) {
                guard followsLeft > 0 else {
                    return lexicalJoin(current, [part] + Array(parts[index...]))
                }
                let absolute = link.hasPrefix("/") ? link : (current == "/" ? "/" + link : current + "/" + link)
                let rest = parts[index...].joined(separator: "/")
                let continued = rest.isEmpty ? absolute : absolute + "/" + rest
                return resolvingWalk(continued, followsLeft: followsLeft - 1)
            }
            if isRealDirectory(next) {
                current = next
                continue
            }
            return lexicalJoin(current, [part] + Array(parts[index...]))
        }
        return current
    }

    /// Paths `open` can read after the profile is built. A missing component
    /// under a write allow can be created as a symlink. `part` → `/part`
    /// makes `jump/../private/tmp/future-keys` and `jump/foo/../../...` read
    /// `/private/tmp/future-keys`, which the lexical doubled path does not
    /// name. The doubled path stays denied too: without that symlink, `open`
    /// still names it.
    static func missingSymlinkOpenings(_ path: String) -> [String] {
        guard path.hasPrefix("/") else { return [] }
        return symlinkOpenings(path, followsLeft: 32)
    }

    private static func symlinkOpenings(_ path: String, followsLeft: Int, afterSymlink: Bool = false) -> [String] {
        var current = "/"
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < parts.count {
            let part = parts[index]
            index += 1
            if part == "." { continue }
            if part == ".." {
                current = parentDirectory(current)
                continue
            }
            let next = current == "/" ? "/" + part : current + "/" + part
            if let link = readLink(next) {
                guard followsLeft > 0 else { return [] }
                var absolute = link.hasPrefix("/") ? link : (current == "/" ? "/" + link : current + "/" + link)
                var rest = Array(parts[index...])
                while let first = rest.first, first == "." || first == ".." {
                    rest.removeFirst()
                    if first == ".." { absolute = parentDirectory(absolute) }
                }
                if let name = rest.first {
                    let child = absolute == "/" ? "/" + name : absolute + "/" + name
                    if readLink(child) == nil, isRealDirectory(child) == false {
                        return openingsFromMissing(parent: absolute, parts: rest, origin: path)
                    }
                }
                let continuedRest = rest.joined(separator: "/")
                let continued = continuedRest.isEmpty ? absolute : absolute + "/" + continuedRest
                return symlinkOpenings(continued, followsLeft: followsLeft - 1, afterSymlink: true)
            }
            if isRealDirectory(next) {
                current = next
                continue
            }
            // A directory that already exists is not the opening. A later
            // missing name under it can still be created as a symlink, and
            // that link can point at an ancestor, not only at `/<name>`.
            guard afterSymlink else { return [] }
            return openingsFromMissing(parent: current, parts: [part] + Array(parts[index...]), origin: path)
        }
        return []
    }

    /// The first missing name can be created as a directory, and a later
    /// name is then the symlink. Each missing name is an opening.
    /// When `/<name>` and the ancestors already collapse to one path
    /// (`../private/tmp/future-keys`), that path is the whole set.
    /// `link/../../../future-keys` collapses to `/future-keys`, and
    /// `link/../../../foo/future-keys` collapses to `/foo/future-keys`.
    /// Neither is the file `open` reads after a deep relative symlink.
    private static func openingsFromMissing(parent: String, parts: [String], origin: String) -> [String] {
        guard let name = parts.first else { return [] }
        let tail = Array(parts.dropFirst())
        let primary = syntheticOpenings(parent: parent, name: name, tail: tail, origin: origin, includeCreationDirectory: false)
        if tail.isEmpty || collapsedOpeningCoversTheParent(primary, parent: parent, tail: tail) {
            return openingsIncludingKeySibling(primary, parent: parent)
        }
        var results = syntheticOpenings(parent: parent, name: name, tail: tail, origin: origin, includeCreationDirectory: true)
        if let dot = finalNameDotOpening(primary, parent: parent) {
            if results.contains(dot) == false { results.append(dot) }
            // `ln -s ../future-keys` from inside `dot` (`anchor/x`).
            for sibling in keyDirectories(under: parentDirectory(dot)) where results.contains(sibling) == false {
                results.append(sibling)
            }
        }
        let nextParent = parent == "/" ? "/" + name : parent + "/" + name
        for opening in openingsFromMissing(parent: nextParent, parts: tail, origin: origin)
            where results.contains(opening) == false {
            results.append(opening)
        }
        return results
    }

    /// One collapsed opening is the whole set when it is the creation
    /// directory or one missing component directly under it
    /// (`../private/tmp/future-keys` → `/private/tmp/future-keys`), or when
    /// a `..` run cannot leave that directory and the collapsed path
    /// continues along it with only that one component left. A collapsed
    /// path that is not under the creation directory
    /// (`foo/../../private/tmp/future-keys` while `foo` is missing under
    /// the anchor) is that one opening too. A final name on that path
    /// (`x/../../private/tmp/future-keys/x`) can still be `ln -s .` inside
    /// the real directory, and so can a missing name in front of it
    /// (`y` in `x/../../private/tmp/y/future-keys`). A final name after a real
    /// directory (`link/../private/tmp/future-keys/x`, `anchor/future-keys`)
    /// does not: `ln -s .` or `ln -s ../future-keys` still reads the
    /// credential directory. A later missing name
    /// (`../private/tmp/x/future-keys`) does not either.
    /// A missing name that repeats an ancestor (`private` →
    /// `/private/future-keys`) does not. `../private` after `link` collapses
    /// to `/private/...` and is not that file. `/foo/future-keys` is as deep
    /// as `/private/tmp` and is a different tree: `link/../../../foo/future-keys`
    /// then `ln -s .` reads `/private/tmp/future-keys`.
    /// `foo/../../private/tmp/future-keys` stays on `/private/tmp/future-keys`
    /// and is the whole set.
    private static func collapsedOpeningCoversTheParent(
        _ primary: [String], parent: String, tail: [String]
    ) -> Bool {
        guard primary.count <= 1 else { return false }
        guard let opened = primary.first else { return true }
        if tail.contains("..") == false {
            return collapsedOpeningLiesOnTheParent(opened, parent: parent)
        }
        let parentParts = parent.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let openedParts = opened.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if openedParts.count < parentParts.count { return false }
        var dots = 0
        for part in tail {
            if part == ".." {
                dots += 1
            } else {
                break
            }
        }
        // Enough `..` to leave the creation directory. Later names can be
        // `ln -s .` and still name a file under that directory.
        if dots >= parentParts.count { return false }
        var shared = 0
        for (parentPart, openedPart) in zip(parentParts, openedParts) {
            if parentPart != openedPart { break }
            shared += 1
        }
        // Matching only the ancestor `..` landed on is the tail repeating
        // that name (`../private` collapses to `/private/...`). A longer
        // shared prefix is either the collapsed path staying on the parent
        // (`link/../private/tmp/future-keys/x`) or a path that left it
        // (`foo/../../private/tmp/future-keys` → `/private/tmp/future-keys`
        // while the missing name sits under `/private/tmp/anchor`). A final
        // name on the path that left (`x/../../private/tmp/future-keys/x`),
        // and a missing name in front of a real directory
        // (`x/../../private/tmp/y/future-keys`), are kept beside that
        // opening. A missing name with no suffix (`.../y`) can be
        // `ln -s future-keys`. Only a longer suffix that is still on the
        // parent can be `ln -s .` through the later-name walk.
        guard shared > parentParts.count - dots else { return false }
        let prefix = parent == "/" ? "/" : parent + "/"
        guard opened == parent || opened.hasPrefix(prefix) else { return true }
        return collapsedOpeningLiesOnTheParent(opened, parent: parent)
    }

    /// A single collapsed path covers the creation directory when it is that
    /// directory, or one missing component directly under it. A name after a
    /// real directory (`x` in `/private/tmp/future-keys/x`, or `future-keys`
    /// in `/private/tmp/anchor/future-keys`) can still be a symlink. A single
    /// missing name can also be `ln -s` to a sibling that already holds
    /// `id_rsa`; that sibling is added beside the lexical path.
    private static func collapsedOpeningLiesOnTheParent(_ opened: String, parent: String) -> Bool {
        if opened == parent { return true }
        let prefix = parent == "/" ? "/" : parent + "/"
        guard opened.hasPrefix(prefix) else { return false }
        let parts = opened.dropFirst(prefix.count).split(
            separator: "/", omittingEmptySubsequences: true
        )
        return parts.count <= 1
    }

    /// `ln -s future-keys` on one missing name under the creation directory
    /// (`../private/tmp/x`). The sibling is a real directory that already
    /// contains `id_rsa`. The lexical path stays the only opening when that
    /// path is already the directory (`../private/tmp/future-keys`), and when
    /// the directory is absent. A directory with no key file is not an opening.
    private static func openingsIncludingKeySibling(_ primary: [String], parent: String) -> [String] {
        guard primary.count == 1, let opened = primary.first, opened != parent else { return primary }
        let prefix = parent == "/" ? "/" : parent + "/"
        guard opened.hasPrefix(prefix) else {
            return openingsIncludingFinalDirectory(primary, opened: opened, parent: parent)
        }
        let parts = opened.dropFirst(prefix.count).split(
            separator: "/", omittingEmptySubsequences: true
        )
        guard parts.count == 1, isRealDirectory(opened) == false else { return primary }
        var results = primary
        for child in keyDirectories(under: parent) where child != opened && results.contains(child) == false {
            results.append(child)
        }
        return results
    }

    /// `ln -s .` on a final name whose collapsed path left the creation
    /// directory (`x/../../private/tmp/future-keys/x`). The real directory
    /// around that name is an opening. The same link on an earlier missing
    /// name (`y` in `x/../../private/tmp/y/future-keys`) reads the real
    /// directory named by the suffix. A missing name with nothing after it
    /// (`x/../../private/tmp/y`) can be `ln -s future-keys`. Consecutive
    /// missing names (`y/z/future-keys`) are each `ln -s .`. An ancestor of
    /// the creation directory (`/private/tmp` for
    /// `foo/../../private/tmp/future-keys`) stays off the list: that shape
    /// is already the one lexical path.
    private static func openingsIncludingFinalDirectory(
        _ primary: [String], opened: String, parent: String
    ) -> [String] {
        var results = primary
        func add(_ directory: String?) {
            guard let directory, keepsFinalDirectory(directory, parent: parent) else { return }
            if results.contains(directory) == false { results.append(directory) }
        }
        add(realDirectoryOfFinalName(opened))
        for directory in directoriesAfterMissingName(opened) {
            add(directory)
        }
        return results
    }

    /// A final-name directory is an opening unless it is the creation
    /// directory or an ancestor of it. `/private/tmp` is that ancestor for
    /// `foo/../../private/tmp/future-keys`.
    private static func keepsFinalDirectory(_ directory: String, parent: String) -> Bool {
        if directory == "/" || directory == parent { return false }
        return parent.hasPrefix(directory + "/") == false
    }

    /// Openings reached from the first missing component.
    /// `/private/tmp/y` is `ln -s future-keys` onto a sibling that already
    /// contains `id_rsa`. `/private/tmp/y/future-keys` is `ln -s .` and the
    /// suffix names that directory. `/private/tmp/y/future-keys/x` is
    /// `ln -s .` on `y` and again on `x`. `/private/tmp/y/z/future-keys` is
    /// `ln -s .` on each missing name, then the real directory.
    /// `/private/tmp/y/w` is `ln -s .` on `y` and `ln -s future-keys` on
    /// `w`, or the key link on `y` and `ln -s .` on `w`.
    /// `/private/tmp/y/anchor` is the same key link when `anchor` already
    /// exists: `ln -s .` on that name inside the key directory reads
    /// `id_rsa`. `ln -s .` on `y` alone still names the real `anchor`.
    private static func directoriesAfterMissingName(_ opened: String) -> [String] {
        let parts = opened.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count > 1 else { return [] }
        var current = "/"
        for index in parts.indices {
            let next = current == "/" ? "/" + parts[index] : current + "/" + parts[index]
            if isRealDirectory(next) {
                current = next
                continue
            }
            guard current != "/" else { return [] }
            let rest = Array(parts[(index + 1)...])
            if rest.isEmpty { return keyDirectories(under: current) }
            var found: [String] = []
            let joined = current + "/" + rest.joined(separator: "/")
            if isRealDirectory(joined) {
                found.append(joined)
            } else if let directory = realDirectoryOfFinalName(joined) {
                found.append(directory)
            }
            var skipped = 0
            while skipped < rest.count {
                let candidate = current + "/" + rest[skipped]
                if isRealDirectory(candidate) { break }
                skipped += 1
            }
            if skipped > 0, skipped < rest.count {
                let tail = current + "/" + rest[skipped...].joined(separator: "/")
                if isRealDirectory(tail) {
                    if found.contains(tail) == false { found.append(tail) }
                } else if let directory = realDirectoryOfFinalName(tail), found.contains(directory) == false {
                    found.append(directory)
                }
            }
            // A missing name can be `ln -s future-keys` even when a later
            // name is already a real directory (`anchor`). `ln -s .` on
            // that later name, inside the key directory, reads `id_rsa`.
            // `ln -s .` on the missing name alone still names the real
            // directory and does not read the key.
            for child in keyDirectories(under: current) where found.contains(child) == false {
                found.append(child)
            }
            return found
        }
        return []
    }

    /// The real directory that contains the final component, when every
    /// component before it already exists. A missing component before that
    /// name is a different opening.
    private static func realDirectoryOfFinalName(_ opened: String) -> String? {
        let parts = opened.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count > 1 else { return nil }
        var current = "/"
        for part in parts.dropLast() {
            let next = current == "/" ? "/" + part : current + "/" + part
            guard isRealDirectory(next) else { return nil }
            current = next
        }
        guard current != "/" else { return nil }
        return current
    }

    /// Real directories under `parent` that already contain `id_rsa`.
    private static func keyDirectories(under parent: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent) else { return [] }
        return names.compactMap { name in
            let child = parent == "/" ? "/" + name : parent + "/" + name
            guard isRealDirectory(child), FileManager.default.fileExists(atPath: child + "/id_rsa") else {
                return nil
            }
            return child
        }
    }

    /// `ln -s .` on a final name that already sits in a real directory.
    /// `/private/tmp/future-keys/x` reads `/private/tmp/future-keys`.
    /// A missing component before that name is a different opening.
    private static func finalNameDotOpening(_ primary: [String], parent: String) -> String? {
        guard primary.count == 1, let opened = primary.first else { return nil }
        let prefix = parent == "/" ? "/" : parent + "/"
        guard opened.hasPrefix(prefix) else { return nil }
        let parts = opened.dropFirst(prefix.count).split(
            separator: "/", omittingEmptySubsequences: true
        ).map(String.init)
        guard parts.count > 1 else { return nil }
        var current = parent
        for part in parts.dropLast() {
            let next = current == "/" ? "/" + part : current + "/" + part
            guard isRealDirectory(next) else { return nil }
            current = next
        }
        guard current != "/" else { return nil }
        return current
    }

    /// Openings for a component that does not exist yet. `name` → `/name`
    /// keeps `../private/tmp/...` and `foo/../../...` on `/private/tmp/...`.
    /// The same component can instead point at an ancestor of the directory
    /// it is created in (`x` → `/private`, `tmp` → `/private/tmp`). A final
    /// missing name can point at that directory itself.
    private static func syntheticOpenings(
        parent: String, name: String, tail: [String], origin: String, includeCreationDirectory: Bool = false
    ) -> [String] {
        var results: [String] = []
        func add(_ base: String) {
            let combined: String
            if tail.isEmpty {
                combined = base
            } else if base == "/" {
                combined = "/" + tail.joined(separator: "/")
            } else {
                combined = base + "/" + tail.joined(separator: "/")
            }
            let opened = resolvingMissingSuffix(combined)
            if opened != origin, results.contains(opened) == false {
                results.append(opened)
            }
        }
        add("/" + name)
        var ancestor = parentDirectory(parent)
        while ancestor != "/" {
            add(ancestor)
            ancestor = parentDirectory(ancestor)
        }
        // `.` is this directory even when the tail is not empty
        // (`ln -s .` then `future-keys`). A final name already includes it.
        if includeCreationDirectory || tail.isEmpty {
            add(parent)
        }
        return results
    }

    private static func parentDirectory(_ path: String) -> String {
        guard path != "/" else { return "/" }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 1 else { return "/" }
        return "/" + parts.dropLast().joined(separator: "/")
    }

    /// Collapse `.` and `..` in a suffix onto a directory the walk already
    /// reached. `URL` is not used, so a missing `..` does not grow the path.
    private static func lexicalJoin(_ base: String, _ suffix: [String]) -> String {
        let combined = (base == "/" ? "" : base) + "/" + suffix.joined(separator: "/")
        return lexicalAbsolute(combined)
    }

    /// Collapse `.` and `..` without asking `URL` to delete a component.
    /// Used for the not-yet-existing suffix. A symlink component is followed
    /// by the walk before this runs, so `..` is not popped past that link.
    static func lexicalAbsolute(_ path: String) -> String {
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if parts.isEmpty == false { parts.removeLast() }
                continue
            }
            parts.append(String(part))
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func isRealDirectory(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// NFC and NFD of one path. A catalog name in the other form misses a
    /// byte-for-byte subpath. ASCII paths are one entry.
    static func unicodeForms(_ path: String) -> [String] {
        var forms: [String] = []
        var seen = Set<[UInt32]>()
        for form in [path, path.precomposedStringWithCanonicalMapping, path.decomposedStringWithCanonicalMapping] {
            let scalars = form.unicodeScalars.map(\.value)
            if seen.insert(scalars).inserted { forms.append(form) }
        }
        return forms
    }

    static func resolveExisting(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func escape(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Bytes per string literal. `sandbox-exec` rejects any one literal
    /// longer than 1023 bytes ("Error reading string"), measured on macOS 27,
    /// and a case-folded path regex is ~7 bytes per letter.
    static let seatbeltLiteralBytes = 960

    /// `escaped` as one SBPL string: a literal when it fits, otherwise the
    /// same string built with `string-append`. Chunks end on scalar
    /// boundaries and never between a backslash and the scalar it escapes.
    static func seatbeltString(_ escaped: String, raw: Bool) -> String {
        var chunks: [String] = []
        var current = ""
        var bytes = 0
        var atom = ""
        for scalar in escaped.unicodeScalars {
            atom.unicodeScalars.append(scalar)
            // A backslash and the scalar it escapes are one atom.
            if scalar == "\\", atom.unicodeScalars.count == 1 { continue }
            let size = atom.utf8.count
            if bytes + size > seatbeltLiteralBytes, bytes > 0 {
                chunks.append(current)
                current = ""
                bytes = 0
            }
            current += atom
            bytes += size
            atom = ""
        }
        current += atom
        chunks.append(current)
        let open = raw ? "#\"" : "\""
        let literals = chunks.map { open + $0 + "\"" }
        return literals.count == 1 ? literals[0] : "(string-append " + literals.joined(separator: " ") + ")"
    }

    /// The `MCPLaunchError` for a profile `sandbox-exec` would refuse.
    static func profileFailure(server: String, reason: String) -> MCPLaunchError {
        .sandbox("could not build the sandbox profile for MCP server \(MCPDisplayedText.field(server)): \(reason)")
    }

    #if os(macOS)
    private typealias CompileProfile = @convention(c) (
        UnsafePointer<CChar>, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    ) -> UnsafeMutableRawPointer?
    private typealias FreeProfile = @convention(c) (UnsafeMutableRawPointer) -> Void

    /// Two C function pointers, set once when libsandbox is loaded and never
    /// changed; `@convention(c)` types are not Sendable only because the
    /// compiler cannot see that. Each call gets its own buffers.
    private struct ProfileCompiler: @unchecked Sendable {
        let compile: CompileProfile
        let free: FreeProfile
    }

    /// libsandbox's compiler, the one `sandbox-exec -p` runs. Nil when the
    /// symbols are missing; launch then reports what sandbox-exec prints.
    private static let profileCompiler: ProfileCompiler? = {
        guard let library = dlopen("/usr/lib/libsandbox.1.dylib", RTLD_NOW),
            let compile = dlsym(library, "sandbox_compile_string"),
            let free = dlsym(library, "sandbox_free_profile")
        else { return nil }
        return ProfileCompiler(
            compile: unsafeBitCast(compile, to: CompileProfile.self), free: unsafeBitCast(free, to: FreeProfile.self))
    }()

    /// The largest profile rv compiles. libsandbox recurses per filter: on a
    /// 16 MiB stack a 256 KB profile of distinct filters compiles in about
    /// 0.1 s, and 384 KB is refused as too large (measured, macOS 27). An
    /// everyday profile is about 24 KB.
    static let maximumProfileBytes = 256 * 1024

    /// The compile's own stack. A 128 KB profile of distinct filters
    /// overflowed a 512 KiB thread (SIGBUS in `expand_logical_conditions`),
    /// the stack `rv mcp serve` and Swift Testing run synchronous code on.
    static let profileCompileStackBytes = 16 << 20

    /// How long a compile may take before the profile is refused. Round 12
    /// measured a profile shape that compiled for over 20 minutes.
    static let profileCompileSeconds = 60

    /// Each compile's answer, by its key, until the caller takes it. A
    /// compile that outlived its caller (and so refused its server) leaves
    /// its one entry behind.
    private static let compileOutcomes = Mutex<[UUID: String?]>([:])

    /// The compiler's first error line for `profile`, or nil when it
    /// compiles. Nothing is applied or launched. It runs on a thread of its
    /// own with `profileCompileStackBytes`, never on the caller's stack, and
    /// a profile over `maximumProfileBytes` or a compile that does not
    /// return in `profileCompileSeconds` is an error.
    static func profileCompileError(_ profile: String) -> String? {
        let size = profile.utf8.count
        if size > maximumProfileBytes {
            return "the profile is \(size) bytes, more than the \(maximumProfileBytes) rv compiles"
        }
        guard let compiler = profileCompiler else { return nil }
        let key = UUID()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            let error = compile(profile, with: compiler)
            compileOutcomes.withLock { _ = $0.updateValue(error, forKey: key) }
            done.signal()
        }
        thread.stackSize = profileCompileStackBytes
        thread.start()
        guard done.wait(timeout: .now() + .seconds(profileCompileSeconds)) == .success,
            let error = compileOutcomes.withLock({ $0.removeValue(forKey: key) })
        else { return "the profile did not compile within \(profileCompileSeconds) seconds" }
        return error
    }

    private static func compile(_ profile: String, with compiler: ProfileCompiler) -> String? {
        var error: UnsafeMutablePointer<CChar>?
        if let compiled = profile.withCString({ compiler.compile($0, nil, &error) }) {
            compiler.free(compiled)
            return nil
        }
        guard let error else { return "the profile did not compile" }
        defer { Darwin.free(error) }
        let text = String(cString: error)
        let line = text.split(separator: "\n").first.map(String.init) ?? ""
        return line.isEmpty ? "the profile did not compile" : MCPDisplayedText.field(line)
    }
    #endif

    /// Each symlink in a credential chain is denied by a regex built from the
    /// path Seatbelt checks; `paths(_:denyTargets:)` denies the target the
    /// chain resolves to at launch. Nothing else is denied: not the link's
    /// parent (for `~/.ssh` that is the whole home, the scratch with it) and
    /// not every read. A link an uncaged process retargets after launch
    /// leaves its new target readable until the server restarts.
    static func symlinkDenies(_ raw: [String]) -> String {
        var seen = Set<String>()
        var filters: [String] = []
        for path in raw {
            for link in symlinkChain(path) {
                var candidates = [link]
                candidates += seatbeltSpellings(link)
                for candidate in candidates {
                    let exact = "(regex \(seatbeltString("^\(regexEscape(candidate))(/.*)?$", raw: true)))"
                    let normalized = "(regex \(seatbeltString(seatbeltPathPattern(candidate), raw: true)))"
                    for filter in [exact, normalized] where seen.insert(filter).inserted {
                        filters.append(filter)
                    }
                }
            }
        }
        return filters.isEmpty ? "" : " " + filters.joined(separator: " ")
    }

    /// Credential ancestors `profile` names one by one; more refuse the profile.
    static let maximumCredentialAncestors = 128

    /// Paths `credentialAncestors` walks up from; more refuse the profile.
    static let maximumCredentialAncestorWalks = 1024

    /// Every directory above a credential that lies inside a write root, up
    /// to the outermost one: renaming, unlinking or cloning any of them would
    /// move or copy the credential to a path its deny does not name. The
    /// walk starts at the credential's path, the target it resolves to, each
    /// link in its chain and that link's target, and the target of every
    /// symlinked directory it passes. Each directory is named twice: where it
    /// resolves, and as the link itself (its parent resolved, its own name
    /// not followed), which is the path an unlink or rename of a symlinked
    /// directory is checked against. Without repeats. Nil, never a shorter
    /// list, past `maximumCredentialAncestors` or
    /// `maximumCredentialAncestorWalks`.
    static func credentialAncestors(_ unreadable: [String], insideWriteRoots writable: [String]) -> [String]? {
        // APFS is case-insensitive by default; folding can only add a path.
        let roots = Set(writable.flatMap { [$0, realPath($0)] }.flatMap(seatbeltSpellings)
            .map { directorySpelling($0).lowercased() })
        func insideWriteRoot(_ path: String) -> Bool {
            let folded = path.lowercased()
            return roots.contains { folded == $0 || folded.hasPrefix($0 == "/" ? "/" : $0 + "/") }
        }
        var seen = Set<String>()
        var ancestors: [String] = []
        func add(_ ancestor: String) -> Bool {
            guard seen.insert(ancestor).inserted else { return true }
            ancestors.append(ancestor)
            return ancestors.count <= maximumCredentialAncestors
        }
        var pending: [String] = []
        for path in unreadable {
            pending += [path, deniedRealPath(path)]
            for link in symlinkChain(path) {
                pending.append(link)
                if let target = absoluteLinkTarget(link) { pending.append(target) }
            }
        }
        // `directory` and each one above it inside a write root. It has no
        // `.` or `..`, so each step drops one component and the walk ends at
        // `/`. (`URL` would append `..` to a `..`.) False past a cap.
        func walkUp(from directory: String) -> Bool {
            var parent = directory
            while parent != "/", insideWriteRoot(parent) {
                let above = parentDirectory(parent)
                let resolvedAbove = realPath(above)
                let name = parent.split(separator: "/").last.map(String.init) ?? ""
                let itself = resolvedAbove == "/" ? "/" + name : resolvedAbove + "/" + name
                guard add(realPath(parent)), add(itself) else { return false }
                var info = stat()
                if lstat(parent, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK, let target = absoluteLinkTarget(parent) {
                    pending.append(target)
                }
                parent = above
            }
            return true
        }
        var walked = Set<String>()
        var next = 0
        while next < pending.count {
            let start = pending[next]
            next += 1
            guard walked.insert(start).inserted else { continue }
            if walked.count > maximumCredentialAncestorWalks { return nil }
            let spelled = withoutDotComponents(start)
            guard walkUp(from: parentDirectory(spelled.path)) else { return nil }
            // A directory a `..` stepped out of decides where the rest
            // lands: replaced, it moves the credential. Named like the rest.
            for directory in spelled.steppedOutOf {
                guard walkUp(from: directory) else { return nil }
            }
        }
        return ancestors
    }

    /// `path` with its `.` and `..` taken as `open` takes them: a `..` goes
    /// to the parent of where the path so far resolves, not to the lexical
    /// parent, which a symlink would make a different directory. Also each
    /// directory a `..` stepped out of, as spelled so far (none of them
    /// holds a `.` or `..`).
    static func withoutDotComponents(_ path: String) -> (path: String, steppedOutOf: [String]) {
        var current = "/"
        var steppedOutOf: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if current != "/" { steppedOutOf.append(current) }
                current = parentDirectory(realPath(current))
                continue
            }
            current = current == "/" ? "/" + part : current + "/" + part
        }
        return (current, steppedOutOf)
    }

    /// Each ancestor exactly, as a literal in every spelling Seatbelt may
    /// check, so files can still be made and removed inside it. Seatbelt
    /// matches the canonical path, so a literal also holds against case
    /// variants, `./`, `//`, a trailing slash and a spelling through a
    /// symlinked parent (probed on macOS 27). It does not hold when the
    /// ancestor IS the link: an unlink or rename of a symlinked directory is
    /// checked at the link's own path, not where it resolves, which is why
    /// `credentialAncestors` names that path too. No case-folded regex:
    /// thirty of them on temp-directory paths kept libsandbox compiling for
    /// over 20 minutes.
    static func ancestorFilters(_ ancestors: [String]) -> String {
        var seen = Set<[UInt32]>()
        var filters: [String] = []
        for ancestor in ancestors {
            for spelling in seatbeltSpellings(ancestor) {
                for form in unicodeForms(spelling) {
                    let filter = "(literal \(seatbeltString(escape(form), raw: false)))"
                    if seen.insert(filter.unicodeScalars.map(\.value)).inserted { filters.append(filter) }
                }
            }
        }
        return filters.joined(separator: " ")
    }

    /// The path and every symlink it points through, without the final real
    /// directory. A second symlink at an intermediate path is its own deny.
    static func symlinkChain(_ path: String) -> [String] {
        var links: [String] = []
        var current = path
        var seen = Set<String>()
        while seen.insert(current).inserted, links.count < 32 {
            var info = stat()
            guard lstat(current, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK else { break }
            links.append(current)
            guard let target = readLink(current) else { break }
            if target.hasPrefix("/") {
                current = target
            } else {
                let parent = URL(fileURLWithPath: current).deletingLastPathComponent().path
                current = URL(fileURLWithPath: parent).appendingPathComponent(target).path
            }
        }
        return links
    }

    static func readLink(_ path: String) -> String? {
        let capacity = 4096
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        let count = readlink(path, buffer, capacity - 1)
        guard count > 0 else { return nil }
        buffer[count] = 0
        return String(cString: buffer)
    }

    /// `^/+(\./+)*` between components, letters as classes, so `/a/./b`,
    /// `/a//b`, and `/A/b` are the same path. `/tmp` and `/var` also match
    /// `/private/...` and the Data-volume spelling of that private path.
    /// `/opt`, `/private`, `/usr/local`, `/Volumes`, and `/Users` match the
    /// Data-volume firmlink. A quote in the path stays escaped and still
    /// fails the profile closed.
    static func seatbeltPathPattern(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.isEmpty == false else { return "^$" }
        var body = parts.map { caseFold($0) }.joined(separator: "/+(\\./+)*")
        let firm = "[Ss][Yy][Ss][Tt][Ee][Mm]/+(\\./+)*[Vv][Oo][Ll][Uu][Mm][Ee][Ss]/+(\\./+)*[Dd][Aa][Tt][Aa]/+(\\./+)*"
        let priv = "[Pp][Rr][Ii][Vv][Aa][Tt][Ee]/+(\\./+)*"
        switch parts[0].lowercased() {
        case "tmp", "var":
            body = "(\(firm))?(\(priv))?" + body
        case "private", "opt", "volumes", "users":
            body = "(\(firm))?" + body
        case "usr":
            if parts.count > 1, parts[1].lowercased() == "local" {
                body = "(\(firm))?" + body
            }
        default:
            break
        }
        return "^/+(\\./+)*" + body + "(/+.*)?$"
    }

    /// Case-fold a path component. One-scalar folds become a class (`s` is
    /// `[Ssſ]`, `σ` includes final sigma). A fold of more than one scalar
    /// (`ß`/`ẞ` → `ss`, `ﬁ` → `fi`, `ﬅ`/`ﬆ` → `st`, `ﬀ` → `ff`, `İ` → `i`
    /// plus U+0307) is an alternation, so either spelling matches. U+017F
    /// stays optional beside each scalar (`fuſture-keys`). A quote is still
    /// escaped inside the atom.
    static func caseFold(_ component: String) -> String {
        var folded: [Unicode.Scalar] = []
        for scalar in component.unicodeScalars {
            folded.append(contentsOf: fullFoldScalars(scalar))
        }
        return caseFoldPattern(folded)
    }

    /// Unicode full casefold where Swift's per-scalar upper+lower is not.
    /// `ẞ`.uppercased().lowercased() is `ß`, not `ss`.
    private static func fullFoldScalars(_ scalar: Unicode.Scalar) -> [Unicode.Scalar] {
        if let override = fullFoldOverrides[scalar.value] { return override }
        let folded = Array(String(scalar).uppercased().lowercased().unicodeScalars)
        return folded.isEmpty ? [scalar] : folded
    }

    private static let fullFoldOverrides: [UInt32: [Unicode.Scalar]] = [
        0x00DF: Array("ss".unicodeScalars),
        0x1E9E: Array("ss".unicodeScalars),
        0x0130: Array("i\u{0307}".unicodeScalars),
        0xFB00: Array("ff".unicodeScalars),
        0xFB01: Array("fi".unicodeScalars),
        0xFB02: Array("fl".unicodeScalars),
        0xFB03: Array("ffi".unicodeScalars),
        0xFB04: Array("ffl".unicodeScalars),
        0xFB05: Array("st".unicodeScalars),
        0xFB06: Array("st".unicodeScalars),
    ]

    private struct FoldTables {
        var single: [UInt32: [Unicode.Scalar]]
        var multi: [String: [Unicode.Scalar]]
    }

    /// Scalars grouped by full casefold, through U+10FFFF. A non-BMP small
    /// letter and its capital are one class (`𐐨` includes `𐐀`), not a
    /// single hard-coded pair. Uncased non-BMP scalars fold to themselves
    /// and stay out of the table. Multi-scalar folds are not members of
    /// the one-scalar class.
    private static let foldTables: FoldTables = {
        var single: [UInt32: [Unicode.Scalar]] = [:]
        var multi: [String: [Unicode.Scalar]] = [:]
        for value in 0...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            if value > 0xFFFF, scalar.properties.isCased == false { continue }
            let folded = fullFoldScalars(scalar)
            if folded.count == 1, let key = folded.first {
                single[key.value, default: []].append(scalar)
            } else {
                multi[scalarString(folded), default: []].append(scalar)
            }
        }
        return FoldTables(single: single, multi: multi)
    }()

    private static func caseFoldPattern(_ folded: [Unicode.Scalar]) -> String {
        var memo: [Int: String] = [:]
        func emit(_ index: Int) -> String {
            if let stored = memo[index] { return stored }
            guard index < folded.count else {
                memo[index] = ""
                return ""
            }
            if let run = homogeneousRun(folded, from: index),
               let compact = repeatedScalarPattern(folded[index], count: run) {
                // `st` is only two scalars, so `ﬅ`/`ﬆ` starts on the last `s`
                // of a run. The compact `ss` pattern would otherwise hand the
                // following `t` to its own atom and drop the ligature.
                let stayed = compact + emit(index + run)
                let pattern: String
                if let bridge = leavingPairPattern(folded, at: index + run - 1),
                   let shorter = repeatedScalarPattern(folded[index], count: run - 1) {
                    let crossed = shorter + bridge + emit(index + run + 1)
                    pattern = "(" + stayed + "|" + crossed + ")"
                } else {
                    pattern = stayed
                }
                memo[index] = pattern
                return pattern
            }
            let one = foldAtom(folded[index]) + "\u{017F}?"
            var spans: [(length: Int, pattern: String)] = []
            let longest = min(3, folded.count - index)
            if longest >= 2 {
                for length in 2...longest {
                    let key = scalarString(Array(folded[index..<(index + length)]))
                    guard let forms = foldTables.multi[key], forms.isEmpty == false else { continue }
                    let body = forms.map { regexEscape(String($0)) }.joined(separator: "|")
                    spans.append((length, "(\(body))\u{017F}?"))
                }
            }
            if spans.isEmpty {
                let pattern = one + emit(index + 1)
                memo[index] = pattern
                return pattern
            }
            let clean = spans.filter { span in
                (1..<span.length).allSatisfy { multiSpan(folded, at: index + $0) == nil }
            }
            if clean.count == spans.count, Set(clean.map(\.length)).count == 1, let length = clean.first?.length {
                var short = ""
                for offset in 0..<length {
                    short += foldAtom(folded[index + offset]) + "\u{017F}?"
                }
                let choices = [short] + clean.map(\.pattern)
                let pattern = "(" + choices.joined(separator: "|") + ")" + emit(index + length)
                memo[index] = pattern
                return pattern
            }
            // Overlapping folds (`ff` beside `ffi`) keep every alternation.
            // The continuation is shared through `memo`; it is not dropped
            // once the text gets long.
            var choices = [one + emit(index + 1)]
            for span in spans {
                choices.append(span.pattern + emit(index + span.length))
            }
            let pattern = "(" + choices.joined(separator: "|") + ")"
            memo[index] = pattern
            return pattern
        }
        // emit(i) only reads later indices. Filling memo from the end keeps
        // the recursion one frame deep: a 255-scalar component recursing
        // index by index overflowed a 512 KiB task stack (SIGBUS).
        for index in stride(from: folded.count, through: 0, by: -1) { _ = emit(index) }
        return emit(0)
    }

    /// A run of one scalar whose only multi-scalar fold inside the run is
    /// that scalar repeated (`ss`, `ff`). A longer fold that leaves the run
    /// (`ffi`) stays on the mixed path so both spellings are still
    /// alternations. A length-2 fold that starts on the last copy (`st`)
    /// is bridged at the call site; it is not a reason to leave this path.
    private static func homogeneousRun(_ folded: [Unicode.Scalar], from index: Int) -> Int? {
        let scalar = folded[index]
        var end = index + 1
        while end < folded.count, folded[end] == scalar { end += 1 }
        let count = end - index
        guard count >= 2 else { return nil }
        let pair = scalarString([scalar, scalar])
        guard foldTables.multi[pair]?.isEmpty == false else { return nil }
        for start in index..<end {
            guard let span = multiSpan(folded, at: start), span.length > 2 else { continue }
            if folded[start + span.length - 1] != scalar { return nil }
        }
        return count
    }

    private static func multiSpan(_ folded: [Unicode.Scalar], at index: Int) -> (length: Int, pattern: String)? {
        let longest = min(3, folded.count - index)
        guard longest >= 2 else { return nil }
        for length in stride(from: longest, through: 2, by: -1) {
            let key = scalarString(Array(folded[index..<(index + length)]))
            guard let forms = foldTables.multi[key], forms.isEmpty == false else { continue }
            let body = forms.map { regexEscape(String($0)) }.joined(separator: "|")
            return (length, "(\(body))\u{017F}?")
        }
        return nil
    }

    /// A length-2 fold that consumes the last copy of a homogeneous run and
    /// the scalar after it (`s` + `t` → `ﬅ`/`ﬆ`). The run stays compact; this
    /// alternation keeps the ligature without copying the tail into every `ß`.
    private static func leavingPairPattern(_ folded: [Unicode.Scalar], at index: Int) -> String? {
        guard index + 1 < folded.count, folded[index] != folded[index + 1] else { return nil }
        let key = scalarString([folded[index], folded[index + 1]])
        guard let forms = foldTables.multi[key], forms.isEmpty == false else { return nil }
        let body = forms.map { regexEscape(String($0)) }.joined(separator: "|")
        return "(\(body))\u{017F}?"
    }

    /// Exactly `count` folded copies of `scalar`, including a weight-2
    /// spelling (`ß`/`ẞ` for `ss`) at any alignment. Seatbelt compiles POSIX
    /// ERE, which has no lookaheads — a `(?=…)` pattern compiles yet never
    /// matches, silently dropping the deny — so every token alignment is
    /// enumerated instead. No boundary assertion is needed: each alternative
    /// consumes exactly `count` weight and the surrounding pattern expects a
    /// different scalar (or the end) next. Runs too long to enumerate return
    /// nil and the caller falls back to the per-scalar alternations.
    private static func repeatedScalarPattern(_ scalar: Unicode.Scalar, count: Int) -> String? {
        guard count >= 1, count <= 8 else { return nil }
        let pair = scalarString([scalar, scalar])
        guard let forms = foldTables.multi[pair], forms.isEmpty == false else { return nil }
        let atom = "(" + foldAtom(scalar) + "\u{017F}?)"
        let wide = "(" + forms.map { regexEscape(String($0)) }.joined(separator: "|") + ")\u{017F}?"
        func sequences(_ remaining: Int) -> [String] {
            if remaining == 0 { return [""] }
            var out = sequences(remaining - 1).map { atom + $0 }
            if remaining >= 2 { out += sequences(remaining - 2).map { wide + $0 } }
            return out
        }
        return "(" + sequences(count).joined(separator: "|") + ")"
    }

    private static func foldAtom(_ scalar: Unicode.Scalar) -> String {
        let equivalents = foldTables.single[scalar.value] ?? [scalar]
        if equivalents.count > 1 {
            return "[" + characterClassBody(equivalents) + "]"
        }
        return regexEscape(String(scalar))
    }

    private static func scalarString(_ scalars: [Unicode.Scalar]) -> String {
        var text = ""
        for scalar in scalars { text.unicodeScalars.append(scalar) }
        return text
    }

    private static func characterClassBody(_ scalars: [Unicode.Scalar]) -> String {
        var body = ""
        for scalar in scalars {
            switch scalar {
            case "\\", "]", "^", "-":
                body += "\\"
                body.unicodeScalars.append(scalar)
            default:
                body.unicodeScalars.append(scalar)
            }
        }
        return body
    }

    static func regexEscape(_ path: String) -> String {
        var escaped = ""
        for scalar in path.unicodeScalars {
            switch scalar {
            case "\\", ".", "^", "$", "*", "+", "?", "(", ")", "[", "]", "{", "}", "|", "\"":
                escaped += "\\"
                escaped.unicodeScalars.append(scalar)
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    /// Opens `path` without following a symlink. The caller creates children
    /// with `mkdirat` on this descriptor, so a later rename of the path does
    /// not redirect the leaf.
    final class HeldDirectory {
        let fd: Int32
        let device: UInt64
        let inode: UInt64

        init?(path: String) {
            let opened = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard opened >= 0 else { return nil }
            var info = stat()
            guard fstat(opened, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
                close(opened)
                return nil
            }
            fd = opened
            device = UInt64(info.st_dev)
            inode = UInt64(info.st_ino)
        }

        deinit { close(fd) }

        func stillChecked() -> Bool {
            var info = stat()
            guard fstat(fd, &info) == 0 else { return false }
            return UInt64(info.st_dev) == device && UInt64(info.st_ino) == inode
        }
    }

    /// Ancestors held before a scratch leaf is created. A later rename of one
    /// of those directories does not redirect `mkdirat`.
    struct PinnedScratch {
        var directories: [HeldDirectory]
        var missing: [String]
    }

    /// Open every existing ancestor of `path` with `O_NOFOLLOW`. A symlink in
    /// the chain is not a directory this can hold.
    static func pinExistingAncestors(_ path: String) -> PinnedScratch? {
        guard path.hasPrefix("/") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let root = HeldDirectory(path: "/") else { return nil }
        var directories = [root]
        var built = ""
        for (index, part) in parts.enumerated() {
            built += "/" + part
            var info = stat()
            if lstat(built, &info) != 0 {
                guard errno == ENOENT else { return nil }
                return PinnedScratch(directories: directories, missing: Array(parts[index...]))
            }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFLNK { return nil }
            guard kind == S_IFDIR, let held = HeldDirectory(path: built) else { return nil }
            directories.append(held)
        }
        return PinnedScratch(directories: directories, missing: [])
    }

    /// Creates `path` by holding a descriptor for every ancestor. `O_NOFOLLOW`
    /// applies to each component, so swapping `~/Library` (the parent of the
    /// checked Caches directory) cannot `mkdirat` the leaf into the project.
    static func createCheckedDirectory(_ path: String) -> Bool {
        guard let pinned = pinExistingAncestors(path) else { return false }
        return createPinned(path, pinned: pinned)
    }

    /// `mkdirat` on the held ancestors. If a component's inode is no longer
    /// the one that was pinned, the path points at another directory: do not
    /// create the leaf. `afterAncestorMatch` runs once the openat walk has
    /// matched those inodes and before the leaf is created. A rename of the
    /// path string after that match must not mkdirat onto the old inode or
    /// return true: the profile allows the path string only when this returns
    /// true.
    static func createPinned(
        _ path: String, pinned: PinnedScratch, afterAncestorMatch: (() -> Void)? = nil
    ) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let existingCount = parts.count - pinned.missing.count
        guard existingCount == pinned.directories.count - 1, let last = pinned.directories.last, last.stillChecked()
        else { return false }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let root = open("/", flags)
        guard root >= 0 else { return false }
        var opened = [root]
        defer { opened.forEach { close($0) } }
        var rootInfo = stat()
        guard fstat(root, &rootInfo) == 0,
            UInt64(rootInfo.st_dev) == pinned.directories[0].device,
            UInt64(rootInfo.st_ino) == pinned.directories[0].inode
        else { return false }
        var current = root
        if existingCount > 0 {
            for index in 0..<existingCount {
                let next = parts[index].withCString { openat(current, $0, flags) }
                guard next >= 0 else { return false }
                opened.append(next)
                var info = stat()
                guard fstat(next, &info) == 0 else { return false }
                let held = pinned.directories[index + 1]
                if UInt64(info.st_dev) != held.device || UInt64(info.st_ino) != held.inode {
                    return false
                }
                current = next
            }
        }
        var parent = stat()
        guard fstat(current, &parent) == 0,
            UInt64(parent.st_dev) == last.device,
            UInt64(parent.st_ino) == last.inode,
            last.stillChecked()
        else { return false }
        let existingPath = existingCount == 0 ? "/" : "/" + parts.prefix(existingCount).joined(separator: "/")
        let watchedBefore = watchedRootIdentities(path)
        afterAncestorMatch?()
        guard pathStillNames(existingPath, held: last) else { return false }
        guard watchedRootIdentities(path) == watchedBefore else { return false }
        guard createMissing(pinned.missing, parent: current) else { return false }
        guard pathStillNames(existingPath, held: last) else {
            removeCreated(pinned.missing, parent: current)
            return false
        }
        guard confirmLeafParent(pinned.missing, parent: current, held: last), last.stillChecked(),
            pathStillNames(existingPath, held: last)
        else {
            removeCreated(pinned.missing, parent: current)
            return false
        }
        rememberLeafIdentity(path)
        return true
    }

    /// `Library/Caches`, `~/.npm`, and `~/.cache`. The profile allows writes
    /// under all three, by path, for the server's whole life. Creation and
    /// `profile` check only that each path still names the entry it named
    /// when the scratch was created, so a root swapped for another directory
    /// or a symlink is refused. Nothing under a root is read: a directory
    /// moved under one is writable to the cage whenever the move happens,
    /// so a check during the milliseconds of creation stops nothing the same
    /// move a second later would not do. A symlink under a root reaches
    /// nothing outside it, because Seatbelt authorizes the resolved path.
    private static func watchedWritableRoots(_ scratch: String) -> [String] {
        guard let marker = scratch.range(of: "/Library/Caches/") else { return [] }
        let home = String(scratch[..<marker.lowerBound])
        return [home + "/Library/Caches", home + "/.npm", home + "/.cache"]
    }

    /// What one watched root's path names, read with `lstat`: a symlink is
    /// its own entry, never followed. Kind, device and inode only, since
    /// writes under a root change its link count and timestamps all the
    /// time. A read that fails other than with `ENOENT` carries a fresh
    /// token, so it equals no other read and the caller refuses.
    private enum RootIdentity: Equatable {
        case absent
        case entry(kind: UInt32, device: UInt64, inode: UInt64)
        case unreadable(UUID)
    }

    /// One `lstat` per root: three for any scratch under `Library/Caches`.
    private static func watchedRootIdentities(_ scratch: String) -> [RootIdentity] {
        watchedWritableRoots(scratch).map { root in
            var info = stat()
            guard lstat(root, &info) == 0 else { return errno == ENOENT ? .absent : .unreadable(UUID()) }
            return .entry(
                kind: UInt32(info.st_mode & S_IFMT), device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
        }
    }

    private struct AncestorPin: Equatable {
        var device: UInt64
        var inode: UInt64
    }

    private struct LeafIdentity: Equatable {
        var present: Bool
        var device: UInt64
        var inode: UInt64
        var parentDevice: UInt64
        var parentInode: UInt64
        /// Parent, then each directory above it. Moving `rv-mcp` together
        /// with the leaf keeps those two inodes and changes `Caches`.
        var ancestors: [AncestorPin]
        /// What `~/Library/Caches`, `~/.npm`, and `~/.cache` named when the
        /// leaf was recorded. `profile` reads them again.
        var watched: [RootIdentity]
    }

    private static let leafRecords = Mutex<[String: LeafIdentity]>([:])

    private static func leafIdentity(_ path: String) -> LeafIdentity {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return LeafIdentity(
                present: false, device: 0, inode: 0, parentDevice: 0, parentInode: 0,
                ancestors: [], watched: [])
        }
        var parentInfo = stat()
        let parent = parentDirectory(path)
        let parentOK = lstat(parent, &parentInfo) == 0
        return LeafIdentity(
            present: true, device: UInt64(info.st_dev), inode: UInt64(info.st_ino),
            parentDevice: parentOK ? UInt64(parentInfo.st_dev) : 0,
            parentInode: parentOK ? UInt64(parentInfo.st_ino) : 0,
            ancestors: ancestorPins(parent),
            watched: watchedRootIdentities(path))
    }

    private static func ancestorPins(_ path: String) -> [AncestorPin] {
        var pins: [AncestorPin] = []
        var current = path
        while true {
            var info = stat()
            if lstat(current, &info) == 0 {
                pins.append(AncestorPin(device: UInt64(info.st_dev), inode: UInt64(info.st_ino)))
            } else {
                pins.append(AncestorPin(device: 0, inode: 0))
            }
            if current == "/" { break }
            current = parentDirectory(current)
        }
        return pins
    }

    private static func rememberLeafIdentity(_ path: String) {
        let identity = leafIdentity(path)
        leafRecords.withLock { $0[path] = identity }
    }

    private static func createdLeafIdentity(_ path: String) -> LeafIdentity? {
        leafRecords.withLock { $0[path] }
    }

    /// The path string still names the directory the walk opened. Each
    /// component is opened with `O_NOFOLLOW`, so a symlink planted on an
    /// ancestor (`~/Library` → project) is not the pinned Caches inode.
    /// `lstat` of the final path would follow that ancestor. A project moved
    /// onto `~/Library/Caches` has a different inode.
    static func pathStillNames(_ path: String, held: HeldDirectory) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let root = open("/", flags)
        guard root >= 0 else { return false }
        var current = root
        var opened = [root]
        defer { opened.forEach { close($0) } }
        for part in parts {
            let next = part.withCString { openat(current, $0, flags) }
            guard next >= 0 else { return false }
            opened.append(next)
            current = next
        }
        var info = stat()
        guard fstat(current, &info) == 0 else { return false }
        return UInt64(info.st_dev) == held.device && UInt64(info.st_ino) == held.inode
    }

    /// Remove a suffix this call created on `parent` after the path string
    /// stopped naming that directory. The leaf must not stay in the directory
    /// that was renamed away.
    static func removeCreated(_ parts: [String], parent: Int32) {
        guard parts.isEmpty == false else { return }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var current = parent
        var opened: [Int32] = []
        defer { opened.forEach { close($0) } }
        for part in parts {
            let next = part.withCString { openat(current, $0, flags) }
            guard next >= 0 else { return }
            opened.append(next)
            current = next
        }
        for index in parts.indices.reversed() {
            let directory = index == 0 ? parent : opened[index - 1]
            _ = parts[index].withCString { unlinkat(directory, $0, AT_REMOVEDIR) }
        }
    }

    /// The new leaf's parent is the pinned directory, or a directory this call
    /// created from that descriptor. A longer missing suffix is walked. It is
    /// not treated as already checked. A name that existed before `mkdirat`
    /// is not the leaf.
    static func confirmLeafParent(_ missing: [String], parent: Int32, held: HeldDirectory) -> Bool {
        guard missing.isEmpty == false else { return true }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var current = parent
        var opened: [Int32] = []
        defer { opened.forEach { close($0) } }
        var info = stat()
        guard fstat(current, &info) == 0,
            UInt64(info.st_dev) == held.device,
            UInt64(info.st_ino) == held.inode
        else { return false }
        for part in missing {
            let next = part.withCString { openat(current, $0, flags) }
            guard next >= 0 else { return false }
            opened.append(next)
            var child = stat()
            guard fstat(next, &child) == 0, (child.st_mode & S_IFMT) == S_IFDIR else { return false }
            if UInt64(child.st_dev) == held.device && UInt64(child.st_ino) == held.inode {
                return false
            }
            current = next
        }
        return held.stillChecked()
    }

    /// `mkdirat` the missing suffix on a descriptor already opened with
    /// `O_NOFOLLOW`. A name that already exists was planted after the pin,
    /// including the project moved onto that component. A symlink swapped in
    /// for a missing name is not followed.
    static func createMissing(_ parts: [String], parent: Int32) -> Bool {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var current = parent
        var opened: [Int32] = []
        defer { opened.forEach { close($0) } }
        for part in parts {
            var existing = stat()
            let present = part.withCString { fstatat(current, $0, &existing, AT_SYMLINK_NOFOLLOW) }
            if present == 0 { return false }
            let created = part.withCString { mkdirat(current, $0, mode_t(0o700)) }
            if created != 0 { return false }
            let next = part.withCString { openat(current, $0, flags) }
            guard next >= 0 else { return false }
            opened.append(next)
            current = next
        }
        return true
    }

    /// `mkdirat` each component on `held`. The leaf's parent is that
    /// descriptor (or a directory created from it), and the checked inode
    /// must be unchanged when the leaf is created.
    static func createRelative(_ parts: [String], holding held: HeldDirectory) -> Bool {
        guard held.stillChecked() else { return false }
        var current = held.fd
        var opened: [Int32] = []
        defer { opened.forEach { close($0) } }
        for (index, part) in parts.enumerated() {
            let created = part.withCString { mkdirat(current, $0, mode_t(0o700)) }
            if created != 0 && errno != EEXIST { return false }
            guard held.stillChecked() else { return false }
            let next = part.withCString { openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard next >= 0 else { return false }
            if index + 1 == parts.count {
                var parent = stat()
                guard fstat(current, &parent) == 0 else {
                    close(next)
                    return false
                }
                if current == held.fd {
                    guard UInt64(parent.st_dev) == held.device, UInt64(parent.st_ino) == held.inode else {
                        close(next)
                        return false
                    }
                }
            }
            opened.append(next)
            current = next
        }
        return held.stillChecked()
    }

}
