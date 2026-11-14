/// The Landlock cage for local MCP servers on Linux: what a kernel's
/// Landlock can keep a server from, whether a server may run under it, and
/// the ruleset `rv-isolation-exec --confine` applies. Everything here is
/// pure: the shell (`MCPSandbox.applyLinux`) reads the host and carries the
/// plan out. `docs/security/mcp-linux-sandbox.md` maps it to the Seatbelt
/// profile rule by rule.

/// A Landlock ABI version, as the kernel reports it
/// (`landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION)`).
/// Never derived from a kernel version string.
public struct LandlockABI: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int

    /// Nil below 1: a kernel without Landlock has no ABI.
    public init?(_ rawValue: Int) {
        guard rawValue >= 1 else { return nil }
        self.rawValue = rawValue
    }

    private init(known rawValue: Int) { self.rawValue = rawValue }

    public static func < (lhs: LandlockABI, rhs: LandlockABI) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String { String(rawValue) }

    /// TCP bind and connect rules (Linux 6.7). The lowest ABI rv cages with.
    public static let tcp = LandlockABI(known: 4)
    /// `ioctl` on device files (Linux 6.10).
    public static let deviceIoctl = LandlockABI(known: 5)
    /// Abstract Unix sockets and signals scoped to the domain (Linux 6.12).
    public static let scopes = LandlockABI(known: 6)
    /// Connecting to a pathname Unix socket (`LANDLOCK_ACCESS_FS_RESOLVE_UNIX`).
    public static let pathnameUnixSockets = LandlockABI(known: 9)
    /// UDP bind and send rules.
    public static let udp = LandlockABI(known: 10)
}

/// What a Landlock cage does not keep a server from. The Seatbelt profile
/// denies each of these with `(deny network*)` or has no equivalent;
/// Landlock closes some one ABI at a time, and never closes the last two.
public enum MCPLinuxCageGap: String, CaseIterable, Sendable {
    /// `ioctl` on device files it opens.
    case deviceIoctl
    /// Abstract Unix sockets, and signals to processes outside the cage.
    case abstractSocketsAndSignals
    /// Connecting to pathname Unix sockets: a session bus, an SSH or GPG
    /// agent, a container daemon.
    case pathnameUnixSockets
    /// Sending and receiving UDP, to any address.
    case udp
    /// TCP that never passes the two calls Landlock's rules cover (`bind`
    /// and `connect` on a TCP socket): an MPTCP socket, a connection opened
    /// by `sendto` with TCP fast open, and `listen` on a socket never
    /// bound. Which of these a kernel build leaves open varies, by patch
    /// level as well as version; every one measured leaves the last open.
    case tcpOutsideTheRules
    /// Sockets that are neither TCP, UDP nor Unix: ICMP echo, SCTP and other
    /// families the kernel lets an unprivileged process open.
    case otherSockets

    /// The ABI from which the kernel closes this gap; nil for one no ABI closes.
    public var closedAt: LandlockABI? {
        switch self {
        case .deviceIoctl: .deviceIoctl
        case .abstractSocketsAndSignals: .scopes
        case .pathnameUnixSockets: .pathnameUnixSockets
        case .udp: .udp
        case .tcpOutsideTheRules, .otherSockets: nil
        }
    }

    /// Whether this is a way onto the network (or to another process's
    /// socket), which a policy that limits the network forbids.
    public var reachesTheNetwork: Bool {
        switch self {
        case .deviceIoctl: false
        case .abstractSocketsAndSignals, .pathnameUnixSockets, .udp, .tcpOutsideTheRules, .otherSockets: true
        }
    }

    public var summary: String {
        switch self {
        case .deviceIoctl: "ioctl on device files"
        case .abstractSocketsAndSignals: "abstract Unix sockets and signals to other processes"
        case .pathnameUnixSockets: "connections to Unix sockets (session bus, SSH and GPG agents, container daemons)"
        case .udp: "UDP"
        case .tcpOutsideTheRules:
            "TCP by a route the rules miss (which ones depends on the kernel build: MPTCP sockets, TCP fast "
                + "open, listening without a bind)"
        case .otherSockets: "sockets that are not TCP, UDP or Unix (ICMP echo, SCTP)"
        }
    }

    /// The gaps a kernel with Landlock `abi` leaves open, in this order.
    public static func open(at abi: LandlockABI) -> [MCPLinuxCageGap] {
        allCases.filter { gap in gap.closedAt.map { abi < $0 } ?? true }
    }
}

