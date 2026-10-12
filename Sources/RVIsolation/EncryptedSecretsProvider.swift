#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVFileStore

// MARK: - Encrypted secrets provider (X1-E)

/// AES-256-GCM file-backed secrets provider under an scrypt-derived master key.
///
/// Executor mapping (`packages/plugins/encrypted-secrets/src/index.ts`,
/// oracles `packages/plugins/encrypted-secrets/src/index.test.ts`):
/// writable `get`/`has`/`set`/`delete`/`list` over ciphertext-at-rest values,
/// opaque V2 item ids (keyed solely by the id string, no scope arg), owner
/// filing from the id-embedded owner with caller-binding fallback
/// (`provider-item-owner.ts`: `connection:`/`oauth:`/`oauth-client:` ids
/// read their second segment; anything else falls back), and
/// owner-targeted delete (a remove aimed at the wrong partition deletes
/// nothing). Reads are never owner-filtered: the referencing row owns the
/// partition, exactly as in the Executor facade.
///
/// Key derivation matches Executor bit-for-bit so migrated ciphertext
/// decrypts: password = master-key UTF-8, salt
/// `executor-encrypted-secrets/v1`, N=16384, r=8, p=1 (Node `scryptSync`
/// defaults, verified: an explicit `{N:16384,r:8,p:1}` call equals the
/// bare call), dkLen 32. The payload envelope is likewise identical:
/// `v1.<iv12B>.<tag16B>.<ct>` with standard padded base64.
///
/// NOT wire-compatible with Executor (by ticket design): the store is an
/// RV owner-only JSON document (`secrets-encrypted.json`, closed key set,
/// per-item `owner` field) rather than Executor plugin-storage rows, so
/// there is no shared file/table format and no repartition migration to
/// port (fresh stores cannot contain pre-fix mis-filed rows). Migrating
/// means re-`set`ting each plaintext under the same master key; the
/// derivation KAT pins `deriveKey("master")` against Node so operators can
/// verify key agreement before moving values.
///
/// Crypto is pure Swift in this file (SHA-256, HMAC, PBKDF2, scrypt per
/// RFC 7914, AES-256-GCM per FIPS 197 / SP 800-38D) rather than CryptoKit:
/// RVIsolation has no CryptoKit on Linux and this ticket's owner fence
/// forbids `Package.swift` changes, so a single dependency-free
/// implementation keeps both platforms identical and every line coverable.
/// Correctness is pinned by KAT vectors (RFC 7914 scrypt, RFC 4231 HMAC,
/// NIST GCM, Node cross-checks) instead of by the framework. Beyond the
/// constant-time tag compare, the primitives are table/loop driven, not
/// hardened against timing oracles; the threat model is ciphertext at rest
/// in an owner-only file, where an offline attacker gains nothing from
/// timing that offline guessing does not already give.
///
/// Write discipline (all owner-only writes go through `OwnerOnlyFileWrite`):
/// single-attempt read-modify-write under an in-process mutex plus a
/// cross-process file lock — `load` (plus a post-load dev/ino capture),
/// `verifyIdentity` before every commit (skipped only when the file was
/// absent at load), then `stage`/`commit`. The file lock makes
/// verify-then-commit atomic across writers; the identity check remains
/// as defense in depth against non-locking replacers. Staging uses
/// (`.all`, 8 attempts): unlike the integration sink, secrets have no
/// background reconciler, so a dropped mutation would silently lose a
/// credential write — the write loops until every byte lands. A lock
/// failure or failed verification throws `storeUnwritable` instead of
/// clobbering: contended or surprising writers fail loud, never silently
/// (proven by the cross-instance and stale-identity tests).
///
/// Master-key loading mirrors Executor host `resolveSecretKey`
/// (`apps/host-selfhost/src/config.ts`): trimmed `EXECUTOR_SECRET_KEY`
/// wins, else the trimmed owner-only `secret.key` beside the store.
/// Deliberate divergences, all fail-closed: RV never silently mints and
/// persists a key (no operator surprise, no stranded secrets — mint
/// explicitly with `generateMasterKey`), and the key file goes through
/// the owner-only read discipline (Executor reads it plain).
public struct EncryptedSecretsProvider: SecretsProvider, Sendable {
    /// Provider id. Admitted by `SecretRef.allowedProviders` and wired
    /// into the factory; `resolve` guards `ref.provider == id`, like its
    /// siblings.
    public var id: String { "encrypted" }

    /// Operator config directory holding `secrets-encrypted.json`.
    public var configDirectory: URL
    /// Filing fallback for ids with no embedded owner (Executor: the
    /// caller's binding — subject-bound callers file `user`, else `org`).
    public var defaultOwner: MCPEncryptedSecretsOwner

    /// Values file name beside the sibling operator stores.
    public static let fileName = "secrets-encrypted.json"
    /// Largest values document accepted, matching the sibling stores.
    public static let maximumBytes = 65_536
    /// Largest item count accepted, matching the file provider.
    public static let maximumItems = 256
    /// Master-key environment variable, same spelling as Executor so a
    /// migrated deployment keeps working unchanged.
    public static let masterKeyEnvironmentVariable = "EXECUTOR_SECRET_KEY"
    /// Master-key file name under the config directory, same spelling as
    /// Executor (`<dataDir>/secret.key`).
    public static let masterKeyFileName = "secret.key"
    /// Largest key file accepted. Master keys are short strings; anything
    /// bigger is not a key file.
    static let masterKeyMaximumBytes = 4_096
    /// Cross-process mutation lock sidecar.
    static let lockFileName = ".secrets-encrypted.json.lock"

    /// Derived 32-byte AES key. Always 32 bytes from `init(masterKey:)` via
    /// scrypt; the internal init takes test-controlled bytes (including
    /// short keys, which fail closed at encrypt/decrypt time).
    private let keyBytes: [UInt8]
    /// Serializes same-instance mutations; struct copies share the box, so
    /// concurrent `set`/`delete` on copies never interleave. Cross-instance
    /// writers serialize on the file lock inside `mutate` (`verifyIdentity`
    /// remains as defense in depth against non-locking replacers).
    private let storeLock: MCPEncryptedStoreLock

    /// Derives the AES key from `masterKey` (any non-empty string, UTF-8).
    /// Throws `emptyMasterKey` on an empty master — a secret store with no
    /// key is unsafe, mirroring Executor's loud construction failure.
    public init(
        configDirectory: URL,
        masterKey: String,
        defaultOwner: MCPEncryptedSecretsOwner
    ) throws(EncryptedSecretsConfigError) {
        guard masterKey.isEmpty == false else {
            throw EncryptedSecretsConfigError.emptyMasterKey
        }
        self.configDirectory = configDirectory
        self.keyBytes = MCPScrypt.executorKey(masterKey: masterKey)
        self.defaultOwner = defaultOwner
        self.storeLock = MCPEncryptedStoreLock()
    }

