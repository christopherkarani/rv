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
/// Landlock closes them one ABI at a time, and never closes the last.
public enum MCPLinuxCageGap: String, CaseIterable, Sendable {
    /// `ioctl` on device files it can open.
    case deviceIoctl
    /// Abstract Unix sockets, and signals to processes outside the cage.
    case abstractSocketsAndSignals
    /// Connecting to pathname Unix sockets: a session bus, an SSH or GPG
    /// agent, a container daemon.
    case pathnameUnixSockets
    /// Sending and receiving UDP, to any address.
    case udp
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
        case .otherSockets: nil
        }
    }

    public var summary: String {
        switch self {
        case .deviceIoctl: "ioctl on device files"
        case .abstractSocketsAndSignals: "abstract Unix sockets and signals to other processes"
        case .pathnameUnixSockets: "connections to Unix sockets (session bus, SSH and GPG agents, container daemons)"
        case .udp: "UDP"
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
    /// The lowest Landlock ABI a server whose policy restricts the network
    /// runs under. Every caged policy does: `network: false` or `hosts`.
    ///
    /// At `.tcp` (the project's decision: Landlock only, Linux 6.7) such a
    /// server cannot make or accept TCP connections, but the kernels before
    /// ABI 9 and 10 do not stop it from reaching Unix sockets or sending
    /// UDP (`MCPLinuxCageGap`); rv says so when it starts the server. Set
    /// this to `.udp` to refuse those servers instead wherever the kernel
    /// cannot block UDP.
    public static let networkFloor = LandlockABI.tcp

    /// Why a server does not start in a cage.
    public enum Refusal: Error, Equatable, Sendable {
        case unavailable(MCPLinuxCageSupport.Unavailable)
        /// The kernel cages, but not well enough for a policy that restricts the network.
        case networkNotConfined(abi: LandlockABI, floor: LandlockABI)
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
            case .networkNotConfined(let abi, let floor):
                "this kernel's Landlock is ABI \(abi), which cannot keep a server off the network ("
                    + MCPLinuxCageGap.open(at: abi).filter { $0 != .deviceIoctl }.map(\.summary).joined(separator: "; ")
                    + " stay open); the sandbox needs ABI \(floor)"
            case .unlistable(let directory):
                "\(directory) holds a path the sandbox keeps unreadable and could not be listed"
            case .tooManyPaths:
                "too many files sit beside the paths the sandbox keeps unreadable"
            case .writableConflict(let writable, let protected):
                "sandbox.writable \(writable) would expose \(protected), which the sandbox keeps unreadable"
            }
        }
    }

    /// Whether a server whose policy restricts the network may run on this
    /// host, and under which ABI.
    public static func admit(
        _ support: MCPLinuxCageSupport, networkFloor: LandlockABI = MCPLinuxCage.networkFloor
    ) -> Result<LandlockABI, Refusal> {
        switch support {
        case .unavailable(let unavailable):
            return .failure(.unavailable(unavailable))
        case .confines(let abi):
            let floor = max(networkFloor, .tcp)
            return abi < floor ? .failure(.networkNotConfined(abi: abi, floor: floor)) : .success(abi)
        }
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

    /// As many `--read` paths as one request carries.
    public static let maximumReadablePaths = 16_384

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
        func holdsProtected(_ path: String) -> Bool {
            let prefix = path == "/" ? "/" : path + "/"
            return protected.contains { $0.hasPrefix(prefix) }
        }
        func walk(_ directory: String) -> Refusal? {
            guard let entries = list(directory) else { return .unlistable(directory) }
            for entry in entries.sorted(by: { $0.name < $1.name }) {
                let path = directory == "/" ? "/" + entry.name : directory + "/" + entry.name
                if protected.contains(path) { continue }
                switch entry.kind {
                case .symlink, .other:
                    continue
                case .file:
                    paths.append(path)
                case .directory:
                    if holdsProtected(path) {
                        if let refusal = walk(path) { return refusal }
                    } else {
                        paths.append(path)
                    }
                }
                guard paths.count <= maximumReadablePaths else { return .tooManyPaths }
            }
            return nil
        }
        // Nothing protected: there is no reason to cage reads, and no caller asks.
        guard protected.contains("/") == false else { return .failure(.unlistable("/")) }
        if let refusal = walk("/") { return .failure(refusal) }
        return .success(paths)
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
        /// The helper refuses to run the server on a kernel below this.
        public var floor: LandlockABI
        public var readable: [String]
        public var writable: [String]
        /// TCP ports the server may connect to: the allowlist proxy's, or none.
        public var tcpPorts: [UInt16]

        public init(floor: LandlockABI, readable: [String], writable: [String], tcpPorts: [UInt16]) {
            self.floor = floor
            self.readable = readable
            self.writable = writable
            self.tcpPorts = tcpPorts
        }

        /// The helper's arguments: the cage, then the server's executable
        /// and its whole argv (`argv[0]` included).
        public func arguments(executable: String, argv: [String]) -> [String] {
            ["--confine", String(floor.rawValue)]
                + readable.flatMap { ["--read", $0] }
                + writable.flatMap { ["--write", $0] }
                + tcpPorts.flatMap { ["--tcp", String($0)] }
                + ["--", executable] + argv
        }
    }

    /// The line rv writes when it starts a caged server on a kernel that
    /// leaves something open, or nil when nothing is.
    public static func notice(server: String, abi: LandlockABI) -> String? {
        let gaps = MCPLinuxCageGap.open(at: abi)
        guard gaps.isEmpty == false else { return nil }
        return "rv mcp: \(server) runs in a Landlock sandbox (ABI \(abi)): its files and TCP connections are "
            + "confined; this kernel does not block " + gaps.map(\.summary).joined(separator: "; ")
    }
}
