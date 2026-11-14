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
    /// Listed this session exactly as pinned.
    case pinned
    /// The server is pinned but this tool was not part of it.
    case new
    /// Pinned under this name with a different description or schema.
    case changed
    /// No verified pin to compare with: the store is unreadable or
    /// unverifiable, the server could not be pinned, or the tool was not
    /// listed this session.
    case unverified
}

/// What `MCPGatewayCore` needs from the pin store. Pins are read and
/// verified once, when `rv mcp serve` starts; the closures write.
public struct MCPToolPinning: Sendable {
    /// server → tool → definition hash. Nil when the store could not be
    /// read or verified: every tool is then unpinned.
    public var pins: [String: [String: String]]?
    /// Pins a server listed for the first time. Returns the server's pins
    /// now in the store (another gateway may have pinned it first), or nil
    /// when nothing verified could be recorded.
    public var pinFirstSeen: @Sendable (_ server: String, _ hashes: [String: String]) -> [String: String]?
    /// Keeps definitions that are not pinned for `rv mcp trust` to review.
    public var recordChanged: @Sendable (_ server: String, _ definitions: [String: JSONValue]) -> Bool
    /// False only in tests that are not about pins.
    var enforced = true

    public init(
        pins: [String: [String: String]]?,
        pinFirstSeen: @escaping @Sendable (String, [String: String]) -> [String: String]?,
        recordChanged: @escaping @Sendable (String, [String: JSONValue]) -> Bool
    ) {
        self.pins = pins
        self.pinFirstSeen = pinFirstSeen
        self.recordChanged = recordChanged
    }

    /// Every tool counts as pinned. Internal: production code cannot pick it.
    static let unenforced: MCPToolPinning = {
        var pinning = MCPToolPinning(pins: [:], pinFirstSeen: { _, hashes in hashes }, recordChanged: { _, _ in true })
        pinning.enforced = false
        return pinning
    }()
}

/// `~/.config/rv/mcp-tool-pins.json` (0600): trust-on-first-use pins of each
/// upstream tool's name, description, and input schema.
///
/// `pins` is MAC'd with the approvals key, the same key and purpose that
/// sign mcp.json (`MCPIntegrity`), with a `tool-pins` field first so the
/// two MACs can never stand for each other. A same-user process can edit or
/// delete the file; it cannot make edited pins verify. A present file whose
/// pins do not verify pins nothing, and so does a platform whose approvals
/// key a same-user process can read (Linux). `changed` is unsigned: definitions the
/// gateway saw that do not match a pin, kept only so `rv mcp trust` can show
/// the owner what they would pin. Editing it can only change what is shown,
/// and what is shown is exactly what gets pinned.
public struct MCPToolPinStore: Sendable {
    public static let fileName = "mcp-tool-pins.json"
    static let domain = "tool-pins"
    static let maximumBytes = 4 * 1024 * 1024
    /// Longest definition kept for review; a longer one stays unpinned.
    static let maximumDefinitionBytes = 64 * 1024
    static let maximumChanged = 512

    public var configDirectory: URL
    public var signing: MCPApprovalSigning

    public init(configDirectory: URL, signing: MCPApprovalSigning) {
        self.configDirectory = configDirectory
        self.signing = signing
    }

    var fileURL: URL { configDirectory.appendingPathComponent(Self.fileName, isDirectory: false) }

    /// The name, description, and input schema a pin covers; nil without a name.
    public static func definition(of tool: JSONValue) -> JSONValue? {
        guard let name = tool["name"]?.stringValue else { return nil }
        var object = JSONObject()
        object["name"] = .string(name)
        if let description = tool["description"] { object["description"] = description }
        if let schema = tool["inputSchema"] { object["inputSchema"] = schema }
        return .object(object)
    }

    public static func hash(_ definition: JSONValue) -> String {
        definition.canonicalHash
    }

    /// The store as one parsed file. `pins` is nil when the file has none
    /// or they do not verify.
    public struct Contents: Sendable {
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

    /// Verified pins. A missing file is an empty store: nothing pinned yet.
    public func load() -> Result<[String: [String: String]], LoadFailure> {
        switch OwnerOnlyFile.read(fileURL, maximumBytes: Self.maximumBytes) {
        case .failure: return .failure(.unreadable)
        case .success(nil): return .success([:])
        case .success(let data?): return verified(data)
        }
    }

    /// Reads and verifies now, and binds the writes to this store. Where
    /// the approvals key cannot be protected from same-user processes (the
    /// platforms where rv does not honor approval grants either), nothing
    /// is pinned.
    public func pinning() -> (pinning: MCPToolPinning, failure: LoadFailure?) {
        let loaded: Result<[String: [String: String]], LoadFailure> = signing.honorsGrants ? load() : .failure(.unprotected)
        let pins: [String: [String: String]]? = if case .success(let pins) = loaded { pins } else { nil }
        let failure: LoadFailure? = if case .failure(let failure) = loaded { failure } else { nil }
        return (
            MCPToolPinning(
                pins: pins,
                pinFirstSeen: { pinFirstSeen(server: $0, hashes: $1) },
                recordChanged: { recordChanged(server: $0, definitions: $1) }),
            failure
        )
    }

