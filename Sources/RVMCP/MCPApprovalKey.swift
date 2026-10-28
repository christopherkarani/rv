#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVIsolation

/// Signs what only rv may produce: approval grants, confirmation codes, and
/// rv's own mcp.json writes. Fields are length-prefixed, so two different
/// field lists never share a MAC.
public struct MCPSigner: Sendable {
    let key: [UInt8]

    public init?(key: [UInt8]) {
        guard key.count == 32 else { return nil }
        self.key = key
    }

    public func mac(_ purpose: String, _ fields: [String]) -> String {
        var message: [UInt8] = []
        for field in [purpose] + fields {
            let bytes = Array(field.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { message += $0 }
            message += bytes
        }
        return MCPHex.encode(RVDigest.hmacSHA256(key: key, message: message))
    }

    /// Constant-time comparison against a freshly computed MAC.
    public func verify(_ candidate: String?, _ purpose: String, _ fields: [String]) -> Bool {
        guard let candidate else { return false }
        let expected = Array(mac(purpose, fields).utf8)
        let given = Array(candidate.utf8)
        guard expected.count == given.count else { return false }
        return zip(expected, given).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Names for where the approvals key lives, shared by the custodian that
/// holds the key and by client-side diagnostics. Key material itself
/// never travels with these names.
public enum MCPApprovalKeyIdentity {
    public static let keychainService = "rv.approvals"
    public static let keychainAccount = "hmac-key"
    /// Seal key for the macOS enrollment. It is a keychain item, not a file.
    public static let anchorAccount = "hmac-anchor"
    public static let fileName = "approvals.key"
}

/// Whether an approvals key exists to MAC or verify with. `.unavailable`
/// means the holder of the key could not be reached or could not answer;
/// callers fail closed on it exactly as on `.notEnrolled`.
public enum MCPApprovalKeyStatus: String, Sendable, Equatable, Codable {
    case enrolled
    case notEnrolled
    case unavailable
}

/// The only thing callers may do with the approvals key: ask for a MAC or
/// ask whether a MAC verifies. Key bytes never leave the implementation
/// behind this struct. `verify` never creates a key, and its nil means
/// "no key to judge with" — distinct from false, "judged and forged".
/// Only `mac` with `createIfMissing` may enroll a new key.
public struct MCPApprovalSigning: Sendable {
    /// Whether a grant MAC'd under this key proves a person approved.
    /// Only a key whose every use requires the person present (the macOS
    /// data-protection keychain, held by its custodian) qualifies. A
    /// same-user-readable key file proves nothing: any process running as
    /// the user can mint grants. The key still seals integrity state either way.
    public var honorsGrants: Bool
    /// True when using the key itself prompts for user presence at
    /// signing time (the custodian's data-protection keychain item), so
    /// flows can skip a separate presence confirmation: the one
    /// authentication in the operation is the key use.
    public var presenceAtSigning: Bool
    public var status: @Sendable () -> MCPApprovalKeyStatus
    public var mac: @Sendable (_ purpose: String, _ fields: [String], _ createIfMissing: Bool) -> String?
    public var verify: @Sendable (_ candidate: String?, _ purpose: String, _ fields: [String]) -> Bool?
    /// Ends any reusable authentication window so the next key use in
    /// this operation prompts exactly once. No-op where key use does not
    /// authenticate (file store) or cannot reuse (in-process test fakes).
    public var beginFreshAuth: @Sendable () -> Void

    public init(
        honorsGrants: Bool = true,
        presenceAtSigning: Bool = false,
        status: @escaping @Sendable () -> MCPApprovalKeyStatus,
        mac: @escaping @Sendable (String, [String], Bool) -> String?,
        verify: @escaping @Sendable (String?, String, [String]) -> Bool?,
        beginFreshAuth: @escaping @Sendable () -> Void = {}
    ) {
        self.honorsGrants = honorsGrants
        self.presenceAtSigning = presenceAtSigning
        self.status = status
        self.mac = mac
        self.verify = verify
        self.beginFreshAuth = beginFreshAuth
    }

    public static let unavailable = MCPApprovalSigning(
        honorsGrants: false, status: { .unavailable }, mac: { _, _, _ in nil }, verify: { _, _, _ in nil })

    /// Custodian-side adapter over a signer held by this process. Every
    /// operation loads the signer fresh, so what is judged is the key as
    /// read for that operation, never a cached copy.
    public static func inProcess(
        honorsGrants: Bool = true,
        status: (@Sendable () -> MCPApprovalKeyStatus)? = nil,
        load: @escaping @Sendable () -> MCPSigner?,
        loadOrCreate: @escaping @Sendable () -> MCPSigner?,
        beginFreshAuth: @escaping @Sendable () -> Void = {}
    ) -> MCPApprovalSigning {
        MCPApprovalSigning(
            honorsGrants: honorsGrants,
            status: status ?? { load() == nil ? .notEnrolled : .enrolled },
            mac: { purpose, fields, createIfMissing in
                (createIfMissing ? loadOrCreate() : load())?.mac(purpose, fields)
            },
            verify: { candidate, purpose, fields in
                load().map { $0.verify(candidate, purpose, fields) }
            },
            beginFreshAuth: beginFreshAuth)
    }

    /// macOS keeps the key in the data-protection keychain, held only by
    /// the approvals custodian (`rv-mcp-custodian` in RVApprovals.app): a
    /// bare rv binary cannot be provisioned for the item's access group,
    /// so this process never touches the keychain for approvals — it asks
    /// the custodian over XPC and fails closed when the custodian is
    /// unreachable or unverifiable. Linux has no OS secret store, so the
    /// key is a 0600 file in the rv config directory, which a process
    /// running as the same user can read; approvals there fail closed
    /// instead of trusting MACs anyone could mint.
    public static func live(configDirectory: URL, home: String) -> MCPApprovalSigning {
        #if os(macOS)
        _ = configDirectory
        return .custodian(transport: MCPCustodianXPCClient.liveTransport(home: home))
        #else
        _ = home
        return .file(configDirectory: configDirectory, honorsGrants: false)
        #endif
    }

    /// `approvals.key` (0600) in the rv config directory, re-read per operation.
    public static func file(configDirectory: URL, honorsGrants: Bool = true) -> MCPApprovalSigning {
        let url = configDirectory.appendingPathComponent(MCPApprovalKeyIdentity.fileName, isDirectory: false)
        return inProcess(
            honorsGrants: honorsGrants,
            load: { readKeyFile(url) },
            loadOrCreate: { readKeyFile(url) ?? createKeyFile(url, directory: configDirectory) })
    }

    static func newKey() -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in generator.next() }
    }

    static func readKeyFile(_ url: URL) -> MCPSigner? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
            (info.st_mode & 0o077) == 0, info.st_size == 64
        else { return nil }
        var text = [UInt8](repeating: 0, count: 64)
        let count = text.withUnsafeMutableBytes { read(fd, $0.baseAddress, 64) }
        guard count == 64 else { return nil }
        return MCPHex.decode(text).flatMap(MCPSigner.init(key:))
    }