/// Whether this host can cage a local MCP server at all.
public enum MCPLinuxCageSupport: Equatable, Sendable {
    case confines(LandlockABI)
    case unavailable(Unavailable)

    public enum Unavailable: Equatable, Sendable {
        /// `rv-isolation-exec` is not installed beside rv.
        case helperMissing
        /// The helper could not be run, or did not report an ABI.
        case probeFailed
        /// The kernel has no Landlock, or it is disabled.
        case noLandlock
        /// Landlock without TCP rules: a kernel before Linux 6.7.
        case tooOld(LandlockABI)

        /// What is missing and what fixes it, for a refusal or `rv mcp check`.
        public var reason: String {
            switch self {
            case .helperMissing:
                "rv-isolation-exec is not installed beside rv; reinstall rv"
            case .probeFailed:
                "rv-isolation-exec could not report this kernel's Landlock ABI; reinstall rv"
            case .noLandlock:
                "this kernel has no Landlock, or it is disabled; the sandbox needs Linux 6.7 or later with "
                    + "Landlock enabled (lsm=landlock)"
            case .tooOld(let abi):
                "this kernel's Landlock is ABI \(abi), which has no network rules; the sandbox needs ABI "
                    + "\(LandlockABI.tcp) (Linux 6.7 or later)"
            }
        }
    }

    /// From what the probe found: whether the helper is there, and the ABI
    /// it reported (nil when it could not; 0 when the kernel has none).
    public static func resolve(helperInstalled: Bool, reportedABI: Int?) -> MCPLinuxCageSupport {
        guard helperInstalled else { return .unavailable(.helperMissing) }
        guard let reportedABI else { return .unavailable(.probeFailed) }
        guard let abi = LandlockABI(reportedABI) else { return .unavailable(.noLandlock) }
        return abi < .tcp ? .unavailable(.tooOld(abi)) : .confines(abi)
    }

    public var abi: LandlockABI? {
        switch self {
        case .confines(let abi): abi
        case .unavailable: nil
        }
    }
}

public enum MCPLinuxCage {
    /// What rv does with a server whose policy limits the network, given
    /// that Landlock cannot hold such a limit. Every sandboxed server's
    /// policy does (`network: false`, or `hosts`), and on every kernel a
    /// caged process still reaches the network by a route the rules do
    /// not cover (`MCPLinuxCageGap.tcpOutsideTheRules`, `.otherSockets`).
    public enum NetworkLimit: Equatable, Sendable {
        /// Do not start it: rv does not run a server under a limit it
        /// cannot hold. The host then has no MCP server sandbox.
        case refuse
        /// Start it with every rule the kernel has, and say what stays open.
        case disclose
    }

    /// The release's answer. `.refuse` until the owner decides otherwise
    /// (docs/security/mcp-linux-sandbox.md, "The network limit").
    public static let networkLimit = NetworkLimit.refuse

    /// Why a server does not start in a cage.
    public enum Refusal: Error, Equatable, Sendable {
        case unavailable(MCPLinuxCageSupport.Unavailable)
        /// Landlock cannot hold the policy's network limit. The ABI is this
        /// kernel's, when the host could say.
        case networkNotConfined(LandlockABI?)
        /// A variable the dynamic loader acts on, set for the server: it
        /// would take effect in rv's helper, before the cage.
        case loaderVariable(String)
        /// A directory that holds a protected path could not be listed.
        case unlistable(String)
        /// More entries beside the protected paths than one request carries.
        case tooManyPaths
        /// A writable path is `/`, holds a protected path, or is inside one.
        case writableConflict(writable: String, protected: String)

        public var reason: String {
            switch self {
            case .unavailable(let unavailable):
                unavailable.reason
            case .networkNotConfined(let abi?):
                "Landlock (ABI \(abi) on this kernel) cannot keep a server off the network: "
                    + MCPLinuxCageGap.open(at: abi).filter(\.reachesTheNetwork).map(\.summary).joined(separator: "; ")
                    + " stay open, and every sandbox policy limits the network"
            case .networkNotConfined(nil):
                "Landlock cannot keep a server off the network on any kernel, and every sandbox policy limits "
                    + "the network"
            case .loaderVariable(let name):
                "its environment sets \(name), which the dynamic loader would act on in rv's helper before the "
                    + "sandbox applies; set it in the server's own command instead (env \(name)=... command)"
            case .unlistable(let directory):
                "\(directory) holds a path the sandbox keeps unreadable and could not be listed"
            case .tooManyPaths:
                "too many files sit beside the paths the sandbox keeps unreadable"
            case .writableConflict(let writable, let protected):
                "sandbox.writable \(writable) would expose \(protected), which the sandbox keeps unreadable"
            }
        }
    }