    public func pinFirstSeen(server: String, hashes: [String: String]) -> [String: String]? {
        withLock { () -> [String: String]? in
            var pins: [String: [String: String]]
            var changed: [String: [String: JSONValue]] = [:]
            switch OwnerOnlyFile.read(fileURL, maximumBytes: Self.maximumBytes) {
            case .failure: return nil
            case .success(nil): pins = [:]
            case .success(let data?):
                guard case .success(let verified) = verified(data) else { return nil }
                pins = verified
                changed = Self.parse(data)?.changed ?? [:]
            }
            if let existing = pins[server] { return existing }
            pins[server] = hashes
            guard write(pins: pins, changed: changed) else { return nil }
            return hashes
        } ?? nil
    }

    public func recordChanged(server: String, definitions: [String: JSONValue]) -> Bool {
        withLock { () -> Bool in
            var root: JSONObject
            switch OwnerOnlyFile.read(fileURL, maximumBytes: Self.maximumBytes) {
            case .failure: return false
            case .success(nil): root = JSONObject()
            // An unparseable file stays unverifiable: no pins, no MAC.
            case .success(let data?): root = (try? JSONValue.parse(data))?.objectValue ?? JSONObject()
            }
            var changed = root["changed"].flatMap(Self.changedEntries) ?? [:]
            var count = changed.values.reduce(0) { $0 + $1.count }
            for (tool, definition) in definitions.sorted(by: { $0.key < $1.key }) {
                guard definition.canonicalText.utf8.count <= Self.maximumDefinitionBytes else { continue }
                if changed[server]?[tool] == nil {
                    guard count < Self.maximumChanged else { continue }
                    count += 1
                }
                changed[server, default: [:]][tool] = definition
            }
            root["version"] = .int(1)
            root["changed"] = Self.encodeChanged(changed)
            return OwnerOnlyFile.write(Data(JSONValue.object(root).prettyText.utf8), to: fileURL)
        } ?? false
    }

    /// The owner reviewed `reviewed` (server → tool → definition): pin
    /// exactly those, drop them from `changed`, and re-sign. When the pins
    /// on disk do not verify, they are replaced, and every server in
    /// `servers` starts pinned to nothing, so its other tools stay unpinned
    /// instead of being pinned on first use without review.
    public func trust(reviewed: [String: [String: JSONValue]], servers: [String]) -> Bool {
        withLock { () -> Bool in
            var pins: [String: [String: String]] = [:]
            var changed: [String: [String: JSONValue]] = [:]
            switch OwnerOnlyFile.read(fileURL, maximumBytes: Self.maximumBytes) {
            case .failure: return false
            case .success(nil): break
            case .success(let data?):
                changed = Self.parse(data)?.changed ?? [:]
                if case .success(let verified) = verified(data) {
                    pins = verified
                } else {
                    for server in servers { pins[server] = [:] }
                }
            }
            for (server, tools) in reviewed {
                for (tool, definition) in tools {
                    pins[server, default: [:]][tool] = Self.hash(definition)
                    changed[server]?[tool] = nil
                }
                if changed[server]?.isEmpty == true { changed[server] = nil }
            }
            return write(pins: pins, changed: changed)
        } ?? false
    }

    /// The whole file for `rv mcp trust`: pins when they verify, and the
    /// definitions waiting for review.
    public func contents() -> Result<Contents, LoadFailure> {
        switch OwnerOnlyFile.read(fileURL, maximumBytes: Self.maximumBytes) {
        case .failure: return .failure(.unreadable)
        case .success(nil): return .success(Contents(pins: [:], changed: [:]))
        case .success(let data?):
            let pins: [String: [String: String]]? = if case .success(let pins) = verified(data) { pins } else { nil }
            return .success(Contents(pins: pins, changed: Self.parse(data)?.changed ?? [:]))
        }
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

    func write(pins: [String: [String: String]], changed: [String: [String: JSONValue]]) -> Bool {
        guard let mac = signing.mac(.mcpJSON, Self.macFields(pins), false) else { return false }
        let body = JSONValue.object([
            "version": .int(1),
            "pins": Self.encodePins(pins),
            "mac": .string(mac),
            "changed": Self.encodeChanged(changed),
        ])
        return OwnerOnlyFile.write(Data(body.prettyText.utf8), to: fileURL)
    }

    struct Parsed {
        var pins: [String: [String: String]]?
        var mac: String?
        var changed: [String: [String: JSONValue]]
    }

    /// Strict for `pins` (an object of objects of strings, or absent);
    /// lenient for `changed`, which is only ever shown.
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
        return Parsed(
            pins: pins, mac: root["mac"]?.stringValue,
            changed: root["changed"].flatMap(changedEntries) ?? [:])
    }

    /// Entries whose definition is an object named like its key; anything
    /// else is dropped.
    static func changedEntries(_ value: JSONValue) -> [String: [String: JSONValue]]? {
        guard let servers = value.objectValue else { return nil }
        var changed: [String: [String: JSONValue]] = [:]
        for (server, tools) in servers.entries {
            for (tool, entry) in tools.objectValue?.entries ?? [] {
                guard entry.objectValue != nil, let kept = definition(of: entry), kept["name"]?.stringValue == tool
                else { continue }
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

    static func encodeChanged(_ changed: [String: [String: JSONValue]]) -> JSONValue {
        var servers = JSONObject()
        for server in changed.keys.sorted() {
            var tools = JSONObject()
            for (tool, definition) in (changed[server] ?? [:]).sorted(by: { $0.key < $1.key }) { tools[tool] = definition }
            servers[server] = .object(tools)
        }
        return .object(servers)
    }

    /// One writer at a time across every `rv mcp serve` and `rv mcp trust`.
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
        guard flock(lock, LOCK_EX) == 0 else { return nil }
        defer { _ = flock(lock, LOCK_UN) }
        return body()
    }
}
