#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// The approvals custodian's socket protocol: what a client, the key
/// daemon and the presence helper say to each other over Unix sockets
/// (docs/security/mcp-linux-custodian.md). Linux uses it today; nothing
/// in it is Linux-specific, so the macOS custodian can adopt it.
///
/// Every message is one frame: a 4-byte big-endian length, then that many
/// bytes of JSON. A frame over `maximumFrameBytes`, or one that does not
/// decode, ends the connection. No message carries key material.
public enum MCPCustodianSocket {
    public static let protocolVersion = "rv.mcp-custodian.socket.v1"
    /// The key daemon's socket, in a directory only root can create.
    public static let path = "/run/rv-mcp-custodian/custodian.sock"
    /// The presence helper's socket.
    public static let presencePath = "/run/rv-mcp-presence/presence.sock"
    /// Root's own copy of the custodian, where `install` puts it. Its
    /// presence means a custodian is installed even while its socket is
    /// not there (stopped, or crashed).
    public static let installedBinary = "/usr/local/libexec/rv/rv-mcp-custodian"
    /// Where the key daemon keeps each account's key and ledger.
    public static let stateDirectory = "/var/lib/rv-mcp-custodian"
    /// The system account that holds the keys.
    public static let account = "rv-mcp-custodian"
    /// The PAM service the presence helper authenticates the owner with.
    public static let pamService = "rv-mcp-custodian"

    public static let maximumFrameBytes = 512 * 1024
    public static let maximumScopeBytes = 4096
    public static let challengeBytes = 32
    /// How long a challenge waits for the owner to authenticate.
    public static let challengeLifetime = Duration.seconds(120)
    /// How long, and for how many signatures, one proof of presence
    /// unlocks the connection that asked for it.
    public static let presenceWindow = Duration.seconds(30)
    public static let presenceUses = 16
    public static let maximumAnswerBytes = 1024
    public static let maximumPromptBytes = 1024

    /// A scope names whose state a request is about: the client's rv
    /// configuration directory, absolute.
    public static func isValid(scope: String) -> Bool {
        scope.hasPrefix("/") && scope.utf8.count <= maximumScopeBytes && scope.utf8.contains(0) == false
    }

    public static func isValid(challenge: String) -> Bool {
        challenge.utf8.count == challengeBytes * 2 && challenge.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
        }
    }
}

/// What a peer sends the key daemon.
public enum MCPCustodianSocketRequest: Sendable, Equatable, Codable {
    /// First on every connection; nothing else is answered before it.
    case hello(protocolVersion: String)
    /// One key operation, for the peer's own key.
    case key(scope: String, request: MCPCustodianRequest)
    /// Ask for a challenge the owner's authentication will answer.
    case challenge
    /// From the presence helper only: the owner of `uid` authenticated
    /// for the connection holding `challenge`.
    case attest(challenge: String, uid: UInt32)
}

public enum MCPCustodianSocketResponse: Sendable, Equatable, Codable {
    case hello(ok: Bool, protocolVersion: String)
    case key(MCPCustodianResponse)
    /// The operation signs what only the owner may sign, and this
    /// connection has no live proof that the owner is present.
    case presenceRequired
    case challenge(String)
    case attested(Bool)
    case error(MCPCustodianError)
}

/// What a client sends the presence helper.
public enum MCPPresenceRequest: Sendable, Equatable, Codable {
    case prove(protocolVersion: String, challenge: String)
    /// The answer to the last `prompt`.
    case answer(String)
}

public enum MCPPresenceResponse: Sendable, Equatable, Codable {
    /// Show `text` and send back what the owner types; `secret` input is
    /// not echoed.
    case prompt(text: String, secret: Bool)
    /// Show `text`; nothing is expected back.
    case notice(String)
    case result(MCPPresenceResult)
}

