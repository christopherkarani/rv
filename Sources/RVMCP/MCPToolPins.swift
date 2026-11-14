#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVIsolation

/// Where a listed tool stands against the definition the owner trusted.
public enum MCPToolPinStatus: String, Sendable, Equatable {
    /// Listed this session only exactly as pinned.
    case pinned
    /// No pin: the owner has not reviewed this tool with `rv mcp trust`.
    case new
    /// Pinned under this name, but listed this session with a different
    /// definition at least once.
    case changed
    /// No verified pin to compare with: the pin store is unreadable or
    /// unverifiable, or the tool was not listed this session.
    case unverified
}

/// What became of definitions offered to the review queue.
public enum MCPToolReviewOutcome: Sendable, Equatable {
    case recorded
    /// The queue, or this server's share of it, is full; these tools'
    /// definitions were not kept.
    case dropped([String])
    case failed
}

/// What `MCPGatewayCore` needs from the pin store. Pins are read and
/// verified once, when `rv mcp serve` starts. The gateway never pins: only
/// `rv mcp trust`, with the owner present, writes pins.
public struct MCPToolPinning: Sendable {
    /// server → tool → definition hash. Nil when the store could not be
    /// read or verified: every tool is then unverified.
    public var pins: [String: [String: String]]?
    /// Keeps definitions that are not pinned for `rv mcp trust` to show.
    public var recordChanged: @Sendable (_ server: String, _ definitions: [String: JSONValue]) -> MCPToolReviewOutcome
    /// False only in tests that are not about pins.
    var enforced = true

    public init(
        pins: [String: [String: String]]?,
        recordChanged: @escaping @Sendable (String, [String: JSONValue]) -> MCPToolReviewOutcome
    ) {
        self.pins = pins
        self.recordChanged = recordChanged
    }

    /// Every tool counts as pinned. Internal: production code cannot pick it.
    static let unenforced: MCPToolPinning = {
        var pinning = MCPToolPinning(pins: [:], recordChanged: { _, _ in .recorded })
        pinning.enforced = false
        return pinning
    }()
}

/// `~/.config/rv/mcp-tool-pins.json` (0600): the upstream tool definitions
/// the owner reviewed and trusted with `rv mcp trust`, each pinned as the
/// hash of the whole tool object the upstream listed (after secret
/// scrubbing). Everything rv forwards about a tool is derived from that
/// object, so a pinned tool is served exactly as reviewed.
///
/// `pins` is MAC'd with the approvals key, the same key and purpose that
/// sign mcp.json (`MCPIntegrity`), with a `tool-pins` field first so the
/// two MACs can never stand for each other. A same-user process can edit or
/// delete the file; it cannot make edited pins verify, and deleting it can
/// only make tools ask. It can restore an older signed file, which restores
/// what the owner trusted then (a known limit until the approvals custodian
/// keeps a counter). A missing file pins
/// nothing; a present file whose pins do not verify pins nothing either, and
/// so does a platform whose approvals key a same-user process can read
/// (Linux).
///
/// `mcp-tool-review.json` (0600) is the unsigned review queue: definitions
/// the gateway saw that match no pin, kept so `rv mcp trust` can show the
/// owner what they would pin. It has a hard size budget, and each server a
/// share of it, so one noisy server cannot keep another's tools out; a full
/// queue or share keeps what it has and drops new entries. Editing it can
/// only change what is shown, and what is shown is exactly what gets pinned.
public struct MCPToolPinStore: Sendable {
    public static let fileName = "mcp-tool-pins.json"
    public static let reviewFileName = "mcp-tool-review.json"
    static let domain = "tool-pins"
    static let maximumBytes = 4 * 1024 * 1024
    /// The review queue's whole file never exceeds this.
    static let reviewBudget = 1024 * 1024
    /// Longest definition kept for review; a longer one stays unpinned.
    static let maximumDefinitionBytes = 64 * 1024
    static let maximumChanged = 512
    /// One server's share of the review queue.
    static let serverReviewBudget = 256 * 1024
    static let maximumChangedPerServer = 128

    public var configDirectory: URL
    public var signing: MCPApprovalSigning
    /// How long a writer waits for another writer before giving up. A
    /// writer that gives up writes nothing, so every tool keeps asking.
    public var lockTimeout: TimeInterval = 5