    /// Whether a server whose policy limits the network may run on this
    /// host, and under which ABI.
    public static func admit(
        _ support: MCPLinuxCageSupport, network: NetworkLimit = MCPLinuxCage.networkLimit
    ) -> Result<LandlockABI, Refusal> {
        switch (support, network) {
        // No kernel or reinstall would change the answer: say only that.
        case (_, .refuse): .failure(.networkNotConfined(support.abi))
        case (.unavailable(let unavailable), .disclose): .failure(.unavailable(unavailable))
        case (.confines(let abi), .disclose): .success(abi)
        }
    }

    /// Whether serve requires a cage for every local server on this host.
    /// A host that should have one and cannot say so (the helper is gone,
    /// or its probe failed) requires it too: a local server is then
    /// refused, never run bare as on a host that has no cage to offer.
    public static func isRequired(
        _ support: MCPLinuxCageSupport, network: NetworkLimit = MCPLinuxCage.networkLimit
    ) -> Bool {
        switch (support, network) {
        case (_, .refuse): false
        case (.confines, .disclose), (.unavailable(.helperMissing), .disclose), (.unavailable(.probeFailed), .disclose): true
        case (.unavailable(.noLandlock), .disclose), (.unavailable(.tooOld), .disclose): false
        }
    }

    /// Why this host has no cage, or nil when it has one.
    public static func unavailability(
        _ support: MCPLinuxCageSupport, network: NetworkLimit = MCPLinuxCage.networkLimit
    ) -> String? {
        switch admit(support, network: network) {
        case .success: nil
        case .failure(let refusal): refusal.reason
        }
    }

    /// Variables the dynamic loader acts on before `main`: in the helper
    /// they would run the server's code with no cage.
    public static func isLoaderVariable(_ name: String) -> Bool {
        name.hasPrefix("LD_") || name == "GLIBC_TUNABLES"
    }

    // MARK: - Paths

    public enum EntryKind: Sendable {
        case directory
        case file
        /// Never granted: access through a link is checked where it leads.
        case symlink
        /// Sockets, FIFOs, devices: nothing to read.
        case other
    }

    public struct Entry: Equatable, Sendable {
        public var name: String
        public var kind: EntryKind

        public init(name: String, kind: EntryKind) {
            self.name = name
            self.kind = kind
        }
    }

    /// As many `--read` paths as one request carries, and as many bytes
    /// of them: the kernel bounds a process's arguments.
    public static let maximumReadablePaths = 16_384
    public static let maximumReadableBytes = 1 << 20

    /// Every path the server may read: all of the file system but
    /// `protected`. Landlock only grants, so "everything but these" is the
    /// entries beside each protected path at every level from `/` down: a
    /// directory that holds a protected path is not granted itself (its
    /// entries are reachable by name, but it cannot be listed), and what
    /// is created in it later is not readable. `protected` are absolute,
    /// normalized paths; `list` returns a directory's entries without `.`
    /// and `..`, or nil when it cannot be read.
    public static func readable(
        protecting protected: Set<String>, list: (String) -> [Entry]?
    ) -> Result<[String], Refusal> {
        var paths: [String] = []
        var bytes = 0
        func holdsProtected(_ path: String) -> Bool {
            let prefix = path == "/" ? "/" : path + "/"
            return protected.contains { $0.hasPrefix(prefix) }
        }
        // An entry beside a protected one and named after it (`name.lock`,
        // `.name.tmp`, `nameXXXXXX`) is what a save renames over it: a grant
        // follows the file, so that one is not granted either.
        func shadowsProtected(_ name: String, in directory: String) -> Bool {
            let prefix = directory == "/" ? "/" : directory + "/"
            return protected.contains { path in
                guard path.hasPrefix(prefix) else { return false }
                let guarded = path.dropFirst(prefix.count)
                return guarded.contains("/") == false && Self.names(name, String(guarded))
            }
        }
        func walk(_ directory: String) -> Refusal? {
            guard let entries = list(directory) else { return .unlistable(directory) }
            for entry in entries.sorted(by: { $0.name < $1.name }) {
                let path = directory == "/" ? "/" + entry.name : directory + "/" + entry.name
                if protected.contains(path) || shadowsProtected(entry.name, in: directory) { continue }
                switch entry.kind {
                case .symlink, .other:
                    continue
                case .file:
                    paths.append(path)
                    bytes += path.utf8.count
                case .directory:
                    if holdsProtected(path) {
                        if let refusal = walk(path) { return refusal }
                    } else {
                        paths.append(path)
                        bytes += path.utf8.count
                    }
                }
                guard paths.count <= maximumReadablePaths, bytes <= maximumReadableBytes else { return .tooManyPaths }
            }
            return nil
        }
        // Nothing protected: there is no reason to cage reads, and no caller asks.
        guard protected.contains("/") == false else { return .failure(.unlistable("/")) }
        if let refusal = walk("/") { return .failure(refusal) }
        return .success(paths)
    }

