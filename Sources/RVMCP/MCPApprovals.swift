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
    /// Written by `rv mcp approve`; a grant without a valid MAC is forged.
    public var grantMAC: String?
    /// MAC of the confirmation code, bound to this call. The plaintext code is
    /// printed once on the gateway stderr, not stored in this file.
    public var codeMAC: String?

    public init(
        id: String, server: String, tool: String, argumentsHash: String, argumentKeys: [String],
        requestedAt: Date, state: State, grantMAC: String? = nil, codeMAC: String? = nil, argumentKeysMAC: String? = nil
    ) {
        self.id = id
        self.server = server
        self.tool = tool
        self.argumentsHash = argumentsHash
        self.argumentKeys = argumentKeys
        self.requestedAt = requestedAt
        self.state = state
        self.grantMAC = grantMAC
        self.codeMAC = codeMAC
        self.argumentKeysMAC = argumentKeysMAC
    }

    /// Canonical argument-key list. One JSON array, so a same-uid edit of the
    /// names is a different MAC input than the hash alone.
    static func argumentKeyField(_ keys: [String]) -> String {
        JSONValue.array(keys.map(JSONValue.string)).compactText
    }

    /// MAC of the names shown for this call, without the one-time code.
    /// `codeMAC` binds the same names plus the code.
    public var argumentKeysMAC: String?

    var grantFields: [String] {
        [id, server, tool, argumentsHash, Self.argumentKeyField(argumentKeys)]
    }
}

/// A recorded pending request. `code` is nil when no signing key exists.
public struct MCPApprovalTicket: Sendable, Equatable {
    public var id: String
    public var code: String?

    public init(id: String, code: String? = nil) {
        self.id = id
        self.code = code
    }
}

public enum MCPGrantLookup: Sendable, Equatable {
    case none
    case granted(id: String)
    /// A `granted` entry whose MAC does not verify; it has been removed.
    case forged(id: String)
}

/// What the gateway core needs from approvals; tests pass in-memory closures.
public struct MCPApprovalGate: Sendable {
    /// A granted approval for exactly this call, consumed on use.
    public var consumeGrant: @Sendable (
        _ server: String, _ tool: String, _ argumentsHash: String, _ argumentKeys: [String]
    ) -> MCPGrantLookup
    /// Records (or reuses) a pending request. Nil when it could not be stored.
    public var request: @Sendable (_ server: String, _ tool: String, _ argumentsHash: String, _ keys: [String]) -> MCPApprovalTicket?

    public init(
        consumeGrant: @escaping @Sendable (String, String, String, [String]) -> MCPGrantLookup,
        request: @escaping @Sendable (String, String, String, [String]) -> MCPApprovalTicket?
    ) {
        self.consumeGrant = consumeGrant
        self.request = request
    }

    public static func store(_ store: MCPApprovalStore) -> MCPApprovalGate {
        MCPApprovalGate(
            consumeGrant: { store.consumeGrant(server: $0, tool: $1, argumentsHash: $2, argumentKeys: $3) },
            request: { store.request(server: $0, tool: $1, argumentsHash: $2, argumentKeys: $3) })
    }
}

/// `~/.config/rv/mcp-approvals.json` (0600), shared by every `rv mcp serve`
/// and `rv mcp approve`; each change holds an exclusive lock on a sibling
/// lock file. Entries older than a day are dropped. Grants and confirmation
/// codes are MAC'd with the approvals key, so editing this file cannot
/// approve anything.
public struct MCPApprovalStore: Sendable {
    public static let fileName = "mcp-approvals.json"
    public static let lifetime: TimeInterval = 24 * 60 * 60
    public static let maximumRequests = 256

    public var configDirectory: URL
    public var signing: MCPApprovalSigning
    public var clock: @Sendable () -> Date

    public init(configDirectory: URL, signing: MCPApprovalSigning, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.configDirectory = configDirectory
        self.signing = signing
        self.clock = clock
    }

