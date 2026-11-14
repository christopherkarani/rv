import RVDomain

extension MCPMACPurpose {
    /// Whether a MAC for this purpose says the owner decided something: a
    /// grant, or that mcp.json and the tool pins are what the owner
    /// reviewed. Those need the owner present. The other two are made by
    /// `rv mcp serve`, unattended, when it records a call that asks; they
    /// authorize nothing until a grant is signed for the same fields.
    public var needsOwnerPresence: Bool {
        switch self {
        case .grant, .mcpJSON: true
        case .code, .argumentKeys: false
        }
    }
}

/// What the custodian remembers about the MACs it issued, per account:
/// the rollback protection. The counter only rises. For `mcp.json` MACs it
/// keeps the newest counter per slot (one file), so an older signed copy
/// put back does not verify. A grant verifies once.
public struct MCPCustodianLedger: Equatable, Sendable, Codable {
    public static let maximumSlots = 256
    public static let maximumGrants = 256

    public private(set) var counter: UInt64 = 0
    /// Slot digest to the counter of its newest MAC.
    public private(set) var latest: [String: UInt64] = [:]
    /// Counters of grants issued and not yet verified, oldest first.
    public private(set) var grants: [UInt64] = []

    public init() {}

    /// Which file a `mcp.json` MAC is for: the scope and every field but
    /// the last, which is the content's digest.
    static func slot(scope: String, fields: [String]) -> String {
        var message: [UInt8] = []
        for field in [scope] + fields.dropLast() {
            let bytes = Array(field.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { message += $0 }
            message += bytes
        }
        return RVDigest.sha256Hex(message)
    }

    /// The counter for a new MAC, recorded. Nil when it cannot be: the
    /// counter is spent, or the account has too many slots.
    public mutating func issue(purpose: MCPMACPurpose, scope: String, fields: [String]) -> UInt64? {
        guard counter < UInt64.max else { return nil }
        let next = counter + 1
        switch purpose {
        case .mcpJSON:
            let slot = Self.slot(scope: scope, fields: fields)
            guard latest[slot] != nil || latest.count < Self.maximumSlots else { return nil }
            latest[slot] = next
        case .grant:
            grants.append(next)
            // The oldest outstanding grant gives way: it no longer verifies.
            if grants.count > Self.maximumGrants { grants.removeFirst(grants.count - Self.maximumGrants) }
        case .code, .argumentKeys:
            break
        }
        counter = next
        return next
    }

    /// Whether a MAC that verified under the key is still good: the newest
    /// for its slot, or a grant not yet used (which this uses).
    public mutating func accept(counter: UInt64, purpose: MCPMACPurpose, scope: String, fields: [String]) -> Bool {
        guard counter >= 1, counter <= self.counter else { return false }
        switch purpose {
        case .mcpJSON:
            return latest[Self.slot(scope: scope, fields: fields)] == counter
        case .grant:
            guard let index = grants.firstIndex(of: counter) else { return false }
            grants.remove(at: index)
            return true
        case .code, .argumentKeys:
            return true
        }
    }
}

/// A connected peer, as the kernel names it (`SO_PEERCRED`).
public struct MCPCustodianPeer: Equatable, Sendable {
    public var uid: UInt32
    public var pid: Int32

    public init(uid: UInt32, pid: Int32) {
        self.uid = uid
        self.pid = pid
    }
}

/// The key daemon's decisions, with no I/O of its own: which peer may ask
/// what, when the owner must be present, and what each key operation
/// answers. The daemon gives it the keys and ledgers through `Storage`,
/// the time, and each connection's peer.
public struct MCPCustodianSocketService: Sendable {
    public struct Storage: Sendable {
        /// The account's key. `.success(nil)`: none yet.
        public var loadKey: @Sendable (_ uid: UInt32) -> Result<MCPSigner?, StorageFailure>
        /// Creates the account's key, or returns the one another request made.
        public var createKey: @Sendable (_ uid: UInt32) -> Result<MCPSigner, StorageFailure>
        /// The account's ledger. A missing one is an empty one.
        public var loadLedger: @Sendable (_ uid: UInt32) -> Result<MCPCustodianLedger, StorageFailure>
        /// Durable before it returns true.
        public var saveLedger: @Sendable (_ uid: UInt32, MCPCustodianLedger) -> Bool

        public init(
            loadKey: @escaping @Sendable (UInt32) -> Result<MCPSigner?, StorageFailure>,
            createKey: @escaping @Sendable (UInt32) -> Result<MCPSigner, StorageFailure>,
            loadLedger: @escaping @Sendable (UInt32) -> Result<MCPCustodianLedger, StorageFailure>,
            saveLedger: @escaping @Sendable (UInt32, MCPCustodianLedger) -> Bool
        ) {
            self.loadKey = loadKey
            self.createKey = createKey
            self.loadLedger = loadLedger
            self.saveLedger = saveLedger
        }
    }

    public struct StorageFailure: Error, Equatable, Sendable {
        public init() {}
    }

    struct Connection: Sendable {
        var peer: MCPCustodianPeer
        var greeted = false
        var challenge: (value: String, expires: ContinuousClock.Instant)?
        var unlocked: (until: ContinuousClock.Instant, uses: Int)?
    }

    /// The uid the presence helper runs as. Only it may attest, and it
    /// may do nothing else.
    public let presenceUID: UInt32
    let storage: Storage
    let newChallenge: @Sendable () -> String
    var connections: [UInt64: Connection] = [:]

