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
import RVPolicy

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
        case .infisical(let name, let project, let environment, let path):
            "infisical \(project.map { "\($0)/" } ?? "")\(environment.map { "\($0):" } ?? "")\(name)\(path.map { " \($0)" } ?? "")"
        case .bitwarden(let id): "bitwarden \(id)"
        case .gcp(let secret, let project, let version):
            "gcp \(project.map { "\($0)/" } ?? "")\(secret)@\(version)"
        case .azure(let vault, let name, let version):
            "azure \(vault)/\(name)\(version.map { "@\($0)" } ?? "")"
        case .awsProfile(let profile): "aws profile \(DisplayedText.field(profile))"
        case .oauth(let oauth):
            "oauth \(oauth.refreshToken == nil ? "client credentials" : "refresh token") at \(oauth.tokenURL.host ?? "")"
        }
    }
}

extension SecretDelivery {
    public var summary: String {
        switch self {
        case .gateway(let binding): "gateway → \(binding.upstream.host ?? binding.upstream.absoluteString) via $\(binding.baseURLEnv)"
        case .environment: "environment (real value in the cage)"
        case .awsSigV4(let binding):
            "AWS SigV4 → \(binding.upstream.host ?? binding.upstream.absoluteString) "
                + "(\(binding.service), \(binding.region)) via $\(binding.endpointEnv)"
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
            if let type = secret.type { entry["type"] = type }
            if let agents = secret.agents { entry["agents"] = agents }
            if let expires = secret.expires { entry["expires"] = SecretExpiry.text(expires) }
            if let refresh = secret.refresh { entry["refresh"] = refresh.text }
            if let binaries = secret.binaries { entry["binaries"] = binaries }
            let sourceKind = secret.source.kind.rawValue
            switch secret.source {
            case .keychain(let service, let account):
                entry["source"] = [sourceKind: ["service": service, "account": account]]
            case .hostEnvironment(let variable):
                entry["source"] = [sourceKind: ["variable": variable]]
            case .onePassword(let reference):
                entry["source"] = [sourceKind: ["reference": reference]]
            case .vault(let path, let field, let address):
                var fields: [String: Any] = ["path": path, "field": field]
                if let address { fields["address"] = address.absoluteString }
                entry["source"] = [sourceKind: fields]
            case .awsSecretsManager(let secretID, let field, let region):
                var fields: [String: Any] = ["secretID": secretID]
                if let field { fields["field"] = field }
                if let region { fields["region"] = region }
                entry["source"] = [sourceKind: fields]
            case .infisical(let name, let project, let environment, let path):
                var fields: [String: Any] = ["name": name]
                if let project { fields["project"] = project }
                if let environment { fields["environment"] = environment }
                if let path { fields["path"] = path }
                entry["source"] = [sourceKind: fields]
            case .bitwarden(let id):
                entry["source"] = [sourceKind: ["id": id]]
            case .gcp(let secret, let project, let version):
                var fields: [String: Any] = ["secret": secret, "version": version]
                if let project { fields["project"] = project }
                entry["source"] = [sourceKind: fields]
            case .azure(let vault, let name, let version):
                var fields: [String: Any] = ["vault": vault, "name": name]
                if let version { fields["version"] = version }
                entry["source"] = [sourceKind: fields]
            case .awsProfile(let profile):
                entry["source"] = [sourceKind: ["profile": profile]]
            case .oauth(let oauth):
                var fields: [String: Any] = ["tokenURL": oauth.tokenURL.absoluteString, "clientID": oauth.clientID]
                if let item = oauth.clientSecret { fields["clientSecret"] = ["service": item.service, "account": item.account] }
                if let item = oauth.refreshToken { fields["refreshToken"] = ["service": item.service, "account": item.account] }
                if let scope = oauth.scope { fields["scope"] = scope }
                entry["source"] = [sourceKind: fields]
            }
            func allowList(_ allow: [GatewayAllowance]) -> [Any] {
                allow.map { allowance -> Any in
                    switch allowance {
                    case .preset(let preset): return preset.rawValue
                    case .rule(let rule):
                        return ["methods": rule.methods.map { $0.sorted() as Any } ?? "*", "path": rule.path]
                    }
                }
            }
            switch secret.delivery {
            case .environment:
                entry["delivery"] = ["environment": [String: Any]()]
            case .gateway(let binding):
                var fields: [String: Any] = [
                    "upstream": binding.upstream.absoluteString, "baseURLEnv": binding.baseURLEnv,
                ]
                if binding.placeholderPrefix.isEmpty == false { fields["placeholderPrefix"] = binding.placeholderPrefix }
                if binding.surfaces != GatewaySurface.defaults {
                    fields["surfaces"] = GatewaySurface.ordered(binding.surfaces).map(\.rawValue)
                }
                if binding.allow.isEmpty == false { fields["allow"] = allowList(binding.allow) }
                if binding.approve.isEmpty == false { fields["approve"] = allowList(binding.approve) }
                entry["delivery"] = ["gateway": fields]
            case .awsSigV4(let binding):
                var fields: [String: Any] = [
                    "upstream": binding.upstream.absoluteString, "region": binding.region,
                    "service": binding.service, "endpointEnv": binding.endpointEnv,
                ]
                if binding.allow.isEmpty == false { fields["allow"] = allowList(binding.allow) }
                if binding.approve.isEmpty == false { fields["approve"] = allowList(binding.approve) }
                entry["delivery"] = ["awsSigV4": fields]
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

/// One place a secret appears. `secret` is the secret's name for an
/// exact-value match, or the built-in rule id for a pattern match.
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

/// Findings plus the files that were too large to read, so an oversized
/// file is reported rather than passed silently.
public struct SecretLeakReport: Sendable, Equatable {
    public var findings: [SecretLeakFinding]
    public var tooLarge: [String]

    public init(findings: [SecretLeakFinding], tooLarge: [String]) {
        self.findings = findings
        self.tooLarge = tooLarge
    }
}

/// `.rv-secrets-ignore`: one `path:rule:line` fingerprint per line, `#`
/// comments. Suppresses pattern findings only; an exact match of a value rv
/// resolves is always a leak.
public struct SecretLeakIgnore: Sendable, Equatable {
    public static let fileName = ".rv-secrets-ignore"
    let fingerprints: Set<String>

    public init(text: String) {
        fingerprints = Set(text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed.hasPrefix("#") ? nil : trimmed
        })
    }

    /// The ignore file at `directory`, or an empty list.
    public static func load(from directory: URL) -> SecretLeakIgnore {
        let url = directory.appendingPathComponent(fileName)
        return SecretLeakIgnore(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    func ignores(path: String, rule: String, line: Int) -> Bool {
        fingerprints.contains("\(path):\(rule):\(line)")
    }
}

/// Exact-match scan for known secret values plus built-in token-shape rules.
/// Reports locations, never values.
public enum SecretLeakScanner {
    public static let minimumValueBytes = 8
    public static let maximumFileBytes = 8 * 1024 * 1024
    public static let maximumFiles = 100_000
    /// Binary sniffing window, as git uses for its own text/binary guess.
    static let binarySniffBytes = 8000
    static let skippedDirectories: Set<String> = [".git", ".build", "node_modules", "DerivedData"]

    public static func scan(root unresolved: URL, secrets: [(name: String, value: SecretValue)]) -> SecretLeakReport {
        let root = unresolved.resolvingSymlinksInPath()
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey], options: [])
        else { return SecretLeakReport(findings: [], tooLarge: []) }
        let needles = secrets.filter { $0.value.bytes.count >= minimumValueBytes }
        let rules = SecretPatternRules.compiled()
        let ignore = SecretLeakIgnore.load(from: root)
        var findings: [SecretLeakFinding] = []
        var tooLarge: [String] = []
        var visited = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().path
            let relative = path.hasPrefix(root.path + "/") ? String(path.dropFirst(root.path.count + 1)) : path
            guard (values?.fileSize ?? 0) <= maximumFileBytes else {
                tooLarge.append(relative)
                continue
            }
            visited += 1
            if visited > maximumFiles { break }
            guard let data = try? Data(contentsOf: url) else { continue }
            findings += scan(path: relative, bytes: [UInt8](data), needles: needles, rules: rules, ignore: ignore)
        }
        return SecretLeakReport(findings: sorted(findings), tooLarge: tooLarge.sorted())
    }

    /// Scans buffers already in memory, such as staged blobs, so nothing
    /// has to be written to disk first.
    public static func scan(
        files: [(path: String, bytes: [UInt8])], secrets: [(name: String, value: SecretValue)], ignore: SecretLeakIgnore
    ) -> [SecretLeakFinding] {
        let needles = secrets.filter { $0.value.bytes.count >= minimumValueBytes }
        let rules = SecretPatternRules.compiled()
        let findings = files.flatMap { scan(path: $0.path, bytes: $0.bytes, needles: needles, rules: rules, ignore: ignore) }
        return sorted(findings)
    }

    static func scan(
        path: String, bytes: [UInt8], needles: [(name: String, value: SecretValue)], rules: [SecretPatternRule],
        ignore: SecretLeakIgnore
    ) -> [SecretLeakFinding] {
        var index: LineIndex?
        func line(at offset: Int) -> Int {
            let built = index ?? LineIndex(bytes: bytes)
            index = built
            return built.line(at: offset)
        }
        var findings: [SecretLeakFinding] = []
        for needle in needles {
            for offset in occurrences(of: needle.value.bytes, in: bytes) {
                findings.append(SecretLeakFinding(path: path, line: line(at: offset), secret: needle.name))
            }
        }
        guard bytes.prefix(binarySniffBytes).contains(0) == false else { return findings }
        let matches = SecretPatternRules.matches(in: bytes, rules: rules)
        guard matches.isEmpty == false else { return findings }
        let exactLines = Set(findings.map(\.line))
        let allowed = allowedLines(bytes, line: line)
        for match in matches {
            guard exactLines.contains(match.line) == false, allowed.contains(match.line) == false,
                ignore.ignores(path: path, rule: match.rule, line: match.line) == false
            else { continue }
            findings.append(SecretLeakFinding(path: path, line: match.line, secret: match.rule))
        }
        return findings
    }

    /// Lines carrying the inline `rv-secrets:allow` comment.
    static func allowedLines(_ bytes: [UInt8], line: (Int) -> Int) -> Set<Int> {
        let marker = Array(SecretPatternRules.allowComment.utf8)
        guard SecretPatternRules.contains(marker, in: bytes) else { return [] }
        return Set(occurrences(of: marker, in: bytes).map(line))
    }

    static func sorted(_ findings: [SecretLeakFinding]) -> [SecretLeakFinding] {
        findings.sorted { ($0.path, $0.line, $0.secret) < ($1.path, $1.line, $1.secret) }
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