    /// Test seam: skips the scrypt derivation so store-mechanics tests run
    /// fast. Production always derives via `init(masterKey:)`.
    init(
        configDirectory: URL,
        keyBytes: [UInt8],
        defaultOwner: MCPEncryptedSecretsOwner
    ) {
        self.configDirectory = configDirectory
        self.keyBytes = keyBytes
        self.defaultOwner = defaultOwner
        self.storeLock = MCPEncryptedStoreLock()
    }

    /// Loads the master key: trimmed `EXECUTOR_SECRET_KEY` wins, else the
    /// trimmed owner-only `secret.key` under `keyFileDirectory`. Tri-state,
    /// mirroring the Vault rule: `.success(key)` loads, `.success(nil)` is
    /// absent (no env var and no key file — the factory skips the
    /// provider), and `.failure` is present-but-unusable (unsafe,
    /// unreadable, oversized, or non-UTF-8 — the factory fails loud, never
    /// silently omitting a provider the operator believes is configured).
    /// A blank env var falls through to the key file; a blank key file
    /// carries no key and reads as absent.
    public static func loadMasterKey(
        environment: [String: String],
        keyFileDirectory: URL?
    ) -> Result<String?, EncryptedSecretsKeyLoadError> {
        if let candidate = environment[masterKeyEnvironmentVariable] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty == false {
                return .success(trimmed)
            }
        }
        guard let directory = keyFileDirectory else {
            return .success(nil)
        }
        switch OwnerOnlyFile.loadBytes(
            fileName: masterKeyFileName, from: directory,
            maximumBytes: masterKeyMaximumBytes
        ) {
        case .success(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                return .failure(.keyUnusable)
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else {
                return .success(nil)
            }
            return .success(trimmed)
        case .failure(.missing):
            return .success(nil)
        case .failure(.inaccessible), .failure(.unsafeLocation),
            .failure(.unreadable), .failure(.oversized):
            return .failure(.keyUnusable)
        }
    }

    /// Mints a fresh master key: 32 random bytes, base64. Explicit — the
    /// provider never calls this on its own (see the header note).
    public static func generateMasterKey() -> String {
        Data(MCPRandom.bytes(count: 32)).base64EncodedString()
    }

    /// Resolves one encrypted-backed ref. Refs naming another provider
    /// are `.invalidRef`, matching the 1Password and WorkOS Vault
    /// providers. A missing document is an empty store (every ref is
    /// `.notFound`, never provider-down); unreadable or corrupt stores,
    /// and values that fail authentication (wrong key or tamper), are
    /// `.providerDown`. Encrypted values are whole strings, so a
    /// field-carrying ref can never resolve and fails closed as
    /// `.notFound`, mirroring the env provider's unknown-field mapping.
    public func resolve(_ ref: SecretRef) async throws -> SecretValue {
        guard ref.provider == id else {
            throw SecretsError.invalidRef(id)
        }
        guard ref.field == nil else {
            throw SecretsError.notFound(id)
        }
        let loaded: (items: [String: MCPEncryptedSecretsRow], fileExisted: Bool)
        do {
            loaded = try Self.load(from: configDirectory)
        } catch {
            throw SecretsError.providerDown(id)
        }
        guard let row = loaded.items[ref.item] else {
            throw SecretsError.notFound(id)
        }
        guard let text = MCPEncryptedPayload.decrypt(key: keyBytes, payload: row.payload) else {
            throw SecretsError.providerDown(id)
        }
        return .text(text)
    }

    /// Reachable when the values document loads (a missing document is an
    /// empty store, still reachable). A wrong master key is invisible here
    /// — authentication happens per value at resolve time — so health
    /// reports store readability only, never key agreement.
    public func health() async -> ProviderHealth {
        do {
            _ = try Self.load(from: configDirectory)
            return ProviderHealth(ok: true)
        } catch {
            return ProviderHealth(ok: false)
        }
    }

    /// Reads one value, or nil when the item is absent. Executor oracle:
    /// "set then get returns the plaintext" / "get returns null for a
    /// missing id".
    public func get(item: String) throws(EncryptedSecretsStoreError) -> String? {
        let loaded = try Self.load(from: configDirectory)
        guard let row = loaded.items[item] else {
            return nil
        }
        guard let text = MCPEncryptedPayload.decrypt(key: keyBytes, payload: row.payload) else {
            throw .decryptFailed
        }
        return text
    }

    /// Reports presence without decrypting. Executor oracle: "has and
    /// delete reflect presence".
    public func has(item: String) throws(EncryptedSecretsStoreError) -> Bool {
        let loaded = try Self.load(from: configDirectory)
        return loaded.items[item] != nil
    }

    /// Encrypts `value` under a fresh random IV and stores the payload,
    /// filing the row under the id-embedded owner (else `defaultOwner`).
    /// Overwrites in place, re-filing the owner. Executor oracles: "set
    /// then get returns the plaintext", "stores ciphertext at rest, not
    /// plaintext", and the four owner-partitioning cases.
    public func set(item: String, value: String) throws(EncryptedSecretsStoreError) {
        guard SecretLabels.isValidItem(item) else {
            throw .invalidItem
        }
        guard let payload = MCPEncryptedPayload.encrypt(key: keyBytes, plaintext: value) else {
            throw .encryptFailed
        }
        let owner = MCPEncryptedSecretsOwner.ownerForItemID(item, defaultOwner: defaultOwner)
        try mutate { items in
            items[item] = MCPEncryptedSecretsRow(owner: owner, payload: payload)
            return true
        }
    }

    /// Removes one value. Idempotent: absent ids are a no-op success.
    /// Targets the embedded owner's partition: when the stored row was
    /// filed under a different owner than the id now resolves to, the
    /// remove deletes nothing — the Executor owner-filtered remove.
    /// Executor oracles: "has and delete reflect presence" / "delete
    /// targets the embedded owner's partition".
    public func delete(item: String) throws(EncryptedSecretsStoreError) {
        try mutate { items in
            guard let existing = items[item] else {
                return false
            }
            guard existing.owner == MCPEncryptedSecretsOwner.ownerForItemID(
                item, defaultOwner: defaultOwner
            ) else {
                return false
            }
            items.removeValue(forKey: item)
            return true
        }
    }

    /// Lists every stored id with its filed owner, sorted by id. Never
    /// owner-filtered and never decrypts. Executor oracle: "list surfaces
    /// stored ids".
    public func list() throws(EncryptedSecretsStoreError) -> [MCPEncryptedSecretEntry] {
        let loaded = try Self.load(from: configDirectory)
        return loaded.items
            .map { MCPEncryptedSecretEntry(id: $0.key, owner: $0.value.owner) }
            .sorted { $0.id < $1.id }
    }

