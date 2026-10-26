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
    /// Seal key for the macOS enrollment. It is a keychain item, not a file.
    public static let anchorAccount = "hmac-anchor"
    public static let fileName = "approvals.key"

    public var load: @Sendable () -> MCPSigner?
    public var loadOrCreate: @Sendable () -> MCPSigner?
    /// Whether a grant MAC'd under this key proves a person approved.
    /// Only a key whose every read requires the person present (the macOS
    /// data-protection keychain) qualifies. A same-user-readable key file
    /// proves nothing: any process running as the user can mint grants.
    /// The key still seals integrity state either way.
    public var honorsGrants: Bool

    public init(
        load: @escaping @Sendable () -> MCPSigner?, loadOrCreate: @escaping @Sendable () -> MCPSigner?,
        honorsGrants: Bool = true
    ) {
        self.load = load
        self.loadOrCreate = loadOrCreate
        self.honorsGrants = honorsGrants
    }

    public static let unavailable = MCPApprovalKeyStore(load: { nil }, loadOrCreate: { nil }, honorsGrants: false)

    /// macOS keeps the key in the data-protection keychain and requires the
    /// user to be present for every read. Linux has no OS secret store, so
    /// the key is a 0600 file in the rv config directory, which a process
    /// running as the same user can read; approvals there fail closed
    /// instead of trusting MACs anyone could mint.
    public static func live(configDirectory: URL, home: String) -> MCPApprovalKeyStore {
        #if os(macOS)
        _ = home
        return MCPApprovalKeyStore(
            load: { ApprovalKeychain.read(configDirectory: configDirectory) },
            loadOrCreate: {
                ApprovalKeychain.read(configDirectory: configDirectory) ?? ApprovalKeychain.create(configDirectory: configDirectory)
            })
        #else
        _ = home
        var store = file(configDirectory: configDirectory)
        store.honorsGrants = false
        return store
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

/// Whether a data-protection keychain item may be used as rv's approvals key.
/// The access-control constraint dictionary records
/// `kSecAccessControlUserPresence` as `cpo`, nested under `od`. An item with
/// no such constraint is not adopted. `pkofn` is an OR (k-of-n) policy: cpo
/// inside it does not by itself require user presence, so that item is not
/// adopted either. The dictionary has no public accessor, so the live check
/// is behavioral: an item that copies without authentication UI does not
/// require user presence, whatever its constraints claim.
enum ApprovalKeyAccess {
    static let userPresenceConstraint = "cpo"
    static let orConstraint = "pkofn"

    enum Item: Equatable {
        case absent
        case unreadable
        case noAccessControl
        case constraints(userPresence: Bool)
    }

    enum Adoption: Equatable {
        case absent
        case accept
        /// Not rv's key. Delete it so a later create can store one that requires user presence.
        case rejectAndDelete
        /// Do not adopt the secret. Leave the item in place.
        case rejectKeep
    }

    static func requiresUserPresence(_ constraints: [String: Any]?) -> Bool {
        guard let constraints, allowsPresenceBypass(constraints) == false else { return false }
        if constraints[userPresenceConstraint] != nil { return true }
        guard let operation = constraints["od"] as? [String: Any] else { return false }
        return operation[userPresenceConstraint] != nil
    }

    /// `pkofn` lets one listed constraint authorize the copy. A policy that
    /// contains cpo and anything else can succeed without user presence.
    static func allowsPresenceBypass(_ constraints: [String: Any]) -> Bool {
        if constraints[orConstraint] != nil { return true }
        if let operation = constraints["od"] as? [String: Any], operation[orConstraint] != nil { return true }
        return false
    }

    static func adoption(_ item: Item) -> Adoption {
        switch item {
        case .absent: .absent
        case .unreadable: .rejectKeep
        case .noAccessControl: .rejectAndDelete
        case .constraints(let userPresence): userPresence ? .accept : .rejectAndDelete
        }
    }

    /// Flattens one level of a keychain constraint dictionary. Non-dictionaries yield [:].
    static func stringKeyed(_ value: Any?) -> [String: Any] {
        guard let dictionary = value as? NSDictionary else { return [:] }
        var parsed: [String: Any] = [:]
        for case let key as String in dictionary.allKeys {
            if let nested = dictionary[key] as? NSDictionary {
                var inner: [String: Any] = [:]
                for case let child as String in nested.allKeys {
                    if let nestedValue = nested[child] { inner[child] = nestedValue }
                }
                parsed[key] = inner
            } else if let stored = dictionary[key] {
                parsed[key] = stored
            }
        }
        return parsed
    }

    /// What `read` does with one copied item. `accept` from `adoption` is the
    /// ACL only. A cpo item still is not the signing secret unless it is the
    /// key rv enrolled.
    enum Disposition: Equatable {
        case absent
        case accept
        case rejectAndDelete
        case rejectPlanted
        case rejectKeep
    }

    static func disposition(
        secret: Data?, anchor: [UInt8]?, pinnedFingerprint: String?, item: Item, configDirectory: URL
    ) -> Disposition {
        switch adoption(item) {
        case .absent: return .absent
        case .rejectKeep: return .rejectKeep
        case .rejectAndDelete: return .rejectAndDelete
        case .accept:
            guard let secret, let anchor, let pinnedFingerprint,
                signer(secret: secret, anchor: anchor, pinnedFingerprint: pinnedFingerprint, configDirectory: configDirectory) != nil
            else { return .rejectPlanted }
            return .accept
        }
    }

    /// The signing secret for one copied item. `anchor` and `pinnedFingerprint`
    /// come from the keychain seal item, not from disk. The enrollment file
    /// must match that pair, and the secret's own fingerprint must be the one
    /// the seal item pinned. Rewriting `approvals.anchor` or `approvals.enrollment`
    /// cannot change either value.
    static func signer(secret: Data, anchor: [UInt8], pinnedFingerprint: String, configDirectory: URL) -> MCPSigner? {
        ApprovalKeyAnchor.remove(configDirectory)
        guard anchor.count == 32, pinnedFingerprint.count == 64,
            let text = String(data: secret, encoding: .utf8),
            let key = MCPHex.decode(Array(text.utf8)), key.count == 32,
            ApprovalKeyMAC.equal(RVDigest.sha256Hex(key), pinnedFingerprint),
            let enrollment = ApprovalKeyEnrollment.load(configDirectory),
            enrollment.binds(key: key, anchor: anchor)
        else { return nil }
        return MCPSigner(key: key)
    }

    /// Constraints dictionary from a copied item, for callers that do not have a SecAccessControl.
    static func item(from constraints: [String: Any]?) -> Item {
        guard let constraints, constraints.isEmpty == false else { return .noAccessControl }
        return .constraints(userPresence: requiresUserPresence(constraints))
    }

    static func adoptedSigner(
        secret: Data, anchor: [UInt8]?, pinnedFingerprint: String?, constraints: [String: Any]?, configDirectory: URL
    ) -> MCPSigner? {
        guard case .accept = disposition(
            secret: secret, anchor: anchor, pinnedFingerprint: pinnedFingerprint, item: item(from: constraints),
            configDirectory: configDirectory)
        else { return nil }
        guard let anchor, let pinnedFingerprint else { return nil }
        return signer(
            secret: secret, anchor: anchor, pinnedFingerprint: pinnedFingerprint, configDirectory: configDirectory)
    }
}

/// Commitment that an approvals key matches the seal key held in the keychain.
/// The file stores a fingerprint and a seal. It does not store the MAC key or
/// the seal key. Rewriting it cannot enroll a different keychain secret.
struct ApprovalKeyEnrollment: Equatable {
    var fingerprint: String
    var seal: String

    static func issue(key: [UInt8], anchor: [UInt8]) -> ApprovalKeyEnrollment? {
        guard key.count == 32, anchor.count == 32 else { return nil }
        let fingerprint = RVDigest.sha256Hex(key)
        let seal = MCPHex.encode(RVDigest.hmacSHA256(key: anchor, message: Array(fingerprint.utf8)))
        return ApprovalKeyEnrollment(fingerprint: fingerprint, seal: seal)
    }

    func binds(key: [UInt8], anchor: [UInt8]) -> Bool {
        guard key.count == 32, anchor.count == 32 else { return false }
        let fingerprint = RVDigest.sha256Hex(key)
        guard ApprovalKeyMAC.equal(self.fingerprint, fingerprint) else { return false }
        let seal = MCPHex.encode(RVDigest.hmacSHA256(key: anchor, message: Array(fingerprint.utf8)))
        return ApprovalKeyMAC.equal(self.seal, seal)
    }

    static func url(_ configDirectory: URL) -> URL {
        configDirectory.appendingPathComponent("approvals.enrollment")
    }

    func save(configDirectory: URL) -> Bool {
        let root = JSONValue.object([
            "version": .int(1),
            "fingerprint": .string(fingerprint),
            "seal": .string(seal),
        ])
        return OwnerOnlyFile.write(Data(root.compactText.utf8), to: Self.url(configDirectory))
    }

    static func load(_ configDirectory: URL) -> ApprovalKeyEnrollment? {
        guard case .success(let data?) = OwnerOnlyFile.read(url(configDirectory), maximumBytes: 4096),
            let root = try? JSONValue.parse(data),
            root["version"]?.intValue == 1,
            let fingerprint = root["fingerprint"]?.stringValue,
            let seal = root["seal"]?.stringValue,
            fingerprint.count == 64, seal.count == 64
        else { return nil }
        return ApprovalKeyEnrollment(fingerprint: fingerprint, seal: seal)
    }

    static func remove(_ configDirectory: URL) {
        unlink(url(configDirectory).path)
    }
}

/// Seal key for the macOS approvals enrollment. It is not the MAC key, and it
/// is not written here. `approvals.anchor` is leftover key material: `load`
/// does not return it, `save` does not write it, and `remove` deletes the file
/// without reading it. A process that can rewrite this directory cannot mint
/// a seal for a keychain secret it chose.
enum ApprovalKeyAnchor {
    static func url(_ configDirectory: URL) -> URL {
        configDirectory.appendingPathComponent("approvals.anchor")
    }

    static func save(_ anchor: [UInt8], configDirectory: URL) -> Bool {
        _ = anchor
        _ = configDirectory
        return false
    }

    static func load(_ configDirectory: URL) -> [UInt8]? {
        _ = configDirectory
        return nil
    }

    static func remove(_ configDirectory: URL) {
        unlink(url(configDirectory).path)
    }
}

enum ApprovalKeyMAC {
    static func equal(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count, left.isEmpty == false else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

#if os(macOS)
/// Keychain item for `rv.approvals` / `hmac-key`. Creating it sets a
/// user-presence access control on the data-protection keychain, so another
/// process cannot copy the key without the user authenticating. A planted
/// data-protection item is not the signing secret: cpo without rv's
/// enrollment is deleted and not returned, and an OR policy (`pkofn`) is
/// not user presence.
enum ApprovalKeychain {
    static func read(configDirectory: URL) -> MCPSigner? {
        deleteUnprotectedItem()
        deleteUnprotectedItem(account: MCPApprovalKeyStore.anchorAccount)
        guard protectedStoreEnabled else { return nil }
        switch copyProtectedItem(account: MCPApprovalKeyStore.keychainAccount) {
        case .absent, .failed:
            return nil
        case .item(let data, let inspection):
            switch ApprovalKeyAccess.adoption(inspection) {
            case .rejectAndDelete:
                deleteProtectedItem()
                return nil
            case .absent, .rejectKeep:
                return nil
            case .accept:
                switch copyAnchor() {
                case .failed:
                    return nil
                case .absent:
                    // The key item requires presence but its seal item is
                    // gone. Fail closed without deleting: destroying the key
                    // here would void every grant and signature on a read.
                    return nil
                case .value(let anchor, let pinnedFingerprint):
                    // Enrollment mismatch also fails closed without deleting.
                    // The only item `read` deletes is one that provably does
                    // not require user presence, which cannot be rv's key.
                    guard let signer = ApprovalKeyAccess.signer(
                        secret: data, anchor: anchor, pinnedFingerprint: pinnedFingerprint, configDirectory: configDirectory)
                    else { return nil }
                    return signer
                }
            }
        }
    }

    private enum ProtectedCopy {
        case absent
        case failed
        case item(Data, ApprovalKeyAccess.Item)
    }

    private enum AnchorCopy {
        case absent
        case failed
        case value([UInt8], String)
    }

    /// The seal key from the data-protection item. A missing or non-presence
    /// item is `.absent` (not a seal). A cancelled prompt is `.failed`.
    private static func copyAnchor() -> AnchorCopy {
        switch copyProtectedItem(account: MCPApprovalKeyStore.anchorAccount) {
        case .absent:
            return .absent
        case .failed:
            return .failed
        case .item(let data, let inspection):
            switch ApprovalKeyAccess.adoption(inspection) {
            case .accept:
                guard let text = String(data: data, encoding: .utf8), text.count == 128,
                    let anchor = MCPHex.decode(Array(text.prefix(64).utf8)), anchor.count == 32
                else { return .absent }
                let pinned = String(text.suffix(64))
                guard MCPHex.decode(Array(pinned.utf8))?.count == 32 else { return .absent }
                return .value(anchor, pinned)
            case .rejectAndDelete:
                deleteProtectedItem(account: MCPApprovalKeyStore.anchorAccount)
                return .absent
            case .absent, .rejectKeep:
                return .failed
            }
        }
    }

    /// One copy returns the secret and the access-control attributes together.
    /// The secret is discarded unless those attributes require user presence.
    private static func copyProtectedItem(account: String) -> ProtectedCopy {
        var result: AnyObject?
        let status = SecItemCopyMatching(readQuery(account: account) as CFDictionary, &result)
        if status == errSecItemNotFound { return .absent }
        guard status == errSecSuccess, let result else { return .failed }
        let attributes: [String: Any]
        if let dict = result as? [String: Any] {
            attributes = dict
        } else if let dictionary = result as? NSDictionary {
            attributes = ApprovalKeyAccess.stringKeyed(dictionary)
        } else {
            return .failed
        }
        guard let data = attributes[kSecValueData as String] as? Data else { return .failed }
        return .item(data, inspection(of: attributes, account: account))
    }

    /// The constraint dictionary behind a `SecAccessControl` has no public
    /// accessor, so presence is judged behaviorally: copy the same item's
    /// data with authentication UI failed. (Attributes-only copies may not
    /// engage the ACL, so the probe asks for data and discards it.) Success
    /// means the item does not require the user (no `cpo`, or a `pkofn`
    /// bypass); an interaction/auth failure means it does. Anything else is
    /// unreadable and the item is kept.
    private static func inspection(of attributes: [String: Any], account: String) -> ApprovalKeyAccess.Item {
        guard attributes[kSecAttrAccessControl as String] != nil else { return .noAccessControl }
        var probe = copyQuery(silent: true, account: account)
        probe[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        switch SecItemCopyMatching(probe as CFDictionary, &result) {
        case errSecSuccess:
            return .constraints(userPresence: false)
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return .constraints(userPresence: true)
        default:
            return .unreadable
        }
    }

    static func create(configDirectory: URL) -> MCPSigner? {
        if let signer = read(configDirectory: configDirectory) { return signer }
        // The MAC-key item is still present: the person cancelled the prompt,
        // or its ACL could not be read. Do not replace a key we did not inspect.
        if protectedItemExists() != false { return nil }
        deleteUnprotectedItem()
        deleteUnprotectedItem(account: MCPApprovalKeyStore.anchorAccount)
        deleteProtectedItem(account: MCPApprovalKeyStore.anchorAccount)
        ApprovalKeyAnchor.remove(configDirectory)
        let raw = MCPApprovalKeyStore.newKey()
        let anchor = MCPApprovalKeyStore.newKey()
        guard protectedStoreEnabled,
            let enrollment = ApprovalKeyEnrollment.issue(key: raw, anchor: anchor),
            let keyQuery = addQuery(value: Data(MCPHex.encode(raw).utf8)),
            let anchorQuery = addQuery(
                value: Data((MCPHex.encode(anchor) + RVDigest.sha256Hex(raw)).utf8),
                account: MCPApprovalKeyStore.anchorAccount),
            SecItemAdd(keyQuery as CFDictionary, nil) == errSecSuccess,
            SecItemAdd(anchorQuery as CFDictionary, nil) == errSecSuccess,
            enrollment.save(configDirectory: configDirectory)
        else {
            deleteProtectedItem()
            deleteProtectedItem(account: MCPApprovalKeyStore.anchorAccount)
            ApprovalKeyEnrollment.remove(configDirectory)
            ApprovalKeyAnchor.remove(configDirectory)
            return nil
        }
        guard let signer = read(configDirectory: configDirectory),
            let expected = MCPSigner(key: raw),
            signer.mac("enrollment", ["check"]) == expected.mac("enrollment", ["check"])
        else {
            deleteProtectedItem()
            deleteProtectedItem(account: MCPApprovalKeyStore.anchorAccount)
            ApprovalKeyEnrollment.remove(configDirectory)
            ApprovalKeyAnchor.remove(configDirectory)
            return nil
        }
        return signer
    }

    /// True when the data-protection item is present. False when it is not.
    /// Nil when the query failed. Authentication UI is fail, so this does not
    /// return the secret and does not prompt.
    static func protectedItemExists() -> Bool? {
        var result: AnyObject?
        let status = SecItemCopyMatching(existenceQuery() as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        if status == errSecSuccess || status == errSecInteractionNotAllowed { return true }
        return nil
    }

    static func existenceQuery(account: String = MCPApprovalKeyStore.keychainAccount) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: MCPApprovalKeyStore.keychainService,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
    }

    static var protectedStoreEnabled: Bool {
        ApprovalKeyProtection.requiresUserPresence && ApprovalKeyProtection.usesDataProtectionKeychain
            && ApprovalKeyProtection.allowsSilentCopy == false
    }

    static var liveUsesSilentCopy: Bool { ApprovalKeyProtection.allowsSilentCopy }

    static func addQuery(value: Data, account: String = MCPApprovalKeyStore.keychainAccount) -> [String: Any]? {
        guard protectedStoreEnabled else { return nil }
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlocked, .userPresence, &error)
        else { return nil }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: MCPApprovalKeyStore.keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: value,
            kSecAttrAccessControl as String: control,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// `silent` is the second-process copy that must not succeed. The live
    /// read leaves authentication UI at its default, which prompts.
    static func copyQuery(silent: Bool, account: String = MCPApprovalKeyStore.keychainAccount) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: MCPApprovalKeyStore.keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if silent {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        return query
    }

    /// Live read. Attributes travel with the secret so the user-presence ACL
    /// is judged on the same item that would be adopted. Authentication UI
    /// stays at its default, which prompts.
    static func readQuery(account: String = MCPApprovalKeyStore.keychainAccount) -> [String: Any] {
        var query = copyQuery(silent: false, account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    /// Removes a pre-presence item from the file-based login keychain. Delete
    /// does not return the secret. The data-protection item is a different store.
    static func deleteUnprotectedItem(account: String = MCPApprovalKeyStore.keychainAccount) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: MCPApprovalKeyStore.keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Removes a data-protection item that is not rv's user-presence key.
    static func deleteProtectedItem(account: String = MCPApprovalKeyStore.keychainAccount) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: MCPApprovalKeyStore.keychainService,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
#endif

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