    public init(configDirectory: URL, signing: MCPApprovalSigning) {
        self.configDirectory = configDirectory
        self.signing = signing
    }

    var fileURL: URL { configDirectory.appendingPathComponent(Self.fileName, isDirectory: false) }
    var reviewURL: URL { configDirectory.appendingPathComponent(Self.reviewFileName, isDirectory: false) }

    /// What a pin covers: the whole tool object; nil without a string name.
    public static func definition(of tool: JSONValue) -> JSONValue? {
        guard tool.objectValue != nil, tool["name"]?.stringValue != nil else { return nil }
        return tool
    }

    public static func hash(_ definition: JSONValue) -> String {
        definition.canonicalHash
    }

    /// Both files for `rv mcp trust`. `pins` is nil when the pins file
    /// does not verify. The review queue is empty when it is missing,
    /// unreadable, oversized, or not valid.
    public struct Contents: Sendable, Equatable {
        public var pins: [String: [String: String]]?
        public var changed: [String: [String: JSONValue]]
    }

    public enum LoadFailure: Error, Sendable, Equatable {
        case unreadable
        case unverifiable(String)
        /// The approvals key is readable by any process running as the
        /// user (Linux), so pins MAC'd with it prove nothing.
        case unprotected

        public var reason: String {
            switch self {
            case .unreadable: "\(MCPToolPinStore.fileName) is unreadable or unsafe"
            case .unverifiable(let why): "\(MCPToolPinStore.fileName) \(why)"
            case .unprotected:
                "rv cannot protect \(MCPToolPinStore.fileName) on this platform: any process running as you can read the approvals key"
            }
        }
    }

    public enum TrustOutcome: Sendable, Equatable {
        case trusted
        /// The pins on disk are not the ones the review was built on.
        case changedDuringReview
        case failed
    }

    /// Verified pins. A missing file pins nothing.
    public func load() -> Result<[String: [String: String]], LoadFailure> {
        switch OwnerOnlyFile.read(fileURL, maximumBytes: Self.maximumBytes) {
        case .failure: return .failure(.unreadable)
        case .success(nil): return .success([:])
        case .success(let data?): return verified(data)
        }
    }

    /// Reads and verifies now, and binds the review queue to this store.
    /// Where the approvals key cannot be protected from same-user processes
    /// (the platforms where rv does not honor approval grants either),
    /// nothing is pinned.
    public func pinning() -> (pinning: MCPToolPinning, failure: LoadFailure?) {
        let loaded: Result<[String: [String: String]], LoadFailure> = signing.honorsGrants ? load() : .failure(.unprotected)
        let pins: [String: [String: String]]? = if case .success(let pins) = loaded { pins } else { nil }
        let failure: LoadFailure? = if case .failure(let failure) = loaded { failure } else { nil }
        return (MCPToolPinning(pins: pins, recordChanged: { recordChanged(server: $0, definitions: $1) }), failure)
    }

    /// Adds definitions to the review queue within its budget. A queue that
    /// is oversized or not valid starts over; an unsafe one is left alone.
    public func recordChanged(server: String, definitions: [String: JSONValue]) -> MCPToolReviewOutcome {
        withLock { () -> MCPToolReviewOutcome in
            var changed: [String: [String: JSONValue]]
            switch readReview() {
            case .unsafe: return .failed
            case .unusable: changed = [:]
            case .read(let queued): changed = queued
            }
            var count = changed.values.reduce(0) { $0 + $1.count }
            var bytes = Self.reviewBytes(changed)
            var serverCount = changed[server]?.count ?? 0
            var serverBytes = (changed[server] ?? [:]).reduce(0) { $0 + Self.entryBytes(server: server, tool: $1.key, $1.value) }
            var dropped: [String] = []
            for (tool, definition) in definitions.sorted(by: { $0.key < $1.key }) {
                let size = Self.entryBytes(server: server, tool: tool, definition)
                guard definition.canonicalText.utf8.count <= Self.maximumDefinitionBytes else {
                    dropped.append(tool)
                    continue
                }
                let previous = changed[server]?[tool].map { Self.entryBytes(server: server, tool: tool, $0) } ?? 0
                let isNew = changed[server]?[tool] == nil
                guard isNew == false || (count < Self.maximumChanged && serverCount < Self.maximumChangedPerServer),
                    bytes - previous + size <= Self.reviewBudget,
                    serverBytes - previous + size <= Self.serverReviewBudget
                else {
                    dropped.append(tool)
                    continue
                }
                if isNew {
                    count += 1
                    serverCount += 1
                }
                bytes += size - previous
                serverBytes += size - previous
                changed[server, default: [:]][tool] = definition
            }
            let body = Data(Self.encodeReview(changed).compactText.utf8)
            guard body.count <= Self.reviewBudget, OwnerOnlyFile.write(body, to: reviewURL) else { return .failed }
            return dropped.isEmpty ? .recorded : .dropped(dropped)
        } ?? .failed
    }