    /// Serialized read-modify-write: loads, applies `transform`, and
    /// commits only when it reports a change. Caps are enforced on the new
    /// document before the write; the write itself verifies the live file
    /// is still the file just read. The cross-process file lock makes the
    /// verify-then-commit sequence atomic across writers (without it two
    /// writers could both verify and the second commit would silently
    /// clobber the first); lock-ordering is fixed (in-process mutex, then
    /// file lock) and `mutate` never nests, so it cannot deadlock.
    private func mutate(
        _ transform: (inout [String: MCPEncryptedSecretsRow]) -> Bool
    ) throws(EncryptedSecretsStoreError) {
        try storeLock.withLock { () throws(EncryptedSecretsStoreError) in
            do {
                try ExclusiveFileLock.withLock(at: lockFileURL) {
                    let loaded = try Self.load(from: configDirectory)
                    var items = loaded.items
                    guard transform(&items) else {
                        return
                    }
                    guard items.count <= Self.maximumItems else {
                        throw EncryptedSecretsStoreError.storeUnwritable
                    }
                    let bytes = Self.encode(items: items)
                    guard bytes.count <= Self.maximumBytes else {
                        throw EncryptedSecretsStoreError.storeUnwritable
                    }
                    let expected = loaded.fileExisted
                        ? Self.identityOfLiveFile(directory: configDirectory) : nil
                    try Self.write(bytes: bytes, expected: expected, directory: configDirectory)
                }
            } catch let error as EncryptedSecretsStoreError {
                throw error
            } catch {
                throw .storeUnwritable
            }
        }
    }

    /// Sidecar lock file ordering cross-process mutations. Hidden, 0600,
    /// managed by `ExclusiveFileLock` (created on first mutation).
    private var lockFileURL: URL {
        configDirectory.appendingPathComponent(Self.lockFileName)
    }
}

// MARK: - Store document

/// One stored row: the filed partition plus the `v1.…` payload. Payloads
/// are validated cryptographically at use, not structurally here, so one
/// tampered row fails only its own reads (Executor: per-item decrypt
/// failure) instead of bricking the store.
struct MCPEncryptedSecretsRow: Sendable, Decodable {
    var owner: MCPEncryptedSecretsOwner
    var payload: String

    init(owner: MCPEncryptedSecretsOwner, payload: String) {
        self.owner = owner
        self.payload = payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(container, allowed: ["owner", "payload"])
        let rawOwner = try container.decode(String.self, forKey: StrictJSONKey("owner"))
        guard let parsed = MCPEncryptedSecretsOwner(rawValue: rawOwner) else {
            throw DecodingError.dataCorruptedError(
                forKey: StrictJSONKey("owner"), in: container,
                debugDescription: "unknown owner"
            )
        }
        owner = parsed
        let rawPayload = try container.decode(String.self, forKey: StrictJSONKey("payload"))
        guard rawPayload.isEmpty == false else {
            throw DecodingError.dataCorruptedError(
                forKey: StrictJSONKey("payload"), in: container,
                debugDescription: "empty payload"
            )
        }
        payload = rawPayload
    }
}

/// Versioned values document: `{"version":1,"items":{"<id>":{"owner":…,
/// "payload":"v1.…"}}}`. Closed key set, like the sibling stores.
private struct MCPEncryptedSecretsDocument: Decodable {
    var version: Int
    var items: [String: MCPEncryptedSecretsRow]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(container, allowed: ["version", "items"])
        version = try container.decode(Int.self, forKey: StrictJSONKey("version"))
        items = try container.decode(
            [String: MCPEncryptedSecretsRow].self, forKey: StrictJSONKey("items")
        )
    }
}

extension EncryptedSecretsProvider {
    /// Loads the store. A missing file (or directory) is an empty store;
    /// every other IO failure is `storeUnreadable`, every content failure
    /// is `corruptDocument`. Each `OwnerOnlyFileError` arm is mapped
    /// exactly once; the four IO arms share one outcome.
    static func load(
        from directory: URL
    ) throws(EncryptedSecretsStoreError) -> (
        items: [String: MCPEncryptedSecretsRow], fileExisted: Bool
    ) {
        switch OwnerOnlyFile.loadBytes(
            fileName: fileName, from: directory, maximumBytes: maximumBytes
        ) {
        case .success(let data):
            return try (items: decode(data), fileExisted: true)
        case .failure(.missing):
            return (items: [:], fileExisted: false)
        case .failure(.inaccessible), .failure(.unsafeLocation),
            .failure(.unreadable), .failure(.oversized):
            throw .storeUnreadable
        }
    }

    /// Decodes plus validates one store document: version 1, item cap,
    /// valid item labels. Row internals (owner spelling, non-empty
    /// payload) are enforced by the row decoder.
    static func decode(
        _ data: Data
    ) throws(EncryptedSecretsStoreError) -> [String: MCPEncryptedSecretsRow] {
        guard let document = try? JSONDecoder().decode(
            MCPEncryptedSecretsDocument.self, from: data
        ) else {
            throw .corruptDocument
        }
        guard document.version == 1 else {
            throw .corruptDocument
        }
        guard document.items.count <= maximumItems else {
            throw .corruptDocument
        }
        for id in document.items.keys {
            guard SecretLabels.isValidItem(id) else {
                throw .corruptDocument
            }
        }
        return document.items
    }