    var fileURL: URL { configDirectory.appendingPathComponent(Self.fileName) }

    public func pending() -> [MCPApprovalRequest] {
        withLockedRequests { requests in requests.filter { $0.state == .pending } } ?? []
    }

    /// Reusing a pending request mints a fresh code: only the newest printed code works.
    public func request(server: String, tool: String, argumentsHash: String, argumentKeys: [String]) -> MCPApprovalTicket? {
        guard signing.honorsGrants else { return nil }
        return withLockedRequests { requests in
            // The code exists only if its MAC could be made (this enrolls
            // the key on first use). A ticket is still recorded without
            // one, exactly as when no key could be loaded before.
            let codeCandidate = MCPConfirmationCode.generate()
            func codeMAC(_ id: String) -> String? {
                signing.mac(
                    "code", Self.codeFields(
                        id: id, server: server, tool: tool, argumentsHash: argumentsHash, argumentKeys: argumentKeys,
                        code: codeCandidate),
                    true)
            }
            func keysMAC(_ id: String) -> String? {
                signing.mac(
                    "argument-keys", Self.boundFields(
                        id: id, server: server, tool: tool, argumentsHash: argumentsHash, argumentKeys: argumentKeys),
                    true)
            }
            func liveCode(for mac: String?) -> String? {
                mac == nil ? nil : codeCandidate
            }
            if let index = requests.firstIndex(where: {
                $0.server == server && $0.tool == tool && $0.argumentsHash == argumentsHash && $0.state == .pending
            }) {
                requests[index].argumentKeys = argumentKeys
                requests[index].argumentKeysMAC = keysMAC(requests[index].id)
                let mac = codeMAC(requests[index].id)
                requests[index].codeMAC = mac
                return MCPApprovalTicket(id: requests[index].id, code: liveCode(for: mac))
            }
            let id = Self.newID()
            let mac = codeMAC(id)
            let code = liveCode(for: mac)
            let request = MCPApprovalRequest(
                id: id, server: server, tool: tool, argumentsHash: argumentsHash,
                argumentKeys: argumentKeys, requestedAt: clock(), state: .pending,
                codeMAC: mac, argumentKeysMAC: keysMAC(id))
            requests.append(request)
            while requests.count > Self.maximumRequests {
                guard let index = requests.firstIndex(where: { $0.state == .pending && $0.id != request.id }) else {
                    requests.removeAll { $0.id == request.id }
                    return nil
                }
                requests.remove(at: index)
            }
            return MCPApprovalTicket(id: id, code: code)
        } ?? nil
    }

    public func consumeGrant(
        server: String, tool: String, argumentsHash: String, argumentKeys: [String]
    ) -> MCPGrantLookup {
        guard signing.honorsGrants else { return .none }
        return withLockedRequests { requests in
            guard let index = requests.firstIndex(where: {
                $0.server == server && $0.tool == tool && $0.argumentsHash == argumentsHash && $0.state == .granted
            }) else { return MCPGrantLookup.none }
            // The hash alone is not the call. A grant signed for other key names stays put.
            guard requests[index].argumentKeys == argumentKeys else { return MCPGrantLookup.none }
            // Verify the row as read under this lock. No key to verify
            // with (nil): leave the grant for a keyed gateway instead of
            // deleting a legitimate approval as "forged".
            switch signing.verify(requests[index].grantMAC, "grant", requests[index].grantFields) {
            case .none:
                return MCPGrantLookup.none
            case .some(false):
                return .forged(id: requests.remove(at: index).id)
            case .some(true):
                return .granted(id: requests.remove(at: index).id)
            }
        } ?? MCPGrantLookup.none
    }

    /// Whether the stored names are the names inside `argumentKeysMAC`.
    /// A missing MAC or a rewritten list is not something to show or sign.
    public func argumentKeysAreBound(_ request: MCPApprovalRequest) -> Bool {
        signing.verify(request.argumentKeysMAC, "argument-keys", request.grantFields) == true
    }