    /// The owner reviewed `reviewed` (server → tool → definition), shown
    /// over `expectedPins` (nil: the pins did not verify). Pins exactly the
    /// reviewed definitions and re-signs, unless the pins on disk changed
    /// since the review was built. Pins that did not verify are replaced:
    /// tools not reviewed this time stay unpinned. With `configured` (the
    /// servers in mcp.json), queued tools of any other server are dropped.
    public func trust(
        reviewed: [String: [String: JSONValue]], expectedPins: [String: [String: String]]?,
        configured: Set<String>? = nil
    ) -> TrustOutcome {
        withLock { () -> TrustOutcome in
            let current: [String: [String: String]]?
            switch OwnerOnlyFile.read(fileURL, maximumBytes: Self.maximumBytes) {
            case .failure: return .failed
            case .success(nil): current = [:]
            case .success(let data?): current = try? verified(data).get()
            }
            guard current == expectedPins else { return .changedDuringReview }
            var pins = current ?? [:]
            for (server, tools) in reviewed {
                for (tool, definition) in tools { pins[server, default: [:]][tool] = Self.hash(definition) }
            }
            guard write(pins: pins) else { return .failed }
            // Drop what was pinned from the queue; a definition the
            // gateway recorded during the review stays for next time.
            if case .read(var changed) = readReview() {
                for (server, tools) in reviewed {
                    for (tool, definition) in tools where changed[server]?[tool].map(Self.hash) == Self.hash(definition) {
                        changed[server]?[tool] = nil
                    }
                    if changed[server]?.isEmpty == true { changed[server] = nil }
                }
                if let configured { changed = changed.filter { configured.contains($0.key) } }
                _ = OwnerOnlyFile.write(Data(Self.encodeReview(changed).compactText.utf8), to: reviewURL)
            }
            return .trusted
        } ?? .failed
    }

    /// Both files for `rv mcp trust`. Fails only when the pins file is
    /// unreadable or unsafe; the review queue never blocks a review.
    public func contents() -> Result<Contents, LoadFailure> {
        let pins: [String: [String: String]]?
        switch OwnerOnlyFile.read(fileURL, maximumBytes: Self.maximumBytes) {
        case .failure: return .failure(.unreadable)
        case .success(nil): pins = [:]
        case .success(let data?): pins = try? verified(data).get()
        }
        let changed: [String: [String: JSONValue]] = if case .read(let queued) = readReview() { queued } else { [:] }
        return .success(Contents(pins: pins, changed: changed))
    }

    // MARK: File format

    static func macFields(_ pins: [String: [String: String]]) -> [String] {
        [domain, RVDigest.sha256Hex(Array(encodePins(pins).canonicalText.utf8))]
    }

    func verified(_ data: Data) -> Result<[String: [String: String]], LoadFailure> {
        guard let parsed = Self.parse(data) else { return .failure(.unverifiable("is not valid")) }
        guard let pins = parsed.pins, let mac = parsed.mac else { return .failure(.unverifiable("has no rv signature")) }
        switch signing.verify(mac, .mcpJSON, Self.macFields(pins)) {
        case .valid: return .success(pins)
        case .forged: return .failure(.unverifiable("does not match rv's signature"))
        case .noKey: return .failure(.unverifiable("cannot be checked: rv has no approvals key"))
        }
    }

    func write(pins: [String: [String: String]]) -> Bool {
        guard let mac = signing.mac(.mcpJSON, Self.macFields(pins), false) else { return false }
        let body = JSONValue.object([
            "version": .int(2),
            "pins": Self.encodePins(pins),
            "mac": .string(mac),
        ])
        return OwnerOnlyFile.write(Data(body.prettyText.utf8), to: fileURL)
    }