    /// Canonical encoding: version first, items sorted by id, no
    /// whitespace. Hand-written (never `JSONEncoder`) so no synthesized
    /// coder can hide an untested path and escaping stays total: item ids
    /// are escaped, payloads are base64-plus-dots and need no escaping.
    static func encode(items: [String: MCPEncryptedSecretsRow]) -> Data {
        var json = #"{"version":1,"items":{"#
        var first = true
        for (id, row) in items.sorted(by: { $0.key < $1.key }) {
            if first {
                first = false
            } else {
                json.append(",")
            }
            json.append("\"")
            appendEscaped(id, to: &json)
            json.append(#"":{"owner":""#)
            json.append(row.owner.rawValue)
            json.append(#"","payload":""#)
            json.append(row.payload)
            json.append(#""}"#)
        }
        json.append("}}")
        return Data(json.utf8)
    }

    /// Appends `value` with JSON string escaping: the short escapes plus
    /// `\u00XX` for the remaining C0 controls; everything else verbatim
    /// (Swift strings are valid Unicode by construction).
    static func appendEscaped(_ value: String, to json: inout String) {
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22:
                json.append("\\\"")
            case 0x5C:
                json.append("\\\\")
            case 0x08:
                json.append("\\b")
            case 0x09:
                json.append("\\t")
            case 0x0A:
                json.append("\\n")
            case 0x0C:
                json.append("\\f")
            case 0x0D:
                json.append("\\r")
            case 0x00..<0x20:
                let hex = String(scalar.value, radix: 16)
                json.append(hex.count == 1 ? "\\u000" + hex : "\\u00" + hex)
            default:
                json.append(Character(scalar))
            }
        }
    }

    /// Commits `bytes` over the live file. The directory must pass the
    /// owner-only trust check; when `expected` is present the live file
    /// must still be the file just read (`verifyIdentity`), otherwise a
    /// concurrent replacement aborts the write instead of being clobbered.
    /// Single attempt: every failure throws `storeUnwritable` and leaves
    /// the live file untouched.
    static func write(
        bytes: Data,
        expected: MCPEncryptedFileIdentity?,
        directory: URL
    ) throws(EncryptedSecretsStoreError) {
        let dirFd = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard dirFd >= 0 else {
            throw .storeUnwritable
        }
        defer { close(dirFd) }
        guard directoryIsTrusted(dirFd) else {
            throw .storeUnwritable
        }
        if let expected {
            guard OwnerOnlyFileWrite.verifyIdentity(
                fileName: fileName, inDirectory: dirFd,
                expectedDevice: expected.device, expectedInode: expected.inode
            ) else {
                throw .storeUnwritable
            }
        }
        guard let staged = OwnerOnlyFileWrite.stage(
            bytes: bytes, fileName: fileName, tag: "enc",
            inDirectory: dirFd, policy: .all, attempts: 8
        ) else {
            throw .storeUnwritable
        }
        defer { close(staged.fd) }
        guard OwnerOnlyFileWrite.commit(staged: staged, as: fileName, inDirectory: dirFd) else {
            throw .storeUnwritable
        }
    }

    /// Captures the live file's dev/ino, or nil when the directory or file
    /// cannot be opened. The `fstat` result is intentionally unchecked: it
    /// cannot fail on a just-opened fd, and a zeroed status can only
    /// mismatch `verifyIdentity` and abort the write — fail closed either
    /// way, with no dead branch.
    static func identityOfLiveFile(directory: URL) -> MCPEncryptedFileIdentity? {
        let dirFd = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard dirFd >= 0 else {
            return nil
        }
        defer { close(dirFd) }
        let fd = fileName.withCString {
            openat(dirFd, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else {
            return nil
        }
        defer { close(fd) }
        var status = stat()
        _ = fstat(fd, &status)
        return MCPEncryptedFileIdentity(
            device: UInt64(status.st_dev), inode: UInt64(status.st_ino)
        )
    }

    /// Owner-owned directory without group/other write, mirroring the read
    /// discipline. Single-expression form (see `identityOfLiveFile` for
    /// why `fstat` is unchecked): an attacker-writable directory could swap
    /// the temp file mid-write, so it fails closed before any staging.
    static func directoryIsTrusted(_ fd: Int32) -> Bool {
        var status = stat()
        _ = fstat(fd, &status)
        return status.st_uid == getuid() && (status.st_mode & 0o022) == 0
    }
}

/// Live-file identity for the pre-commit freshness check.
struct MCPEncryptedFileIdentity: Sendable, Equatable {
    var device: UInt64
    var inode: UInt64
}

/// In-process mutation lock. The box is shared by struct copies; the
/// `NSLock` (never a value-type lock) is what makes that sharing order
/// concurrent mutations.
final class MCPEncryptedStoreLock: @unchecked Sendable {
    private let lock = NSLock()

    func withLock<Value>(
        _ body: () throws(EncryptedSecretsStoreError) -> Value
    ) throws(EncryptedSecretsStoreError) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

// MARK: - Redacted description

/// Key material never prints: the derived `keyBytes` stay out of both
/// `description` and `debugDescription`, so crash reports, debug logs, and
/// test-failure output cannot carry them.
extension EncryptedSecretsProvider: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "EncryptedSecretsProvider(id: \"encrypted\", defaultOwner: \(defaultOwner))"
    }

    public var debugDescription: String {
        description
    }
}

// MARK: - Owner partition

/// Storage partition: org-shared or user-private. Alias for the shared
/// `MCPSecretsOwner` (RVDomain); the encrypted and WorkOS Vault
/// providers file under one partition type with one `embeddedOwner`.
public typealias MCPEncryptedSecretsOwner = MCPSecretsOwner

// MARK: - Errors and entries

/// Provider-construction failure. The master key is required; an empty
/// one fails loud, mirroring Executor's throwing plugin factory.
public enum EncryptedSecretsConfigError: Error, Sendable, Equatable {
    /// Empty master key: a secret store with no key is unsafe.
    case emptyMasterKey
}

/// Master-key load failure. Fixed labels only: the key file's bytes
/// and path never appear.
public enum EncryptedSecretsKeyLoadError: Error, Sendable, Equatable {
    /// `secret.key` is present but unusable (unsafe, unreadable,
    /// oversized, or non-UTF-8). Absence is `.success(nil)`, not this.
    case keyUnusable
}

/// Store-operation failure. Fixed labels only: item names and values
/// never appear.
public enum EncryptedSecretsStoreError: Error, Sendable, Equatable {
    /// Item label failed `SecretLabels` validation.
    case invalidItem
    /// Store file missing its trust or readability (absent directory or
    /// file loads empty instead — this is only the failure arms).
    case storeUnreadable
    /// Mutation could not land (caps, trust, contention, or IO). The live
    /// file is untouched.
    case storeUnwritable
    /// Store document failed structural validation.
    case corruptDocument
    /// Value failed authentication (wrong key or tampered bytes). Never
    /// serves wrong bytes.
    case decryptFailed
    /// Value could not be sealed (unusable key material). Production keys
    /// always seal; this arm is defense in depth.
    case encryptFailed
}

/// One listed secret: its id plus the partition it was filed under.
public struct MCPEncryptedSecretEntry: Sendable, Equatable {
    /// Opaque item id.
    public var id: String
    /// Partition the row was filed under.
    public var owner: MCPEncryptedSecretsOwner
}

// MARK: - Randomness

/// System randomness for IVs and minted master keys.
enum MCPRandom {
    /// `count` random bytes. Callers always pass a positive count.
    static func bytes(count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        var out = [UInt8]()
        out.reserveCapacity(count)
        for _ in 0..<count {
            out.append(UInt8(truncatingIfNeeded: generator.next()))
        }
        return out
    }
}

// MARK: - Payload envelope

/// `v1.<iv>.<tag>.<ct>` envelope, byte-identical to Executor: standard
/// padded base64 parts, 12-byte IV, 16-byte tag. Every malformed shape and
/// every authentication failure collapses to nil — Executor likewise
/// funnels wrong keys, tampered bytes, and bad base64/arity into one
/// decrypt failure. UTF-8 decoding is lossy like Node's
/// `Buffer.toString("utf8")`; authenticated bytes are always the original
/// valid UTF-8, so lossiness never alters a genuine value.
enum MCPEncryptedPayload {
    /// Envelope version. Only `v1` exists, on both sides.
    static let version = "v1"

    /// Seals `plaintext` under a fresh random 12-byte IV. Nil only when
    /// the key is unusable (never for derived keys).
    static func encrypt(key: [UInt8], plaintext: String) -> String? {
        encrypt(key: key, plaintext: plaintext, nonce: MCPRandom.bytes(count: 12))
    }

    /// Seals `plaintext` under an explicit IV. The deterministic form pins
    /// migration vectors; production always passes fresh randomness.
    static func encrypt(key: [UInt8], plaintext: String, nonce: [UInt8]) -> String? {
        guard let sealed = try? MCPAES256GCM.encrypt(
            key: key, nonce: nonce, plaintext: Array(plaintext.utf8)
        ) else {
            return nil
        }
        return [
            version,
            Data(nonce).base64EncodedString(),
            Data(sealed.tag).base64EncodedString(),
            Data(sealed.ciphertext).base64EncodedString(),
        ].joined(separator: ".")
    }

    /// Opens a payload, or nil on any failure: bad arity, bad version, bad
    /// base64, wrong IV/tag lengths, unusable key, or GCM authentication
    /// failure. Executor oracles: "round-trips through encrypt/decrypt",
    /// "a different key cannot decrypt", "tampered ciphertext fails the
    /// auth tag".
    static func decrypt(key: [UInt8], payload: String) -> String? {
        let parts = payload.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            return nil
        }
        guard parts[0] == version else {
            return nil
        }
        guard let iv = base64(parts[1]), iv.count == 12 else {
            return nil
        }
        guard let tag = base64(parts[2]), tag.count == 16 else {
            return nil
        }
        guard let ciphertext = base64(parts[3]) else {
            return nil
        }
        let authenticated: [UInt8]?
        do {
            authenticated = try MCPAES256GCM.decrypt(
                key: key, nonce: iv, ciphertext: ciphertext, tag: tag
            )
        } catch {
            return nil
        }
        guard let plain = authenticated else {
            return nil
        }
        return String(decoding: plain, as: UTF8.self)
    }

    /// Strict standard base64 (padded; anything else fails closed). The
    /// empty part is the empty ciphertext of an empty plaintext.
    static func base64(_ part: Substring) -> [UInt8]? {
        if part.isEmpty {
            return []
        }
        guard let data = Data(base64Encoded: String(part)) else {
            return nil
        }
        return Array(data)
    }
}

// MARK: - scrypt (RFC 7914)

/// Invalid scrypt parameters. One case: every guard below throws it.
enum MCPScryptError: Error, Sendable, Equatable {
    /// Parameters failed RFC 7914 shape validation.
    case invalidParameters
}

/// scrypt password-based key derivation (RFC 7914) over HMAC-SHA256 and
/// Salsa20/8. Parameters are validated once at construction, so
/// `derive` itself cannot fail; both PBKDF2 calls use the RFC's fixed
/// iteration count of 1.
enum MCPScrypt {
    /// Validated scrypt parameters. Each guard throws on its own invalid
    /// shape; bounds keep memory sane (`n * r` words of state).
    struct Parameters: Sendable, Equatable {
        /// CPU/memory cost (power of two).
        let n: Int
        /// Block size.
        let r: Int
        /// Parallelization.
        let p: Int
        /// Salt bytes.
        let salt: [UInt8]
        /// Derived-key length in bytes.
        let dkLen: Int