    /// Whether `typed` is the code for this pending request as it stands now.
    /// Server, tool, argument hash, and argument key names are part of the MAC, so a rewrite fails.
    public func verifyCode(id: String, typed: String) -> Bool {
        guard signing.honorsGrants else { return false }
        let request = withLockedRequests { requests in requests.first { $0.id == id && $0.state == .pending } } ?? nil
        guard let request else { return false }
        // The row is read before the verify call, so the MAC judges the
        // row as it stands now, not one swapped in during a key load.
        return signing.verify(request.codeMAC, "code", Self.codeFields(
            id: request.id, server: request.server, tool: request.tool, argumentsHash: request.argumentsHash,
            argumentKeys: request.argumentKeys, code: typed)) == true
    }

    public func hasCode(id: String) -> Bool {
        (withLockedRequests { requests in requests.first { $0.id == id }?.codeMAC } ?? nil) != nil
    }

    /// Pending → granted, signed for this exact call. Nil when no pending
    /// request has this id, the row no longer matches, or no key can be made.
    /// The check and the write happen in one locked read of the file. A row
    /// that changed after the user was shown `server`/`tool`/`argumentsHash`
    /// or the argument key names is left pending and unsigned.
    public func grant(
        id: String, server: String, tool: String, argumentsHash: String, argumentKeys: [String]
    ) -> MCPApprovalRequest? {
        guard signing.honorsGrants else { return nil }
        return withLockedRequests { requests in
            guard let index = requests.firstIndex(where: { $0.id == id && $0.state == .pending }) else { return nil }
            guard requests[index].server == server, requests[index].tool == tool,
                requests[index].argumentsHash == argumentsHash, requests[index].argumentKeys == argumentKeys
            else { return nil }
            guard signing.verify(requests[index].argumentKeysMAC, "argument-keys", requests[index].grantFields) == true,
                let grantMAC = signing.mac("grant", requests[index].grantFields, true)
            else { return nil }
            requests[index].state = .granted
            requests[index].grantMAC = grantMAC
            return requests[index]
        } ?? nil
    }

    static func boundFields(
        id: String, server: String, tool: String, argumentsHash: String, argumentKeys: [String]
    ) -> [String] {
        [id, server, tool, argumentsHash, MCPApprovalRequest.argumentKeyField(argumentKeys)]
    }

    static func codeFields(
        id: String, server: String, tool: String, argumentsHash: String, argumentKeys: [String], code: String
    ) -> [String] {
        boundFields(
            id: id, server: server, tool: tool, argumentsHash: argumentsHash, argumentKeys: argumentKeys
        ) + [MCPConfirmationCode.normalize(code)]
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
        let now = clock()
        let cutoff = now.addingTimeInterval(-Self.lifetime)
        // `requestedAt` is not MAC'd, so a future date smuggled into the file
        // must not keep a grant alive past its real lifetime.
        var requests = original.filter { $0.requestedAt > cutoff && $0.requestedAt <= now.addingTimeInterval(300) }
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
                var object = JSONObject()
                object["id"] = .string(request.id)
                object["server"] = .string(request.server)
                object["tool"] = .string(request.tool)
                object["argumentsHash"] = .string(request.argumentsHash)
                object["argumentKeys"] = .array(request.argumentKeys.map(JSONValue.string))
                object["requestedAt"] = .string(formatter.string(from: request.requestedAt))
                object["state"] = .string(request.state.rawValue)
                if let mac = request.grantMAC { object["grantMAC"] = .string(mac) }
                if let mac = request.codeMAC { object["codeMAC"] = .string(mac) }
                if let mac = request.argumentKeysMAC { object["argumentKeysMAC"] = .string(mac) }
                return .object(object)
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
                argumentKeys: item["argumentKeys"]?.stringArray ?? [], requestedAt: requested, state: state,
                grantMAC: item["grantMAC"]?.stringValue, codeMAC: item["codeMAC"]?.stringValue,
                argumentKeysMAC: item["argumentKeysMAC"]?.stringValue)
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