    /// Whether `name` is named after `guarded`. A distinctive name (five
    /// characters or more, or one with a character that is not a letter or
    /// digit) is carried anywhere in it: `.git-credentials.lock`,
    /// `.netrcAbCdEf` (a `mkstemp` name), `my.netrc`. A short plain one
    /// must stand as a whole word, so `ghostty` is not named after `gh`.
    static func names(_ name: String, _ guarded: String) -> Bool {
        guard guarded.isEmpty == false, name != guarded else { return false }
        let text = Array(name.unicodeScalars)
        let word = Array(guarded.unicodeScalars)
        guard text.count > word.count else { return false }
        func isWord(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.isAlphabetic || scalar.properties.numericType != nil }
        let distinctive = word.count >= 5 || word.contains { isWord($0) == false }
        for start in 0...(text.count - word.count) where Array(text[start..<(start + word.count)]) == word {
            if distinctive { return true }
            let before = start == 0 || isWord(text[start - 1]) == false
            let end = start + word.count
            let after = end == text.count || isWord(text[end]) == false
            if before, after { return true }
        }
        return false
    }

    /// A writable path that would undo a protected one: Landlock grants
    /// beneath a directory with no way to carve a hole, so a write root may
    /// not be `/`, hold a protected path, be one, or sit inside one.
    public static func writableConflict(_ writable: [String], protected: Set<String>) -> Refusal? {
        for path in writable {
            if path == "/" { return .writableConflict(writable: path, protected: "/") }
            for guarded in protected.sorted()
            where guarded == path || guarded.hasPrefix(path + "/") || path.hasPrefix(guarded + "/") {
                return .writableConflict(writable: path, protected: guarded)
            }
        }
        return nil
    }

    // MARK: - The request

    /// One server's cage, as `rv-isolation-exec --confine` takes it.
    public struct Plan: Equatable, Sendable {
        public var readable: [String]
        /// The server's own directories: every file right beneath them.
        public var writable: [String]
        /// Directories it shares with other programs (`/tmp`, `/dev`, the
        /// user's caches): as `writable`, but a socket another program
        /// made there is not the server's to reach.
        public var shared: [String]
        /// TCP ports the server may connect to: the allowlist proxy's, or none.
        public var tcpPorts: [UInt16]

        public init(readable: [String], writable: [String], shared: [String], tcpPorts: [UInt16]) {
            self.readable = readable
            self.writable = writable
            self.shared = shared
            self.tcpPorts = tcpPorts
        }

        /// The helper's arguments: the lowest ABI it may run under, the
        /// cage, then the server's executable and its whole argv
        /// (`argv[0]` included).
        public func arguments(executable: String, argv: [String]) -> [String] {
            ["--confine", String(LandlockABI.tcp.rawValue)]
                + readable.flatMap { ["--read", $0] }
                + writable.flatMap { ["--write", $0] }
                + shared.flatMap { ["--temp", $0] }
                + tcpPorts.flatMap { ["--tcp", String($0)] }
                + ["--", executable] + argv
        }
    }

    /// The line rv writes when it starts a caged server: what the cage
    /// holds, and what this kernel leaves open.
    public static func notice(server: String, abi: LandlockABI) -> String {
        "rv mcp: \(server) runs in a Landlock sandbox (ABI \(abi)): its files are confined, and TCP `connect` "
            + "and `bind` are denied; this kernel does not block "
            + MCPLinuxCageGap.open(at: abi).map(\.summary).joined(separator: "; ")
    }
}
