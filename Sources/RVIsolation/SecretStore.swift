#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(Security)
import Security
#endif
import Foundation
import RVDomain

extension SecretSource {
    /// Where the value lives, safe to print. Never the value.
    public var locator: String {
        switch self {
        case .keychain(let service, let account):
            "keychain \(DisplayedText.field(service))/\(DisplayedText.field(account))"
        case .hostEnvironment(let variable): "host $\(DisplayedText.field(variable))"
        case .onePassword(let reference): DisplayedText.field(reference)
        case .vault(let path, let field, let address):
            "vault \(address.map { "\($0.host ?? "")/" } ?? "")\(DisplayedText.field(path))#\(DisplayedText.field(field))"
        case .awsSecretsManager(let secretID, let field, let region):
            "aws \(region.map { "\(DisplayedText.field($0)):" } ?? "")\(DisplayedText.field(secretID))\(field.map { "#\(DisplayedText.field($0))" } ?? "")"
        }
    }
}

extension SecretDelivery {
    public var summary: String {
        switch self {
        case .gateway(let binding): "gateway → \(binding.upstream.host ?? binding.upstream.absoluteString) via $\(binding.baseURLEnv)"
        case .environment: "environment (real value in the cage)"
        }
    }
}

/// Values rv itself stores live in the login Keychain under this service.
public enum SecretKeychain {
    public static let service = "rv.secrets"
}

/// Keychain writes for `rv secrets set|remove`. Tests inject fakes.
public struct SecretKeychainWriter: Sendable {
    public var store: @Sendable (_ service: String, _ account: String, _ value: Data) -> Bool
    /// True when the item is gone afterwards (deleted or never present).
    public var delete: @Sendable (_ service: String, _ account: String) -> Bool

    public init(
        store: @escaping @Sendable (String, String, Data) -> Bool,
        delete: @escaping @Sendable (String, String) -> Bool
    ) {
        self.store = store
        self.delete = delete
    }

    #if canImport(Security)
    public static let live = SecretKeychainWriter(
        store: { service, account, value in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            let update: [String: Any] = [kSecValueData as String: value]
            switch SecItemUpdate(query as CFDictionary, update as CFDictionary) {
            case errSecSuccess:
                return true
            case errSecItemNotFound:
                var add = query
                add[kSecValueData as String] = value
                add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
                return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
            default:
                return false
            }
        },
        delete: { service, account in
            let status = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
    )
    #else
    public static let live = SecretKeychainWriter(store: { _, _, _ in false }, delete: { _, _ in false })
    #endif
}

extension SecretFingerprinter {
    public func fingerprint(of value: SecretValue) -> String {
        fingerprint(value)
    }
}

extension SecretsConfiguration {
    /// Canonical JSON for this configuration; round-trips through `decode`.
    public func encoded() -> Data {
        let entries: [[String: Any]] = secrets.map { secret in
            var entry: [String: Any] = ["name": secret.name]
            if let description = secret.description { entry["description"] = description }
            if let agents = secret.agents { entry["agents"] = agents }
            switch secret.source {
            case .keychain(let service, let account):
                entry["source"] = ["keychain": ["service": service, "account": account]]
            case .hostEnvironment(let variable):
                entry["source"] = ["hostEnvironment": ["variable": variable]]
            case .onePassword(let reference):
                entry["source"] = ["onePassword": ["reference": reference]]
            case .vault(let path, let field, let address):
                var fields: [String: Any] = ["path": path, "field": field]
                if let address { fields["address"] = address.absoluteString }
                entry["source"] = ["vault": fields]
            case .awsSecretsManager(let secretID, let field, let region):
                var fields: [String: Any] = ["secretID": secretID]
                if let field { fields["field"] = field }
                if let region { fields["region"] = region }
                entry["source"] = ["awsSecretsManager": fields]
            }
            switch secret.delivery {
            case .environment:
                entry["delivery"] = ["environment": [String: Any]()]
            case .gateway(let binding):
                var fields: [String: Any] = [
                    "upstream": binding.upstream.absoluteString, "baseURLEnv": binding.baseURLEnv,
                ]
                if binding.placeholderPrefix.isEmpty == false { fields["placeholderPrefix"] = binding.placeholderPrefix }
                entry["delivery"] = ["gateway": fields]
            }
            return entry
        }
        let document: [String: Any] = ["version": 1, "secrets": entries]
        let data = (try? JSONSerialization.data(
            withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return data + Data("\n".utf8)
    }

    /// Validates, then atomically replaces secrets.json (0600, owner-only directory).
    public func write(configDirectory: URL) -> Result<Void, SecretsConfigurationError> {
        let data = encoded()
        if case .failure(let error) = Self.decode(data) { return .failure(error) }
        guard OwnerOnlyFile.write(data, to: Self.fileURL(configDirectory: configDirectory)) else {
            return .failure(.unreadable)
        }
        return .success(())
    }
}

/// One place a resolvable secret value appears in a tree.
public struct SecretLeakFinding: Sendable, Equatable, Codable {
    public var path: String
    public var line: Int
    public var secret: String

    public init(path: String, line: Int, secret: String) {
        self.path = path
        self.line = line
        self.secret = secret
    }
}

/// Exact-match scan for known secret values. Reports locations, never values.
public enum SecretLeakScanner {
    public static let minimumValueBytes = 8
    public static let maximumFileBytes = 8 * 1024 * 1024
    public static let maximumFiles = 100_000
    static let skippedDirectories: Set<String> = [".git", ".build", "node_modules", "DerivedData"]

    public static func scan(root unresolved: URL, secrets: [(name: String, value: SecretValue)]) -> [SecretLeakFinding] {
        let root = unresolved.resolvingSymlinksInPath()
        let needles = secrets.filter { $0.value.bytes.count >= minimumValueBytes }
        guard needles.isEmpty == false,
            let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
                options: [])
        else { return [] }
        var findings: [SecretLeakFinding] = []
        var visited = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true, (values?.fileSize ?? 0) <= maximumFileBytes else { continue }
            visited += 1
            if visited > maximumFiles { break }
            guard let data = try? Data(contentsOf: url) else { continue }
            let bytes = [UInt8](data)
            let path = url.resolvingSymlinksInPath().path
            let relative = path.hasPrefix(root.path + "/") ? String(path.dropFirst(root.path.count + 1)) : path
            for needle in needles {
                for offset in occurrences(of: needle.value.bytes, in: bytes) {
                    let line = bytes[..<offset].reduce(1) { $1 == 10 ? $0 + 1 : $0 }
                    findings.append(SecretLeakFinding(path: relative, line: line, secret: needle.name))
                }
            }
        }
        return findings.sorted { ($0.path, $0.line, $0.secret) < ($1.path, $1.line, $1.secret) }
    }

    static func occurrences(of needle: [UInt8], in haystack: [UInt8]) -> [Int] {
        guard needle.isEmpty == false, haystack.count >= needle.count else { return [] }
        var found: [Int] = []
        var index = 0
        let first = needle[0]
        while index <= haystack.count - needle.count {
            if haystack[index] == first, haystack[index..<index + needle.count].elementsEqual(needle) {
                found.append(index)
                index += needle.count
            } else {
                index += 1
            }
        }
        return found
    }
}
