#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVFileStore

public enum SecretsProviderStoreError: Error, Sendable, Equatable {
    case unsafeLocation
    case unreadable
    case oversized
    case invalidDocument
    case unsupportedVersion
}

/// One named provider binding: which broker provider backs `name` and
/// which item (plus optional field) it resolves. Refs only; the file
/// never carries secret material.
public struct ProviderBinding: Sendable, Equatable {
    public let name: String
    public let provider: String
    public let item: String
    public let field: String?

    public init(name: String, provider: String, item: String, field: String? = nil) {
        self.name = name
        self.provider = provider
        self.item = item
        self.field = field
    }

    /// The broker ref this binding names, or nil when the provider is
    /// unknown or the item is empty. Mirrors the store's allowlist so
    /// unvalidated bindings fail closed here too.
    public var ref: SecretRef? {
        try? SecretRef(provider: provider, item: item, field: field)
    }
}

/// Validated provider bindings loaded from `secrets-providers.json`.
public struct SecretsProviderBindings: Sendable, Equatable {
    public let bindings: [ProviderBinding]

    public init(bindings: [ProviderBinding]) {
        self.bindings = bindings
    }

    public static let empty = SecretsProviderBindings(bindings: [])

    /// Binding named `name`, or nil when no binding carries that name.
    public func binding(named name: String) -> ProviderBinding? {
        bindings.first { $0.name == name }
    }
}

/// Loads trusted operator provider bindings from `secrets-providers.json`.
///
/// Bindings come ONLY from this operator config file, under the same
/// owner-only, no-symlink, 64KB discipline as the sibling stores. Every
/// binding names a provider from `SecretRef.allowedProviders`; unknown
/// providers fail closed. Every failure mode fails closed.
public enum SecretsProviderStore {
    public static let maximumBytes = 65_536
    public static let maximumBindings = 32
    public static let fileName = "secrets-providers.json"

    public static func load(from configDirectory: URL) -> Result<SecretsProviderBindings, SecretsProviderStoreError> {
        switch OwnerOnlyFile.loadBytes(
            fileName: fileName, from: configDirectory, maximumBytes: maximumBytes
        ) {
        case .success(let data):
            return decode(data)
        case .failure(.missing):
            return .success(.empty)
        case .failure(.inaccessible), .failure(.unsafeLocation):
            return .failure(.unsafeLocation)
        case .failure(.unreadable):
            return .failure(.unreadable)
        case .failure(.oversized):
            return .failure(.oversized)
        }
    }

    public static func decode(_ data: Data) -> Result<SecretsProviderBindings, SecretsProviderStoreError> {
        guard data.count <= maximumBytes else { return .failure(.oversized) }
        guard let document = try? JSONDecoder().decode(ProviderBindingsDocument.self, from: data) else {
            return .failure(.invalidDocument)
        }
        guard document.version == 1 else { return .failure(.unsupportedVersion) }
        guard document.bindings.count <= maximumBindings else { return .failure(.invalidDocument) }
        var seen = Set<String>()
        var bindings: [ProviderBinding] = []
        for dto in document.bindings {
            guard bindingName(dto.name), seen.insert(dto.name).inserted,
                SecretRef.allowedProviders.contains(dto.provider),
                SecretLabels.isValidItem(dto.item), dto.field.map(SecretLabels.isValidField) ?? true
            else {
                return .failure(.invalidDocument)
            }
            bindings.append(
                ProviderBinding(name: dto.name, provider: dto.provider, item: dto.item, field: dto.field)
            )
        }
        return .success(SecretsProviderBindings(bindings: bindings))
    }

    /// Binding names share the credential-binding charset: short,
    /// portable identifiers with no whitespace or control bytes.
    private static func bindingName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }
}

/// Atomic best-effort rewrite of a migrated owner-only JSON document.
///
/// The v1 migration rewrites normalize old documents in place. The rewrite
/// must neither corrupt the file nor follow a swapped path, so it re-checks
/// the live file against the just-read identity, stages the bytes in a 0600
/// temp file, and renames over the original. Every failure returns false
/// and leaves the original untouched: the load already succeeded and the
/// document stays readable without the rewrite.
enum MigratedDocumentRewrite {
    /// Rewrites `fileName` under the already-open `directory` with `bytes`
    /// when the live file is still the file the caller just read
    /// (`expectedDevice`/`expectedInode` from its fstat). Returns whether
    /// the rewrite landed.
    static func rewrite(
        fileName: String,
        inDirectory directory: Int32,
        expectedDevice: UInt64,
        expectedInode: UInt64,
        bytes: Data
    ) -> Bool {
        // The live file must still be the one the caller validated: a
        // concurrent swap aborts the rewrite instead of clobbering it.
        // Deliberate divergences from the sink staging, preserved: the
        // dev/ino recheck plus the retrying loop (`.all`, eight attempts
        // with `EEXIST` retry).
        guard OwnerOnlyFileWrite.verifyIdentity(
            fileName: fileName, inDirectory: directory,
            expectedDevice: expectedDevice, expectedInode: expectedInode
        ) else {
            return false
        }
        guard let staged = OwnerOnlyFileWrite.stage(
            bytes: bytes, fileName: fileName, tag: "migrate",
            inDirectory: directory, policy: .all, attempts: 8
        ) else {
            return false
        }
        defer { close(staged.fd) }
        return OwnerOnlyFileWrite.commit(staged: staged, as: fileName, inDirectory: directory)
    }
}

/// Temporary alias: tests pin the historical name; new code uses `StrictJSONKey`.
typealias ProviderStrictKey = StrictJSONKey

/// Versioned operator document. The key sets below are closed: unknown
/// fields fail closed, so a security-critical field RV does not understand
/// (or a secret value smuggled under any name) can never slip through.
/// Bindings name refs only, never secret values.
private struct ProviderBindingsDocument: Decodable {
    let version: Int
    let bindings: [ProviderBindingDTO]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(container, allowed: ["version", "bindings"])
        version = try container.decode(Int.self, forKey: StrictJSONKey("version"))
        bindings = try container.decode([ProviderBindingDTO].self, forKey: StrictJSONKey("bindings"))
    }
}

private struct ProviderBindingDTO: Decodable {
    let name: String
    let provider: String
    let item: String
    let field: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(
            container, allowed: ["name", "provider", "item", "field"]
        )
        name = try container.decode(String.self, forKey: StrictJSONKey("name"))
        provider = try container.decode(String.self, forKey: StrictJSONKey("provider"))
        item = try container.decode(String.self, forKey: StrictJSONKey("item"))
        field = try container.decodeIfPresent(String.self, forKey: StrictJSONKey("field"))
    }
}