        init(n: Int, r: Int, p: Int, salt: [UInt8], dkLen: Int) throws(MCPScryptError) {
            guard n >= 2 else {
                throw .invalidParameters
            }
            guard n & (n - 1) == 0 else {
                throw .invalidParameters
            }
            guard n <= 1_048_576 else {
                throw .invalidParameters
            }
            guard r >= 1 else {
                throw .invalidParameters
            }
            guard r <= 256 else {
                throw .invalidParameters
            }
            guard p >= 1 else {
                throw .invalidParameters
            }
            guard p <= 256 else {
                throw .invalidParameters
            }
            guard dkLen >= 1 else {
                throw .invalidParameters
            }
            guard dkLen <= 1_048_576 else {
                throw .invalidParameters
            }
            guard n * r <= 1_048_576 else {
                throw .invalidParameters
            }
            self.n = n
            self.r = r
            self.p = p
            self.salt = salt
            self.dkLen = dkLen
        }

        /// Unchecked construction for the production constant only: the
        /// derivation KAT (pinned against Node) guards these values — any
        /// drift breaks it loudly.
        private init(uncheckedN n: Int, r: Int, p: Int, salt: [UInt8], dkLen: Int) {
            self.n = n
            self.r = r
            self.p = p
            self.salt = salt
            self.dkLen = dkLen
        }

        /// Executor derivation: N=16384, r=8, p=1, salt
        /// `executor-encrypted-secrets/v1`, 32 bytes.
        static let executorV1 = Parameters(
            uncheckedN: 16384, r: 8, p: 1,
            salt: Array("executor-encrypted-secrets/v1".utf8), dkLen: 32
        )
    }

    /// Executor `deriveKey`: master-key UTF-8 through `executorV1`.
    static func executorKey(masterKey: String) -> [UInt8] {
        derive(password: Array(masterKey.utf8), parameters: Parameters.executorV1)
    }

    /// RFC 7914 `scrypt(P, S, N, r, p, dkLen)`: PBKDF2, parallel ROMix,
    /// PBKDF2. Non-throwing: validated parameters keep every index and
    /// every allocation in bounds.
    static func derive(password: [UInt8], parameters: Parameters) -> [UInt8] {
        let blockLen = parameters.p * 128 * parameters.r
        var mixed = pbkdf2(password: password, salt: parameters.salt, dkLen: blockLen)
        let chunk = 128 * parameters.r
        for index in 0..<parameters.p {
            let window = index * chunk..<(index + 1) * chunk
            mixed.replaceSubrange(
                window, with: roMix(Array(mixed[window]), n: parameters.n, r: parameters.r)
            )
        }
        return pbkdf2(password: password, salt: mixed, dkLen: parameters.dkLen)
    }

    /// PBKDF2-HMAC-SHA256 with the RFC 7914 fixed iteration count of 1.
    static func pbkdf2(password: [UInt8], salt: [UInt8], dkLen: Int) -> [UInt8] {
        let blocks = (dkLen + 31) / 32
        var out = [UInt8]()
        out.reserveCapacity(blocks * 32)
        for index in 1...blocks {
            var message = salt
            message.append(UInt8((index >> 24) & 0xFF))
            message.append(UInt8((index >> 16) & 0xFF))
            message.append(UInt8((index >> 8) & 0xFF))
            message.append(UInt8(index & 0xFF))
            let round = hmac(key: password, message: message)
            out.append(contentsOf: round.prefix(dkLen - out.count))
        }
        return out
    }

    /// HMAC-SHA256 (RFC 2104 / RFC 4231).
    static func hmac(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var padded = key
        if padded.count > 64 {
            padded = sha256(padded)
        }
        padded += [UInt8](repeating: 0, count: 64 - padded.count)
        let inner = padded.map { $0 ^ 0x36 }
        let outer = padded.map { $0 ^ 0x5C }
        return sha256(outer + sha256(inner + message))
    }