    /// O_EXCL: when two processes race, the loser reads the winner's key.
    static func createKeyFile(_ url: URL, directory: URL) -> MCPSigner? {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let text = Array(MCPHex.encode(newKey()).utf8)
        let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return readKeyFile(url) }
        let written = text.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        let synced = fsync(fd) == 0
        close(fd)
        guard written == text.count, synced else {
            unlink(url.path)
            return nil
        }
        return readKeyFile(url)
    }
}


/// One-time code bound to one pending call. The gateway prints it on stderr
/// when the request is recorded, so the person can type it before Touch ID.
/// 10 symbols from a 32-letter alphabet without look-alikes: 50 bits.
public enum MCPConfirmationCode {
    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        let symbols = (0..<10).map { _ in alphabet[Int(generator.next(upperBound: UInt8(alphabet.count)))] }
        return String(symbols[0..<5]) + "-" + String(symbols[5...])
    }

    /// Uppercased, without spaces or dashes, so `abcde fghjk` matches `ABCDE-FGHJK`.
    public static func normalize(_ typed: String) -> String {
        String(typed.uppercased().filter { $0 != "-" && $0.isWhitespace == false })
    }
}

/// Hex codec for key text. Public so the custodian (the only other
/// holder of key bytes) encodes exactly what the file adapter does.
public enum MCPHex {
    public static func encode(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func decode(_ text: [UInt8]) -> [UInt8]? {
        guard text.count.isMultiple(of: 2) else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: c - 0x30
            case 0x61...0x66: c - 0x61 + 10
            case 0x41...0x46: c - 0x41 + 10
            default: nil
            }
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.count / 2)
        var index = 0
        while index < text.count {
            guard let high = nibble(text[index]), let low = nibble(text[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        return bytes
    }
}