public enum MCPPresenceResult: String, Sendable, Equatable, Codable {
    /// Authenticated, and the key daemon accepted the attestation.
    case proved
    case authenticationFailed
    /// Authentication succeeded without asking the owner for anything
    /// (an empty password, a permissive PAM stack): not proof of presence.
    case nothingAsked
    /// The peer is root, or its uid has no account on this host.
    case noAccount
    /// Another proof for this account is in progress.
    case busy
    /// The challenge was not one the key daemon is waiting on.
    case rejected
    /// PAM or the key daemon could not be used.
    case unavailable
    case badRequest
}

/// Frame encoding, shared by every party.
public enum MCPCustodianFrame {
    public static func encode<T: Encodable>(_ value: T) -> [UInt8]? {
        guard let body = try? JSONEncoder().encode(value), body.count <= MCPCustodianSocket.maximumFrameBytes else {
            return nil
        }
        var length = UInt32(body.count).bigEndian
        return withUnsafeBytes(of: &length) { Array($0) } + Array(body)
    }

    /// The body length a 4-byte header announces; nil when it is over the bound.
    public static func bodyLength(header: [UInt8]) -> Int? {
        guard header.count == 4 else { return nil }
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        return length <= MCPCustodianSocket.maximumFrameBytes ? length : nil
    }

    public static func decode<T: Decodable>(_ type: T.Type, body: [UInt8]) -> T? {
        try? JSONDecoder().decode(type, from: Data(body))
    }

    #if os(Linux)
    /// Writes one frame. False when the value does not fit or the peer is gone.
    public static func write<T: Encodable>(_ value: T, to fd: Int32) -> Bool {
        guard let frame = encode(value) else { return false }
        var sent = 0
        while sent < frame.count {
            let count = frame.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return send(fd, base + sent, frame.count - sent, Int32(MSG_NOSIGNAL))
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }
            sent += count
        }
        return true
    }

    /// Reads one frame. Nil at end of stream, on a timeout, an oversized
    /// frame, or a body that is not a `T`.
    public static func read<T: Decodable>(_ type: T.Type, from fd: Int32) -> T? {
        guard let header = bytes(4, from: fd), let length = bodyLength(header: header),
            let body = bytes(length, from: fd)
        else { return nil }
        return decode(type, body: body)
    }

    private static func bytes(_ count: Int, from fd: Int32) -> [UInt8]? {
        guard count > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let got = buffer.withUnsafeMutableBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return recv(fd, base + filled, count - filled, 0)
            }
            if got < 0, errno == EINTR { continue }
            guard got > 0 else { return nil }
            filled += got
        }
        return buffer
    }
    #endif
}

/// A MAC the socket custodian issues: `v1.<counter>.<hex>`. The counter
/// is the custodian's own, never repeats, and is inside the MAC, so the
/// custodian can tell the newest signature of a file from an older one
/// put back (`MCPCustodianLedger`). A bare 64-hex MAC (no counter) is
/// what the file store and the macOS keychain custodian issue.
public struct MCPCounterMAC: Equatable, Sendable {
    public static let version = "v1"
    /// Domain separator inside the MAC'd fields.
    public static let domain = "rv.mcp-custodian.mac.v1"

    public var counter: UInt64
    public var hex: String

    public init(counter: UInt64, hex: String) {
        self.counter = counter
        self.hex = hex
    }

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == Self.version, parts[2].utf8.count == 64,
            parts[1].isEmpty == false, parts[1].utf8.count <= 20, parts[1].utf8.allSatisfy({ (0x30...0x39).contains($0) }),
            parts[1].first != "0" || parts[1].count == 1, let counter = UInt64(parts[1])
        else { return nil }
        self.counter = counter
        self.hex = String(parts[2])
    }

    public var text: String { "\(Self.version).\(counter).\(hex)" }

    /// What the key signs for this counter: the caller's fields behind the
    /// domain, the scope and the counter.
    public static func fields(scope: String, counter: UInt64, _ fields: [String]) -> [String] {
        [domain, scope, String(counter)] + fields
    }
}