    /// SHA-256 (FIPS 180-4).
    static func sha256(_ message: [UInt8]) -> [UInt8] {
        var hash: [UInt32] = [
            0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
            0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
        ]
        var padded = message
        let bitLength = UInt64(message.count) * 8
        padded.append(0x80)
        while padded.count % 64 != 56 {
            padded.append(0x00)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8((bitLength >> shift) & 0xFF))
        }
        for chunk in stride(from: 0, to: padded.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                words[index] = loadBE32(padded, chunk + index * 4)
            }
            for index in 16..<64 {
                let low = rotateRight(words[index - 15], 7)
                    ^ rotateRight(words[index - 15], 18) ^ (words[index - 15] >> 3)
                let high = rotateRight(words[index - 2], 17)
                    ^ rotateRight(words[index - 2], 19) ^ (words[index - 2] >> 10)
                words[index] = words[index - 16] &+ low &+ words[index - 7] &+ high
            }
            var a = hash[0]
            var b = hash[1]
            var c = hash[2]
            var d = hash[3]
            var e = hash[4]
            var f = hash[5]
            var g = hash[6]
            var h = hash[7]
            for index in 0..<64 {
                let s1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
                let choice = (e & f) ^ (~e & g)
                let t1 = h &+ s1 &+ choice &+ sha256RoundConstants[index] &+ words[index]
                let s0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ majority
                h = g
                g = f
                f = e
                e = d &+ t1
                d = c
                c = b
                b = a
                a = t1 &+ t2
            }
            hash[0] = hash[0] &+ a
            hash[1] = hash[1] &+ b
            hash[2] = hash[2] &+ c
            hash[3] = hash[3] &+ d
            hash[4] = hash[4] &+ e
            hash[5] = hash[5] &+ f
            hash[6] = hash[6] &+ g
            hash[7] = hash[7] &+ h
        }
        var out = [UInt8]()
        out.reserveCapacity(32)
        for word in hash {
            out.append(UInt8((word >> 24) & 0xFF))
            out.append(UInt8((word >> 16) & 0xFF))
            out.append(UInt8((word >> 8) & 0xFF))
            out.append(UInt8(word & 0xFF))
        }
        return out
    }

    /// `ROmix(B, N)`: fill `N` checkpoints, then `N` pseudo-random mixes.
    /// `n` is a validated power of two, so the mask keeps `j` in range.
    private static func roMix(_ input: [UInt8], n: Int, r: Int) -> [UInt8] {
        var checkpoints = [[UInt8]]()
        checkpoints.reserveCapacity(n)
        var mixed = input
        for _ in 0..<n {
            checkpoints.append(mixed)
            mixed = blockMix(mixed, r: r)
        }
        for _ in 0..<n {
            let probe = Int(loadLE32(mixed, (2 * r - 1) * 64) & UInt32(n - 1))
            for index in 0..<mixed.count {
                mixed[index] ^= checkpoints[probe][index]
            }
            mixed = blockMix(mixed, r: r)
        }
        return mixed
    }

    /// `BlockMix(B)`: Salsa20/8 chain over the `2r` 64-byte blocks, output
    /// even halves then odd halves.
    private static func blockMix(_ input: [UInt8], r: Int) -> [UInt8] {
        let blockCount = 2 * r
        var carry = Array(input[(blockCount - 1) * 64..<blockCount * 64])
        var mixed = [[UInt8]]()
        mixed.reserveCapacity(blockCount)
        for index in 0..<blockCount {
            let block = Array(input[index * 64..<(index + 1) * 64])
            for byte in 0..<64 {
                carry[byte] ^= block[byte]
            }
            carry = wordsToLEBytes(salsa20by8(leBytesToWords(carry)))
            mixed.append(carry)
        }
        var out = [UInt8]()
        out.reserveCapacity(input.count)
        for index in stride(from: 0, to: blockCount, by: 2) {
            out.append(contentsOf: mixed[index])
        }
        for index in stride(from: 1, to: blockCount, by: 2) {
            out.append(contentsOf: mixed[index])
        }
        return out
    }

    /// Salsa20/8 core: four double-rounds over 16 words, then the feed
    /// forward add. Column round, then row round, per double-round.
    private static func salsa20by8(_ input: [UInt32]) -> [UInt32] {
        var words = input
        for _ in 0..<4 {
            quarterRound(&words, 0, 4, 8, 12)
            quarterRound(&words, 5, 9, 13, 1)
            quarterRound(&words, 10, 14, 2, 6)
            quarterRound(&words, 15, 3, 7, 11)
            quarterRound(&words, 0, 1, 2, 3)
            quarterRound(&words, 5, 6, 7, 4)
            quarterRound(&words, 10, 11, 8, 9)
            quarterRound(&words, 15, 12, 13, 14)
        }
        var out = [UInt32](repeating: 0, count: 16)
        for index in 0..<16 {
            out[index] = words[index] &+ input[index]
        }
        return out
    }

    /// Salsa quarter-round on words `(a, b, c, d)` in place.
    private static func quarterRound(
        _ words: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int
    ) {
        words[b] ^= rotateLeft(words[a] &+ words[d], 7)
        words[c] ^= rotateLeft(words[b] &+ words[a], 9)
        words[d] ^= rotateLeft(words[c] &+ words[b], 13)
        words[a] ^= rotateLeft(words[d] &+ words[c], 18)
    }

    /// Little-endian 16-word view of a 64-byte block.
    private static func leBytesToWords(_ bytes: [UInt8]) -> [UInt32] {
        var words = [UInt32](repeating: 0, count: 16)
        for index in 0..<16 {
            words[index] = loadLE32(bytes, index * 4)
        }
        return words
    }

    /// Little-endian 64-byte view of 16 words.
    private static func wordsToLEBytes(_ words: [UInt32]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 64)
        for index in 0..<16 {
            let word = words[index]
            bytes[index * 4] = UInt8(word & 0xFF)
            bytes[index * 4 + 1] = UInt8((word >> 8) & 0xFF)
            bytes[index * 4 + 2] = UInt8((word >> 16) & 0xFF)
            bytes[index * 4 + 3] = UInt8((word >> 24) & 0xFF)
        }
        return bytes
    }

    /// Little-endian 32-bit load.
    private static func loadLE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    /// Big-endian 32-bit load (SHA-256 message schedule).
    private static func loadBE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    /// 32-bit left rotation.
    private static func rotateLeft(_ value: UInt32, _ count: Int) -> UInt32 {
        (value << count) | (value >> (32 - count))
    }

    /// 32-bit right rotation.
    private static func rotateRight(_ value: UInt32, _ count: Int) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }

    /// SHA-256 round constants (first 32 bits of the fractional parts of
    /// the cube roots of the first 64 primes).
    private static let sha256RoundConstants: [UInt32] = [
        0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1,
        0x923F82A4, 0xAB1C5ED5, 0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3,
        0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174, 0xE49B69C1, 0xEFBE4786,
        0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
        0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147,
        0x06CA6351, 0x14292967, 0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13,
        0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85, 0xA2BFE8A1, 0xA81A664B,
        0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
        0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A,
        0x5B9CCA4F, 0x682E6FF3, 0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208,
        0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
    ]
}

// MARK: - AES-256-GCM (FIPS 197 / SP 800-38D)

/// Malformed GCM inputs. Authentication failure is not an error case:
/// `decrypt` returns nil for a wrong tag.
enum MCPAES256GCMError: Error, Sendable, Equatable {
    /// Key is not 32 bytes.
    case invalidKeyLength
    /// Nonce is not 12 bytes.
    case invalidNonceLength
    /// Tag is not 16 bytes.
    case invalidTagLength
}

