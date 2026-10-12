#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVIsolation

/// One `ask` tool call waiting for, or holding, a human decision. Bound to
/// the exact arguments so an approval cannot be reused for a different call.
public struct MCPApprovalRequest: Sendable, Equatable {
    public enum State: String, Sendable {
        case pending
        case granted
    }

    public var id: String
    public var server: String
    public var tool: String
    public var argumentsHash: String
    public var argumentKeys: [String]
    public var requestedAt: Date
    public var state: State

    public init(
        id: String, server: String, tool: String, argumentsHash: String, argumentKeys: [String],
        requestedAt: Date, state: State
    ) {
        self.id = id
        self.server = server
        self.tool = tool
        self.argumentsHash = argumentsHash
        self.argumentKeys = argumentKeys
        self.requestedAt = requestedAt
        self.state = state
    }
}

/// What the gateway core needs from approvals; tests pass in-memory closures.
public struct MCPApprovalGate: Sendable {
    /// A granted approval for exactly this call, consumed on use. Returns its id.
    public var consumeGrant: @Sendable (_ server: String, _ tool: String, _ argumentsHash: String) -> String?
    /// Records (or reuses) a pending request. Nil when it could not be stored.
    public var request: @Sendable (_ server: String, _ tool: String, _ argumentsHash: String, _ keys: [String]) -> String?

    public init(
        consumeGrant: @escaping @Sendable (String, String, String) -> String?,
        request: @escaping @Sendable (String, String, String, [String]) -> String?
    ) {
        self.consumeGrant = consumeGrant
        self.request = request
    }

    public static func store(_ store: MCPApprovalStore) -> MCPApprovalGate {
        MCPApprovalGate(
            consumeGrant: { store.consumeGrant(server: $0, tool: $1, argumentsHash: $2) },
            request: { store.request(server: $0, tool: $1, argumentsHash: $2, argumentKeys: $3) })
    }
}

/// `~/.config/rv/mcp-approvals.json` (0600), shared by every `rv mcp serve`
/// and `rv mcp approve`; each change holds an exclusive lock on a sibling
/// lock file. Entries older than a day are dropped.
public struct MCPApprovalStore: Sendable {
    public static let fileName = "mcp-approvals.json"
    public static let lifetime: TimeInterval = 24 * 60 * 60
    public static let maximumRequests = 256

    public var configDirectory: URL
    public var clock: @Sendable () -> Date

    public init(configDirectory: URL, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.configDirectory = configDirectory
        self.clock = clock
    }

    var fileURL: URL { configDirectory.appendingPathComponent(Self.fileName) }

    public func pending() -> [MCPApprovalRequest] {
        withLockedRequests { requests in requests.filter { $0.state == .pending } } ?? []
    }

    public func request(server: String, tool: String, argumentsHash: String, argumentKeys: [String]) -> String? {
        withLockedRequests { requests in
            if let existing = requests.first(where: {
                $0.server == server && $0.tool == tool && $0.argumentsHash == argumentsHash && $0.state == .pending
            }) {
                return existing.id
            }
            let request = MCPApprovalRequest(
                id: Self.newID(), server: server, tool: tool, argumentsHash: argumentsHash,
                argumentKeys: argumentKeys, requestedAt: clock(), state: .pending)
            requests.append(request)
            if requests.count > Self.maximumRequests { requests.removeFirst(requests.count - Self.maximumRequests) }
            return request.id
        } ?? nil
    }

    public func consumeGrant(server: String, tool: String, argumentsHash: String) -> String? {
        withLockedRequests { requests in
            guard let index = requests.firstIndex(where: {
                $0.server == server && $0.tool == tool && $0.argumentsHash == argumentsHash && $0.state == .granted
            }) else { return nil }
            return requests.remove(at: index).id
        } ?? nil
    }

    /// Pending → granted. Returns the request, or nil when no pending request has this id.
    public func grant(id: String) -> MCPApprovalRequest? {
        withLockedRequests { requests in
            guard let index = requests.firstIndex(where: { $0.id == id && $0.state == .pending }) else { return nil }
            requests[index].state = .granted
            return requests[index]
        } ?? nil
    }

    /// Removes a request in any state.
    public func remove(id: String) -> MCPApprovalRequest? {
        withLockedRequests { requests in
            guard let index = requests.firstIndex(where: { $0.id == id }) else { return nil }
            return requests.remove(at: index)
        } ?? nil
    }

    static func newID() -> String {
        (0..<4).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    private func withLockedRequests<T>(_ body: (inout [MCPApprovalRequest]) -> T) -> T? {
        do {
            try FileManager.default.createDirectory(
                at: configDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return nil
        }
        let lockPath = configDirectory.appendingPathComponent(".mcp-approvals.lock").path
        let lock = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { return nil }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { return nil }
        defer { _ = flock(lock, LOCK_UN) }

        let original: [MCPApprovalRequest]
        switch OwnerOnlyFile.read(fileURL, maximumBytes: 4 * 1024 * 1024) {
        case .success(let data?): original = Self.decode(data)
        case .success(nil): original = []
        case .failure: return nil
        }
        let cutoff = clock().addingTimeInterval(-Self.lifetime)
        var requests = original.filter { $0.requestedAt > cutoff }
        let result = body(&requests)
        if requests != original {
            guard OwnerOnlyFile.write(Data(Self.encode(requests).prettyText.utf8), to: fileURL) else { return nil }
        }
        return result
    }

    static func encode(_ requests: [MCPApprovalRequest]) -> JSONValue {
        let formatter = ISO8601DateFormatter()
        return .object([
            "version": .int(1),
            "requests": .array(requests.map { request in
                .object([
                    "id": .string(request.id),
                    "server": .string(request.server),
                    "tool": .string(request.tool),
                    "argumentsHash": .string(request.argumentsHash),
                    "argumentKeys": .array(request.argumentKeys.map(JSONValue.string)),
                    "requestedAt": .string(formatter.string(from: request.requestedAt)),
                    "state": .string(request.state.rawValue),
                ])
            }),
        ])
    }

    static func decode(_ data: Data) -> [MCPApprovalRequest] {
        let formatter = ISO8601DateFormatter()
        guard let root = try? JSONValue.parse(data), let items = root["requests"]?.arrayValue else { return [] }
        return items.compactMap { item in
            guard let id = item["id"]?.stringValue, let server = item["server"]?.stringValue,
                let tool = item["tool"]?.stringValue, let hash = item["argumentsHash"]?.stringValue,
                let requested = item["requestedAt"]?.stringValue.flatMap(formatter.date(from:)),
                let state = item["state"]?.stringValue.flatMap(MCPApprovalRequest.State.init(rawValue:))
            else { return nil }
            return MCPApprovalRequest(
                id: id, server: server, tool: tool, argumentsHash: hash,
                argumentKeys: item["argumentKeys"]?.stringArray ?? [], requestedAt: requested, state: state)
        }
    }
}

extension JSONValue {
    /// Object keys sorted at every level: equal values hash equally.
    public var canonicalText: String {
        switch self {
        case .array(let items):
            return "[" + items.map(\.canonicalText).joined(separator: ",") + "]"
        case .object(let object):
            let body = object.keys.sorted().compactMap { key in
                object[key].map { JSONValue.string(key).compactText + ":" + $0.canonicalText }
            }
            return "{" + body.joined(separator: ",") + "}"
        default:
            return compactText
        }
    }

    public var canonicalHash: String {
        RVDigest.sha256Hex(Array(canonicalText.utf8))
    }
}