    struct Parsed {
        var pins: [String: [String: String]]?
        var mac: String?
    }

    /// Strict: `pins` is an object of objects of strings, or absent.
    static func parse(_ data: Data) -> Parsed? {
        guard let root = (try? JSONValue.parse(data))?.objectValue else { return nil }
        var pins: [String: [String: String]]?
        if let raw = root["pins"] {
            guard let servers = raw.objectValue else { return nil }
            var decoded: [String: [String: String]] = [:]
            for (server, tools) in servers.entries {
                guard let tools = tools.objectValue else { return nil }
                var hashes: [String: String] = [:]
                for (tool, hash) in tools.entries {
                    guard let hash = hash.stringValue else { return nil }
                    hashes[tool] = hash
                }
                decoded[server] = hashes
            }
            pins = decoded
        }
        return Parsed(pins: pins, mac: root["mac"]?.stringValue)
    }

    enum ReviewRead {
        case read([String: [String: JSONValue]])
        /// Missing, oversized, or not valid: treated as empty.
        case unusable
        /// A symlink, another owner's file, or a writable-by-others file.
        case unsafe
    }

    func readReview() -> ReviewRead {
        switch OwnerOnlyFile.read(reviewURL, maximumBytes: Self.reviewBudget) {
        case .success(nil), .failure(.oversized): return .unusable
        case .failure: return .unsafe
        case .success(let data?):
            guard let root = try? JSONValue.parse(data), let changed = root["changed"].flatMap(Self.changedEntries)
            else { return .unusable }
            return .read(changed)
        }
    }

    /// Entries whose definition is an object named like its key; anything
    /// else is dropped.
    static func changedEntries(_ value: JSONValue) -> [String: [String: JSONValue]]? {
        guard let servers = value.objectValue else { return nil }
        var changed: [String: [String: JSONValue]] = [:]
        for (server, tools) in servers.entries {
            for (tool, entry) in tools.objectValue?.entries ?? [] {
                guard let kept = definition(of: entry), kept["name"]?.stringValue == tool else { continue }
                changed[server, default: [:]][tool] = kept
            }
        }
        return changed
    }

    static func encodePins(_ pins: [String: [String: String]]) -> JSONValue {
        var servers = JSONObject()
        for server in pins.keys.sorted() {
            var tools = JSONObject()
            for (tool, hash) in (pins[server] ?? [:]).sorted(by: { $0.key < $1.key }) { tools[tool] = .string(hash) }
            servers[server] = .object(tools)
        }
        return .object(servers)
    }

    static func encodeReview(_ changed: [String: [String: JSONValue]]) -> JSONValue {
        var servers = JSONObject()
        for server in changed.keys.sorted() {
            var tools = JSONObject()
            for (tool, definition) in (changed[server] ?? [:]).sorted(by: { $0.key < $1.key }) { tools[tool] = definition }
            servers[server] = .object(tools)
        }
        return .object(["version": .int(1), "changed": .object(servers)])
    }

    /// An upper bound on what one entry adds to the compact file.
    static func entryBytes(server: String, tool: String, _ definition: JSONValue) -> Int {
        JSONValue.string(server).compactText.utf8.count + JSONValue.string(tool).compactText.utf8.count
            + definition.compactText.utf8.count + 8
    }

    static func reviewBytes(_ changed: [String: [String: JSONValue]]) -> Int {
        changed.reduce(64) { total, server in
            server.value.reduce(total) { $0 + entryBytes(server: server.key, tool: $1.key, $1.value) }
        }
    }

    /// One writer at a time across every `rv mcp serve` and `rv mcp trust`,
    /// waiting at most `lockTimeout`. Nil when the lock was not taken.
    private func withLock<T>(_ body: () -> T) -> T? {
        do {
            try FileManager.default.createDirectory(
                at: configDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return nil
        }
        let lockPath = configDirectory.appendingPathComponent(".mcp-tool-pins.lock").path
        let lock = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { return nil }
        defer { close(lock) }
        let deadline = Date().addingTimeInterval(lockTimeout)
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else { return nil }
            usleep(10_000)
        }
        defer { _ = flock(lock, LOCK_UN) }
        return body()
    }
}