/// AES-256 in Galois/Counter Mode with a 12-byte nonce and empty AAD
/// (Executor passes no AAD). The forward block cipher is the only AES
/// direction GCM needs, so no inverse cipher exists here.
enum MCPAES256GCM {
    /// Encrypts under `key`/`nonce`, returning ciphertext plus tag.
    static func encrypt(
        key: [UInt8], nonce: [UInt8], plaintext: [UInt8]
    ) throws(MCPAES256GCMError) -> (ciphertext: [UInt8], tag: [UInt8]) {
        guard key.count == 32 else {
            throw .invalidKeyLength
        }
        guard nonce.count == 12 else {
            throw .invalidNonceLength
        }
        let roundKeys = expandKey(key)
        let ciphertext = cryptBlocks(roundKeys: roundKeys, nonce: nonce, input: plaintext)
        return (ciphertext: ciphertext, tag: authTag(
            roundKeys: roundKeys, nonce: nonce, ciphertext: ciphertext
        ))
    }

    /// Decrypts, or nil when the tag does not verify. The compare is
    /// constant-time; key/nonce/tag shape failures throw instead.
    static func decrypt(
        key: [UInt8], nonce: [UInt8], ciphertext: [UInt8], tag: [UInt8]
    ) throws(MCPAES256GCMError) -> [UInt8]? {
        guard key.count == 32 else {
            throw .invalidKeyLength
        }
        guard nonce.count == 12 else {
            throw .invalidNonceLength
        }
        guard tag.count == 16 else {
            throw .invalidTagLength
        }
        let roundKeys = expandKey(key)
        let expected = authTag(roundKeys: roundKeys, nonce: nonce, ciphertext: ciphertext)
        guard constantTimeEqual(expected, tag) else {
            return nil
        }
        return cryptBlocks(roundKeys: roundKeys, nonce: nonce, input: ciphertext)
    }