    public init(presenceUID: UInt32 = 0, storage: Storage, newChallenge: @escaping @Sendable () -> String = Self.randomChallenge) {
        self.presenceUID = presenceUID
        self.storage = storage
        self.newChallenge = newChallenge
    }

    public static func randomChallenge() -> String {
        var generator = SystemRandomNumberGenerator()
        return MCPHex.encode((0..<MCPCustodianSocket.challengeBytes).map { _ in generator.next() })
    }

    public mutating func open(_ id: UInt64, peer: MCPCustodianPeer) {
        connections[id] = Connection(peer: peer)
    }

    public mutating func close(_ id: UInt64) {
        connections[id] = nil
    }

    /// Nil ends the connection: the peer spoke before its hello, or its
    /// hello was not this protocol.
    public mutating func handle(
        _ id: UInt64, _ request: MCPCustodianSocketRequest, now: ContinuousClock.Instant
    ) -> MCPCustodianSocketResponse? {
        guard var connection = connections[id] else { return nil }
        defer { if connections[id] != nil { connections[id] = connection } }
        if case .hello(let version) = request {
            connection.greeted = version == MCPCustodianSocket.protocolVersion
            return .hello(ok: connection.greeted, protocolVersion: MCPCustodianSocket.protocolVersion)
        }
        guard connection.greeted else { return nil }
        let isHelper = connection.peer.uid == presenceUID
        switch request {
        case .hello:
            return nil
        case .attest(let challenge, let uid):
            guard isHelper else { return .error(.unauthorized) }
            return .attested(attest(challenge: challenge, uid: uid, now: now))
        case .challenge:
            guard isHelper == false else { return .error(.unauthorized) }
            let value = newChallenge()
            connection.challenge = (value, now + MCPCustodianSocket.challengeLifetime)
            return .challenge(value)
        case .key(let scope, let request):
            guard isHelper == false else { return .error(.unauthorized) }
            guard MCPCustodianSocket.isValid(scope: scope), MCPCustodianWire.isValid(request) else {
                return .error(.badRequest)
            }
            return key(request, scope: scope, connection: &connection, now: now)
        }
    }

    /// Unlocks the one connection that holds `challenge`, if its peer is
    /// `uid` and the challenge is still waiting. A challenge is used once.
    private mutating func attest(challenge: String, uid: UInt32, now: ContinuousClock.Instant) -> Bool {
        guard MCPCustodianSocket.isValid(challenge: challenge),
            let id = connections.first(where: { $0.value.challenge?.value == challenge })?.key,
            var connection = connections[id], let pending = connection.challenge
        else { return false }
        connection.challenge = nil
        defer { connections[id] = connection }
        guard now < pending.expires, connection.peer.uid == uid else { return false }
        connection.unlocked = (now + MCPCustodianSocket.presenceWindow, MCPCustodianSocket.presenceUses)
        return true
    }

    private func key(
        _ request: MCPCustodianRequest, scope: String, connection: inout Connection, now: ContinuousClock.Instant
    ) -> MCPCustodianSocketResponse {
        let uid = connection.peer.uid
        switch request {
        case .status:
            return .key(.status(status(uid)))
        case .beginFreshAuth:
            connection.unlocked = nil
            return .key(.status(status(uid)))
        case .verify(let candidate, let purpose, let fields):
            guard case .success(let key) = storage.loadKey(uid) else { return .key(.error(.unavailable)) }
            guard let key else { return .key(.verify(nil)) }
            guard let candidate, let mac = MCPCounterMAC(candidate),
                key.verify(mac.hex, purpose.rawValue, MCPCounterMAC.fields(scope: scope, counter: mac.counter, fields))
            else { return .key(.verify(false)) }
            guard case .success(var ledger) = storage.loadLedger(uid) else { return .key(.error(.unavailable)) }
            let before = ledger
            guard ledger.accept(counter: mac.counter, purpose: purpose, scope: scope, fields: fields) else {
                return .key(.verify(false))
            }
            // A used grant is recorded as used before it is reported valid.
            if ledger != before, storage.saveLedger(uid, ledger) == false { return .key(.error(.unavailable)) }
            return .key(.verify(true))
        case .mac(let purpose, let fields, let createIfMissing):
            if purpose.needsOwnerPresence {
                guard let unlocked = connection.unlocked, now < unlocked.until, unlocked.uses > 0 else {
                    connection.unlocked = nil
                    return .presenceRequired
                }
                connection.unlocked = (unlocked.until, unlocked.uses - 1)
            }
            let key: MCPSigner
            switch storage.loadKey(uid) {
            case .failure: return .key(.error(.unavailable))
            case .success(let existing?): key = existing
            case .success(nil):
                guard createIfMissing else { return .key(.mac(nil)) }
                guard case .success(let created) = storage.createKey(uid) else { return .key(.error(.unavailable)) }
                key = created
            }
            guard case .success(var ledger) = storage.loadLedger(uid),
                let counter = ledger.issue(purpose: purpose, scope: scope, fields: fields),
                storage.saveLedger(uid, ledger)
            else { return .key(.error(.unavailable)) }
            let hex = key.mac(purpose.rawValue, MCPCounterMAC.fields(scope: scope, counter: counter, fields))
            return .key(.mac(MCPCounterMAC(counter: counter, hex: hex).text))
        }
    }

    private func status(_ uid: UInt32) -> MCPApprovalKeyStatus {
        switch storage.loadKey(uid) {
        case .failure: .unavailable
        case .success(nil): .notEnrolled
        case .success: .enrolled
        }
    }
}
