/// The cage for local MCP servers on Linux: Landlock for files and TCP
/// ports, and a seccomp socket filter for the ways onto the network that
/// Landlock's rules do not cover. What a kernel can keep a server from,
/// whether a server may run under it, and the request
/// `rv-isolation-exec --confine` carries out. Everything here is
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
    /// From here Landlock confines Unix sockets, so the socket filter
    /// allows a server to make them.
    public static let pathnameUnixSockets = LandlockABI(known: 9)
}

/// What the cage does not keep a server from on an older kernel. The
/// network is not among them: the socket filter closes it on every
/// kernel. These two are Landlock's alone, and it gained them later.
public enum MCPLinuxCageGap: String, CaseIterable, Sendable {
    /// `ioctl` on device files it opens.
    case deviceIoctl
    /// Signals to processes outside the cage.
    case signals

    /// The ABI from which the kernel closes this gap.
    public var closedAt: LandlockABI {
        switch self {
        case .deviceIoctl: .deviceIoctl
        case .signals: .scopes
        }
    }

    public var summary: String {
        switch self {
        case .deviceIoctl: "ioctl on device files"
        case .signals: "signals to your other processes"
        }
    }

    /// The gaps a kernel with Landlock `abi` leaves open, in this order.
    public static func open(at abi: LandlockABI) -> [MCPLinuxCageGap] {
        allCases.filter { abi < $0.closedAt }
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
        /// The kernel cannot install the socket filter (no seccomp filters).
        case noSocketFilter

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
            case .noSocketFilter:
                "this kernel has no seccomp filters (CONFIG_SECCOMP_FILTER), which the sandbox needs to keep a "
                    + "server off the network"
            }
        }
    }

    /// From what the probe found: whether the helper is there, and what it
    /// printed (nil when it could not be run): the kernel's Landlock ABI
    /// (0 when it has none), then ` no-socket-filter` on a kernel without
    /// seccomp filters. Anything else is a probe that failed.
    public static func resolve(helperInstalled: Bool, report: String?) -> MCPLinuxCageSupport {
        guard helperInstalled else { return .unavailable(.helperMissing) }
        let words = report?.split(separator: " ", omittingEmptySubsequences: false).map(String.init) ?? []
        guard let first = words.first, first.isEmpty == false, first.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
            let reported = Int(first),
            words.count == 1 || words == [first, "no-socket-filter"]
        else { return .unavailable(.probeFailed) }
        guard let abi = LandlockABI(reported) else { return .unavailable(.noLandlock) }
        guard abi >= .tcp else { return .unavailable(.tooOld(abi)) }
        return words.count == 1 ? .confines(abi) : .unavailable(.noSocketFilter)
    }

    public var abi: LandlockABI? {
        switch self {
        case .confines(let abi): abi
        case .unavailable: nil
        }
    }
}

public enum MCPLinuxCage {
    /// Why a server does not start in a cage.
    public enum Refusal: Error, Equatable, Sendable {
        case unavailable(MCPLinuxCageSupport.Unavailable)
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

    /// Whether serve requires a cage for every local server on this host.
    /// A host that should have one and cannot say so (the helper is gone,
    /// or its probe failed) requires it too: a local server is then
    /// refused, never run bare as on a host that has no cage to offer.
    public static func isRequired(_ support: MCPLinuxCageSupport) -> Bool {
        switch support {
        case .confines, .unavailable(.helperMissing), .unavailable(.probeFailed): true
        case .unavailable(.noLandlock), .unavailable(.tooOld), .unavailable(.noSocketFilter): false
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
        /// The allowlist proxy's port on loopback, the one place the
        /// server may open a TCP connection to; nil for no network. The
        /// helper then stays as the server's parent and makes each of
        /// those connections for it.
        public var proxyPort: UInt16?

        public init(readable: [String], writable: [String], shared: [String], proxyPort: UInt16?) {
            self.readable = readable
            self.writable = writable
            self.shared = shared
            self.proxyPort = proxyPort
        }

        /// The helper's arguments: the lowest ABI it may run under, the
        /// cage, then the server's executable and its whole argv
        /// (`argv[0]` included).
        public func arguments(executable: String, argv: [String]) -> [String] {
            ["--confine", String(LandlockABI.tcp.rawValue)]
                + readable.flatMap { ["--read", $0] }
                + writable.flatMap { ["--write", $0] }
                + shared.flatMap { ["--temp", $0] }
                + (proxyPort.map { ["--tcp", String($0)] } ?? [])
                + ["--", executable] + argv
        }
    }

    /// The line rv writes when it starts a caged server on a kernel whose
    /// Landlock leaves something open, or nil when it leaves nothing.
    public static func notice(server: String, abi: LandlockABI) -> String? {
        let gaps = MCPLinuxCageGap.open(at: abi)
        guard gaps.isEmpty == false else { return nil }
        return "rv mcp: \(server) runs in its sandbox; this kernel's Landlock (ABI \(abi)) does not block "
            + gaps.map(\.summary).joined(separator: " or ")
    }
}