    /// Equality without early exit: length mismatch folds into the
    /// accumulator, so every call walks the shared prefix.
    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        var diff = a.count ^ b.count
        for index in 0..<min(a.count, b.count) {
            diff |= Int(a[index] ^ b[index])
        }
        return diff == 0
    }

    /// CTR transform shared by encrypt and decrypt: counter blocks
    /// `nonce || BE32(2), BE32(3), …` — the first block is `incr(J0)`,
    /// since `J0` itself (`…||1`) masks only the tag — keystream XOR in.
    private static func cryptBlocks(
        roundKeys: [[UInt8]], nonce: [UInt8], input: [UInt8]
    ) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(input.count)
        let blockCount = (input.count + 15) / 16
        for index in 0..<blockCount {
            var counter = nonce
            let number = UInt32(index + 2)
            counter.append(UInt8((number >> 24) & 0xFF))
            counter.append(UInt8((number >> 16) & 0xFF))
            counter.append(UInt8((number >> 8) & 0xFF))
            counter.append(UInt8(number & 0xFF))
            let keystream = encryptBlock(roundKeys, counter)
            let start = index * 16
            let end = min(start + 16, input.count)
            for position in start..<end {
                out.append(input[position] ^ keystream[position - start])
            }
        }
        return out
    }

    /// GCM tag: `GHASH(H, ct) ^ E(K, J0)` with `J0 = nonce || 1` and the
    /// all-zero-AAD length block.
    private static func authTag(
        roundKeys: [[UInt8]], nonce: [UInt8], ciphertext: [UInt8]
    ) -> [UInt8] {
        let hashKey = encryptBlock(roundKeys, [UInt8](repeating: 0, count: 16))
        let digest = ghash(hashKey, ciphertext)
        let mask = encryptBlock(roundKeys, nonce + [0x00, 0x00, 0x00, 0x01])
        var tag = [UInt8]()
        tag.reserveCapacity(16)
        for index in 0..<16 {
            tag.append(digest[index] ^ mask[index])
        }
        return tag
    }

    /// `GHASH(H, ct)`: accumulate each zero-padded ciphertext block, then
    /// the length block, multiplying by `H` in GF(2^128) after each.
    private static func ghash(_ hashKey: [UInt8], _ ciphertext: [UInt8]) -> [UInt8] {
        var state = [UInt8](repeating: 0, count: 16)
        for offset in stride(from: 0, to: ciphertext.count, by: 16) {
            var block = Array(ciphertext[offset..<min(offset + 16, ciphertext.count)])
            block += [UInt8](repeating: 0, count: 16 - block.count)
            for index in 0..<16 {
                state[index] ^= block[index]
            }
            state = gfMultiply(state, hashKey)
        }
        var lengths = [UInt8](repeating: 0, count: 8)
        let bits = UInt64(ciphertext.count) * 8
        for shift in stride(from: 56, through: 0, by: -8) {
            lengths.append(UInt8((bits >> shift) & 0xFF))
        }
        for index in 0..<16 {
            state[index] ^= lengths[index]
        }
        return gfMultiply(state, hashKey)
    }

    /// GF(2^128) multiply (SP 800-38D, big-endian bit order): shift-add
    /// with the `x^128 + x^7 + x^2 + x + 1` reduction on overflow.
    private static func gfMultiply(_ x: [UInt8], _ y: [UInt8]) -> [UInt8] {
        var product = [UInt8](repeating: 0, count: 16)
        var factor = y
        for bit in 0..<128 {
            if (x[bit >> 3] >> (7 - (bit & 7))) & 1 == 1 {
                for index in 0..<16 {
                    product[index] ^= factor[index]
                }
            }
            let overflow = factor[15] & 1
            var carry: UInt8 = 0
            for index in 0..<16 {
                let next = factor[index] & 1
                factor[index] = (factor[index] >> 1) | (carry << 7)
                carry = next
            }
            if overflow == 1 {
                factor[0] ^= 0xE1
            }
        }
        return product
    }

    /// AES-256 forward block cipher: 14 rounds, column-major state.
    private static func encryptBlock(_ roundKeys: [[UInt8]], _ input: [UInt8]) -> [UInt8] {
        var state = input
        addRoundKey(&state, roundKeys[0])
        for round in 1..<14 {
            subBytes(&state)
            shiftRows(&state)
            mixColumns(&state)
            addRoundKey(&state, roundKeys[round])
        }
        subBytes(&state)
        shiftRows(&state)
        addRoundKey(&state, roundKeys[14])
        return state
    }

    /// AES-256 key expansion: 32 bytes to 15 16-byte round keys.
    private static func expandKey(_ key: [UInt8]) -> [[UInt8]] {
        var words = [UInt32](repeating: 0, count: 60)
        for index in 0..<8 {
            words[index] = (UInt32(key[index * 4]) << 24)
                | (UInt32(key[index * 4 + 1]) << 16)
                | (UInt32(key[index * 4 + 2]) << 8)
                | UInt32(key[index * 4 + 3])
        }
        for index in 8..<60 {
            var temp = words[index - 1]
            if index % 8 == 0 {
                temp = subWord(rotateWord(temp)) ^ roundConstants[index / 8 - 1]
            } else if index % 8 == 4 {
                temp = subWord(temp)
            }
            words[index] = words[index - 8] ^ temp
        }
        var roundKeys = [[UInt8]]()
        roundKeys.reserveCapacity(15)
        for round in 0..<15 {
            var bytes = [UInt8]()
            bytes.reserveCapacity(16)
            for column in 0..<4 {
                let word = words[round * 4 + column]
                bytes.append(UInt8((word >> 24) & 0xFF))
                bytes.append(UInt8((word >> 16) & 0xFF))
                bytes.append(UInt8((word >> 8) & 0xFF))
                bytes.append(UInt8(word & 0xFF))
            }
            roundKeys.append(bytes)
        }
        return roundKeys
    }

    /// Byte substitution through the S-box.
    private static func subBytes(_ state: inout [UInt8]) {
        for index in 0..<16 {
            state[index] = sBox[Int(state[index])]
        }
    }

    /// Row shifts: row `r` rotates left by `r`.
    private static func shiftRows(_ state: inout [UInt8]) {
        let original = state
        state[1] = original[5]
        state[5] = original[9]
        state[9] = original[13]
        state[13] = original[1]
        state[2] = original[10]
        state[6] = original[14]
        state[10] = original[2]
        state[14] = original[6]
        state[3] = original[15]
        state[7] = original[3]
        state[11] = original[7]
        state[15] = original[11]
    }

    /// Column mix over GF(2^8).
    private static func mixColumns(_ state: inout [UInt8]) {
        for column in 0..<4 {
            let base = column * 4
            let a = state[base]
            let b = state[base + 1]
            let c = state[base + 2]
            let d = state[base + 3]
            state[base] = mul2(a) ^ mul3(b) ^ c ^ d
            state[base + 1] = a ^ mul2(b) ^ mul3(c) ^ d
            state[base + 2] = a ^ b ^ mul2(c) ^ mul3(d)
            state[base + 3] = mul3(a) ^ b ^ c ^ mul2(d)
        }
    }

    /// XOR the round key into the state.
    private static func addRoundKey(_ state: inout [UInt8], _ roundKey: [UInt8]) {
        for index in 0..<16 {
            state[index] ^= roundKey[index]
        }
    }

    /// 4-byte rotate: `(a, b, c, d)` to `(b, c, d, a)`.
    private static func rotateWord(_ word: UInt32) -> UInt32 {
        (word << 8) | (word >> 24)
    }

    /// S-box over each of the word's four bytes.
    private static func subWord(_ word: UInt32) -> UInt32 {
        (UInt32(sBox[Int((word >> 24) & 0xFF)]) << 24)
            | (UInt32(sBox[Int((word >> 16) & 0xFF)]) << 16)
            | (UInt32(sBox[Int((word >> 8) & 0xFF)]) << 8)
            | UInt32(sBox[Int(word & 0xFF)])
    }

    /// GF(2^8) doubling.
    private static func mul2(_ value: UInt8) -> UInt8 {
        (value << 1) ^ ((value & 0x80) == 0 ? 0x00 : 0x1B)
    }

    /// GF(2^8) multiply by three.
    private static func mul3(_ value: UInt8) -> UInt8 {
        mul2(value) ^ value
    }

    /// AES round constants.
    private static let roundConstants: [UInt32] = [
        0x01000000, 0x02000000, 0x04000000, 0x08000000, 0x10000000,
        0x20000000, 0x40000000, 0x80000000, 0x1B000000, 0x36000000,
    ]

    /// AES substitution box.
    private static let sBox: [UInt8] = [
        0x63, 0x7C, 0x77, 0x7B, 0xF2, 0x6B, 0x6F, 0xC5,
        0x30, 0x01, 0x67, 0x2B, 0xFE, 0xD7, 0xAB, 0x76,
        0xCA, 0x82, 0xC9, 0x7D, 0xFA, 0x59, 0x47, 0xF0,
        0xAD, 0xD4, 0xA2, 0xAF, 0x9C, 0xA4, 0x72, 0xC0,
        0xB7, 0xFD, 0x93, 0x26, 0x36, 0x3F, 0xF7, 0xCC,
        0x34, 0xA5, 0xE5, 0xF1, 0x71, 0xD8, 0x31, 0x15,
        0x04, 0xC7, 0x23, 0xC3, 0x18, 0x96, 0x05, 0x9A,
        0x07, 0x12, 0x80, 0xE2, 0xEB, 0x27, 0xB2, 0x75,
        0x09, 0x83, 0x2C, 0x1A, 0x1B, 0x6E, 0x5A, 0xA0,
        0x52, 0x3B, 0xD6, 0xB3, 0x29, 0xE3, 0x2F, 0x84,
        0x53, 0xD1, 0x00, 0xED, 0x20, 0xFC, 0xB1, 0x5B,
        0x6A, 0xCB, 0xBE, 0x39, 0x4A, 0x4C, 0x58, 0xCF,
        0xD0, 0xEF, 0xAA, 0xFB, 0x43, 0x4D, 0x33, 0x85,
        0x45, 0xF9, 0x02, 0x7F, 0x50, 0x3C, 0x9F, 0xA8,
        0x51, 0xA3, 0x40, 0x8F, 0x92, 0x9D, 0x38, 0xF5,
        0xBC, 0xB6, 0xDA, 0x21, 0x10, 0xFF, 0xF3, 0xD2,
        0xCD, 0x0C, 0x13, 0xEC, 0x5F, 0x97, 0x44, 0x17,
        0xC4, 0xA7, 0x7E, 0x3D, 0x64, 0x5D, 0x19, 0x73,
        0x60, 0x81, 0x4F, 0xDC, 0x22, 0x2A, 0x90, 0x88,
        0x46, 0xEE, 0xB8, 0x14, 0xDE, 0x5E, 0x0B, 0xDB,
        0xE0, 0x32, 0x3A, 0x0A, 0x49, 0x06, 0x24, 0x5C,
        0xC2, 0xD3, 0xAC, 0x62, 0x91, 0x95, 0xE4, 0x79,
        0xE7, 0xC8, 0x37, 0x6D, 0x8D, 0xD5, 0x4E, 0xA9,
        0x6C, 0x56, 0xF4, 0xEA, 0x65, 0x7A, 0xAE, 0x08,
        0xBA, 0x78, 0x25, 0x2E, 0x1C, 0xA6, 0xB4, 0xC6,
        0xE8, 0xDD, 0x74, 0x1F, 0x4B, 0xBD, 0x8B, 0x8A,
        0x70, 0x3E, 0xB5, 0x66, 0x48, 0x03, 0xF6, 0x0E,
        0x61, 0x35, 0x57, 0xB9, 0x86, 0xC1, 0x1D, 0x9E,
        0xE1, 0xF8, 0x98, 0x11, 0x69, 0xD9, 0x8E, 0x94,
        0x9B, 0x1E, 0x87, 0xE9, 0xCE, 0x55, 0x28, 0xDF,
        0x8C, 0xA1, 0x89, 0x0D, 0xBF, 0xE6, 0x42, 0x68,
        0x41, 0x99, 0x2D, 0x0F, 0xB0, 0x54, 0xBB, 0x16,
    ]
}
