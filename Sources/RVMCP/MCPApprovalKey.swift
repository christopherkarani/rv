#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
#if canImport(Security)
import Security
#endif
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

/// Where the signing key lives. Verifiers call `load` only, so checking a
/// grant or mcp.json never writes the Keychain; signers call `loadOrCreate`.
public struct MCPApprovalKeyStore: Sendable {
    public static let keychainService = "rv.approvals"
    public static let keychainAccount = "hmac-key"
    public static let fileName = "approvals.key"

    public var load: @Sendable () -> MCPSigner?
    public var loadOrCreate: @Sendable () -> MCPSigner?

    public init(load: @escaping @Sendable () -> MCPSigner?, loadOrCreate: @escaping @Sendable () -> MCPSigner?) {
        self.load = load
        self.loadOrCreate = loadOrCreate
    }

    public static let unavailable = MCPApprovalKeyStore(load: { nil }, loadOrCreate: { nil })

    /// macOS keeps the key in the data-protection keychain and requires the
    /// user to be present for every read. Linux has no OS secret store, so
    /// the key is a 0600 file in the rv config directory, which a process
    /// running as the same user can read.
    public static func live(configDirectory: URL, home: String) -> MCPApprovalKeyStore {
        #if os(macOS)
        _ = home
        return MCPApprovalKeyStore(
            load: { ApprovalKeychain.read() },
            loadOrCreate: { ApprovalKeychain.read() ?? ApprovalKeychain.create() })
        #else
        _ = home
        return file(configDirectory: configDirectory)
        #endif
    }

    /// `approvals.key` (0600) in the rv config directory.
    public static func file(configDirectory: URL) -> MCPApprovalKeyStore {
        let url = configDirectory.appendingPathComponent(fileName, isDirectory: false)
        return MCPApprovalKeyStore(
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

/// How the macOS approvals key is stored. A silent `SecItemCopyMatching`
/// (authentication UI fail) is not a successful read. Linux does not use this.
enum ApprovalKeyProtection {
    static let requiresUserPresence = true
    static let usesDataProtectionKeychain = true
    static let allowsSilentCopy = false
}

#if os(macOS)
/// Keychain item for `rv.approvals` / `hmac-key`. Creating it sets a
/// user-presence access control on the data-protection keychain, so another
/// process cannot copy the key without the user authenticating.
enum ApprovalKeychain {
    static func read() -> MCPSigner? {
        deleteUnprotectedItem()
        guard protectedStoreEnabled else { return nil }
        var result: AnyObject?
        guard SecItemCopyMatching(copyQuery(silent: false) as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data, let text = String(data: data, encoding: .utf8)
        else { return nil }
        return MCPHex.decode(Array(text.utf8)).flatMap(MCPSigner.init(key:))
    }

    static func create() -> MCPSigner? {
        deleteUnprotectedItem()
        let raw = MCPApprovalKeyStore.newKey()
        guard protectedStoreEnabled, let query = addQuery(value: Data(MCPHex.encode(raw).utf8)),
            SecItemAdd(query as CFDictionary, nil) == errSecSuccess
        else { return nil }
        return read()
    }

    static var protectedStoreEnabled: Bool {
        ApprovalKeyProtection.requiresUserPresence && ApprovalKeyProtection.usesDataProtectionKeychain
            && ApprovalKeyProtection.allowsSilentCopy == false
    }

    static var liveUsesSilentCopy: Bool { ApprovalKeyProtection.allowsSilentCopy }

    static func addQuery(value: Data) -> [String: Any]? {
        guard protectedStoreEnabled else { return nil }
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlocked, .userPresence, &error)
        else { return nil }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: MCPApprovalKeyStore.keychainService,
            kSecAttrAccount as String: MCPApprovalKeyStore.keychainAccount,
            kSecValueData as String: value,
            kSecAttrAccessControl as String: control,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// `silent` is the second-process copy that must not succeed. The live
    /// read leaves authentication UI at its default, which prompts.
    static func copyQuery(silent: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: MCPApprovalKeyStore.keychainService,
            kSecAttrAccount as String: MCPApprovalKeyStore.keychainAccount,
            kSecReturnData as String: true,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if silent {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        return query
    }

    /// Removes a pre-presence item from the file-based login keychain. Delete
    /// does not return the secret. The data-protection item is a different store.
    static func deleteUnprotectedItem() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: MCPApprovalKeyStore.keychainService,
            kSecAttrAccount as String: MCPApprovalKeyStore.keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
#endif

/// One-time code bound to one pending call. It is not written to the gateway log.
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

enum MCPHex {
    static func encode(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func decode(_ text: [UInt8]) -> [UInt8]? {
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
