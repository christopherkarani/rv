#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain

/// Organization policy installed by an administrator (MDM, root). It only
/// restricts: user configuration can never loosen what it sets.
public struct ManagedPolicy: Sendable, Equatable {
    public enum Decision: String, Sendable, Equatable, CaseIterable, Comparable {
        case allow
        case ask
        case deny

        var strictness: Int {
            switch self {
            case .allow: 0
            case .ask: 1
            case .deny: 2
            }
        }

        public static func < (lhs: Decision, rhs: Decision) -> Bool { lhs.strictness < rhs.strictness }
    }

    public struct MCP: Sendable, Equatable {
        /// Server name globs no one may run.
        public var blocked: [String] = []
        /// When false, the user's mcp.json `direct` list is ignored.
        public var allowDirect = true
        public var requireSandbox = false
        /// `server/tool` globs.
        public var deny: [String] = []
        public var ask: [String] = []
        public var allow: [String] = []
        /// Rule objects from the same three lists; `tool` is a `server/tool` glob.
        public var rules: [ToolArgumentRule.Decided] = []
        public var defaultDecision: Decision = .allow

        public init() {}
    }

    public struct Secrets: Sendable, Equatable {
        /// Source kinds (`keychain`, `vault`, …); nil allows every kind.
        public var allowedSources: [String]?
        public var allowEnvironmentDelivery = true

        public init() {}
    }

    public struct AuditForward: Sendable, Equatable {
        public var url: String
        /// Values may be `${secret:NAME}`.
        public var headers: [String: String]

        public init(url: String, headers: [String: String] = [:]) {
            self.url = url
            self.headers = headers
        }
    }

    public static let secretSourceKinds = ["keychain", "hostEnvironment", "onePassword", "vault", "awsSecretsManager"]

    public var organization: String?
    public var serial: Int?
    public var mcp = MCP()
    public var secrets = Secrets()
    public var auditForward: AuditForward?

    public init() {}

    public func isServerBlocked(_ server: String) -> Bool {
        mcp.blocked.contains { Self.glob($0, server) }
    }

    /// The strictest matching glob or rule, else `defaultDecision`. Without
    /// arguments (a listing), only plain globs apply.
    public func mcpDecision(server: String, tool: String, arguments: JSONValue? = nil) -> Decision {
        let subject = "\(server)/\(tool)"
        var matched: [Decision] = []
        if mcp.deny.contains(where: { Self.glob($0, subject) }) { matched.append(.deny) }
        if mcp.ask.contains(where: { Self.glob($0, subject) }) { matched.append(.ask) }
        if mcp.allow.contains(where: { Self.glob($0, subject) }) { matched.append(.allow) }
        if let arguments, let ruled = ToolArgumentRule.strictest(mcp.rules, tool: subject, arguments: arguments) {
            matched.append(ruled)
        }
        return matched.max() ?? mcp.defaultDecision
    }

    public func mcpHasArgumentRules(server: String, tool: String) -> Bool {
        mcp.rules.contains { $0.rule.namesTool("\(server)/\(tool)") }
    }

    public func allowsSecretSource(_ kind: String) -> Bool {
        secrets.allowedSources.map { $0.contains(kind) } ?? true
    }

    /// `*` any run of characters, `?` one character.
    public static func glob(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern), t = Array(text)
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi
                mark = ti
                pi += 1
            } else if star >= 0 {
                pi = star + 1
                mark += 1
                ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}

public struct ManagedPolicyError: Error, Sendable, Equatable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}

extension ManagedPolicy {
    public static let maximumBytes = 256 * 1024

    /// Strict: unknown keys are errors, so a typo cannot silently weaken policy.
    public static func decode(_ data: Data) -> Result<ManagedPolicy, ManagedPolicyError> {
        guard data.count <= maximumBytes else { return .failure(.init("policy.json is larger than 256 KiB")) }
        guard let literal = JSONLiteral.parse(data), case .object(let object) = literal.domainValue() else {
            return .failure(.init("policy.json is not a JSON object"))
        }
        do {
            var decoded = try policy(object)
            if object["serial"] != nil {
                guard case .number(let token)? = literal.object?["serial"],
                    let exact = JSONLiteral.nonNegativeInteger(token)
                else { return .failure(.init("\"serial\" must be a non-negative integer")) }
                decoded.serial = exact
            }
            return .success(decoded)
        } catch let error as ManagedPolicyError {
            return .failure(error)
        } catch {
            return .failure(.init("policy.json is invalid"))
        }
    }

    static func policy(_ object: [String: JSONValue]) throws -> ManagedPolicy {
        try keys(object, allowed: ["version", "organization", "serial", "mcp", "secrets", "audit"], context: "policy")
        guard case .number(let version)? = object["version"], version == 1 else {
            throw ManagedPolicyError("policy \"version\" must be 1")
        }
        var policy = ManagedPolicy()
        policy.organization = try optionalString(object["organization"], "organization")
        // `serial` is read from the source spelling in `decode`. A `Double`
        // cannot hold every integer, and a rounded one can look newer than
        // the exact serial already accepted.
        if let raw = object["mcp"] {
            guard case .object(let mcp) = raw else { throw ManagedPolicyError("\"mcp\" must be an object") }
            try keys(mcp, allowed: ["blocked", "allowDirect", "requireSandbox", "deny", "ask", "allow", "defaultDecision"], context: "mcp")
            policy.mcp.blocked = try strings(mcp["blocked"], "mcp.blocked")
            policy.mcp.allowDirect = try bool(mcp["allowDirect"], "mcp.allowDirect") ?? true
            policy.mcp.requireSandbox = try bool(mcp["requireSandbox"], "mcp.requireSandbox") ?? false
            for decision in [Decision.allow, .ask, .deny] {
                let (globs, rules) = try toolRules(mcp[decision.rawValue], decision: decision, "mcp.\(decision.rawValue)")
                switch decision {
                case .deny: policy.mcp.deny = globs
                case .ask: policy.mcp.ask = globs
                case .allow: policy.mcp.allow = globs
                }
                policy.mcp.rules += rules
            }
            if let text = try optionalString(mcp["defaultDecision"], "mcp.defaultDecision") {
                guard let decision = Decision(rawValue: text) else {
                    throw ManagedPolicyError("\"mcp.defaultDecision\" must be allow, ask, or deny")
                }
                policy.mcp.defaultDecision = decision
            }
        }
        if let raw = object["secrets"] {
            guard case .object(let secrets) = raw else { throw ManagedPolicyError("\"secrets\" must be an object") }
            try keys(secrets, allowed: ["allowedSources", "allowEnvironmentDelivery"], context: "secrets")
            if secrets["allowedSources"] != nil {
                let kinds = try strings(secrets["allowedSources"], "secrets.allowedSources")
                if let unknown = kinds.first(where: { secretSourceKinds.contains($0) == false }) {
                    throw ManagedPolicyError("unknown secret source \"\(unknown)\" in secrets.allowedSources")
                }
                policy.secrets.allowedSources = kinds
            }
            policy.secrets.allowEnvironmentDelivery =
                try bool(secrets["allowEnvironmentDelivery"], "secrets.allowEnvironmentDelivery") ?? true
        }
        if let raw = object["audit"] {
            guard case .object(let audit) = raw else { throw ManagedPolicyError("\"audit\" must be an object") }
            try keys(audit, allowed: ["forward"], context: "audit")
            if let rawForward = audit["forward"] {
                guard case .object(let forward) = rawForward else {
                    throw ManagedPolicyError("\"audit.forward\" must be an object")
                }
                try keys(forward, allowed: ["url", "headers"], context: "audit.forward")
                guard let url = try optionalString(forward["url"], "audit.forward.url") else {
                    throw ManagedPolicyError("\"audit.forward.url\" is required")
                }
                var headers: [String: String] = [:]
                if let rawHeaders = forward["headers"] {
                    guard case .object(let map) = rawHeaders else {
                        throw ManagedPolicyError("\"audit.forward.headers\" must be an object of strings")
                    }
                    for (name, value) in map {
                        guard case .string(let text) = value else {
                            throw ManagedPolicyError("\"audit.forward.headers.\(name)\" must be a string")
                        }
                        headers[name] = text
                    }
                }
                policy.auditForward = AuditForward(url: url, headers: headers)
            }
        }
        return policy
    }

    private static func keys(_ object: [String: JSONValue], allowed: Set<String>, context: String) throws {
        if let unknown = object.keys.sorted().first(where: { allowed.contains($0) == false }) {
            throw ManagedPolicyError("unknown key \"\(unknown)\" in \(context)")
        }
    }

    private static func optionalString(_ value: JSONValue?, _ name: String) throws -> String? {
        guard let value else { return nil }
        guard case .string(let text) = value else { throw ManagedPolicyError("\"\(name)\" must be a string") }
        return text
    }

    private static func bool(_ value: JSONValue?, _ name: String) throws -> Bool? {
        guard let value else { return nil }
        guard case .bool(let flag) = value else { throw ManagedPolicyError("\"\(name)\" must be true or false") }
        return flag
    }

    private static func toolRules(
        _ value: JSONValue?, decision: Decision, _ name: String
    ) throws -> ([String], [ToolArgumentRule.Decided]) {
        guard let value else { return ([], []) }
        guard case .array(let items) = value else {
            throw ManagedPolicyError("\"\(name)\" must hold non-empty strings or rule objects")
        }
        var globs: [String] = []
        var rules: [ToolArgumentRule.Decided] = []
        for item in items {
            switch item {
            case .string(let text) where text.isEmpty == false:
                globs.append(text)
            case .object:
                do {
                    rules.append(.init(decision: decision, rule: try ToolArgumentRule.decode(item)))
                } catch let error as ToolArgumentRuleError {
                    throw ManagedPolicyError("\(name): \(error.message)")
                }
            default:
                throw ManagedPolicyError("\"\(name)\" must hold non-empty strings or rule objects")
            }
        }
        return (globs, rules)
    }

    private static func strings(_ value: JSONValue?, _ name: String) throws -> [String] {
        guard let value else { return [] }
        guard case .array(let items) = value else { throw ManagedPolicyError("\"\(name)\" must be an array of strings") }
        return try items.map { item in
            guard case .string(let text) = item, text.isEmpty == false else {
                throw ManagedPolicyError("\"\(name)\" must be an array of non-empty strings")
            }
            return text
        }
    }
}

/// A verified policy as installed.
public struct ManagedPolicyBundle: Sendable, Equatable {
    public var policy: ManagedPolicy
    public var sha256: String
    public var isSigned: Bool
    public var directory: String
    /// 1-based position among the keys in `org-key.pub` of the key that verified.
    public var signingKey: Int?
    /// Highest serial accepted from `directory`, once the rollback check has run.
    public var highestSerial: Int?

    public init(
        policy: ManagedPolicy, sha256: String, isSigned: Bool, directory: String, signingKey: Int? = nil,
        highestSerial: Int? = nil
    ) {
        self.policy = policy
        self.sha256 = sha256
        self.isSigned = isSigned
        self.directory = directory
        self.signingKey = signingKey
        self.highestSerial = highestSerial
    }
}

public enum ManagedPolicyState: Sendable, Equatable {
    case none
    case active(ManagedPolicyBundle)
    /// Present but untrustworthy or malformed. Governed features fail closed.
    case invalid(String)

    public var policy: ManagedPolicy? {
        if case .active(let bundle) = self { return bundle.policy }
        return nil
    }

    public var invalidReason: String? {
        if case .invalid(let reason) = self { return reason }
        return nil
    }
}

/// Where the managed bundle lives and who must own it. The binary always uses
/// `installed`; there is deliberately no environment override.
public struct ManagedPolicyLocation: Sendable {
    public static let policyFile = "policy.json"
    public static let signatureFile = "policy.json.sig"
    public static let publicKeyFile = "org-key.pub"

    public var directory: URL
    public var requiredOwner: uid_t
    /// Ancestors are checked up to and including this path.
    public var trustRoot: String

    public init(directory: URL, requiredOwner: uid_t, trustRoot: String) {
        self.directory = directory
        self.requiredOwner = requiredOwner
        self.trustRoot = trustRoot
    }

    #if os(macOS)
    public static let installedDirectory = "/Library/Application Support/RV/managed"
    #else
    public static let installedDirectory = "/etc/rv/managed"
    #endif

    public static let installed = ManagedPolicyLocation(
        directory: URL(fileURLWithPath: installedDirectory, isDirectory: true), requiredOwner: 0, trustRoot: "/")

    public func load() -> ManagedPolicyState {
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            return errno == ENOENT ? .none : .invalid("cannot inspect \(directory.path)")
        }
        guard protectedChain(directory.path, isFile: false) else {
            return .invalid("\(directory.path) must be a directory owned by uid \(requiredOwner) and not writable by others")
        }
        let policyURL = directory.appendingPathComponent(Self.policyFile)
        let policyData: Data
        switch readFile(policyURL) {
        case .missing: return .none
        case .unsafe: return .invalid("\(policyURL.path) must be a regular file owned by uid \(requiredOwner), not writable by others")
        case .data(let data): policyData = data
        }
        var signature: Data?
        var publicKey: Data?
        for (name, slot) in [(Self.signatureFile, 0), (Self.publicKeyFile, 1)] {
            switch readFile(directory.appendingPathComponent(name)) {
            case .missing: continue
            case .unsafe: return .invalid("\(name) must be a regular file owned by uid \(requiredOwner), not writable by others")
            case .data(let data): if slot == 0 { signature = data } else { publicKey = data }
            }
        }
        return ManagedPolicyVerifier.verify(
            policy: policyData, signature: signature, publicKey: publicKey, directory: directory.path)
    }

    enum ReadOutcome {
        case missing
        case unsafe
        case data(Data)
    }

    func readFile(_ url: URL) -> ReadOutcome {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return .missing }
            return .unsafe
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, trusted(info), (info.st_mode & S_IFMT) == S_IFREG,
            info.st_size >= 0, Int(info.st_size) <= ManagedPolicy.maximumBytes, Self.hasNoAllowACL(fd: fd)
        else { return .unsafe }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return .unsafe }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
            guard bytes.count <= ManagedPolicy.maximumBytes else { return .unsafe }
        }
        return .data(bytes)
    }

    func trusted(_ info: stat) -> Bool {
        info.st_uid == requiredOwner && (info.st_mode & 0o022) == 0
    }

    func protectedChain(_ path: String, isFile: Bool) -> Bool {
        var current = URL(fileURLWithPath: path).standardizedFileURL.path
        let top = URL(fileURLWithPath: trustRoot).standardizedFileURL.path
        guard current == top || current.hasPrefix(top == "/" ? "/" : top + "/") else { return false }
        var first = true
        while true {
            var info = stat()
            guard lstat(current, &info) == 0, trusted(info) || (first == false && info.st_uid == 0 && (info.st_mode & 0o022) == 0),
                (info.st_mode & S_IFMT) == (first && isFile ? S_IFREG : S_IFDIR), Self.hasNoAllowACL(path: current)
            else { return false }
            if current == top || current == "/" { return true }
            current = (current as NSString).deletingLastPathComponent
            first = false
        }
    }

    #if canImport(Darwin)
    static func hasNoAllowACL(path: String) -> Bool {
        errno = 0
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        return onlyDenyEntries(acl)
    }

    static func hasNoAllowACL(fd: Int32) -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        return onlyDenyEntries(acl)
    }

    private static func onlyDenyEntries(_ acl: acl_t) -> Bool {
        var entry: acl_entry_t?
        var selector = Int32(ACL_FIRST_ENTRY.rawValue)
        while acl_get_entry(acl, selector, &entry) == 0 {
            guard let entry else { return false }
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0, tag == ACL_EXTENDED_DENY else { return false }
            selector = Int32(ACL_NEXT_ENTRY.rawValue)
        }
        return true
    }
    #else
    static func hasNoAllowACL(path: String) -> Bool { true }
    static func hasNoAllowACL(fd: Int32) -> Bool { true }
    #endif
}

/// Ed25519 over the exact policy bytes. Keys and signatures are base64 text.
/// `org-key.pub` may pin several keys (one per line, `#` comments) so an
/// organization can rotate: any pinned key verifies.
public enum ManagedPolicyVerifier {
    public static let maximumKeys = 16

    public static func verify(policy data: Data, signature: Data?, publicKey: Data?, directory: String) -> ManagedPolicyState {
        var signingKey: Int?
        if let publicKey {
            let keys: [Curve25519.Signing.PublicKey]
            switch publicKeys(publicKey) {
            case .failure(let error): return .invalid(error.message)
            case .success(let parsed): keys = parsed
            }
            guard let signature else {
                return .invalid("\(ManagedPolicyLocation.publicKeyFile) is pinned but \(ManagedPolicyLocation.signatureFile) is missing")
            }
            guard let signatureBytes = base64(signature),
                let index = keys.firstIndex(where: { $0.isValidSignature(signatureBytes, for: data) })
            else {
                let target = keys.count == 1 ? ManagedPolicyLocation.publicKeyFile : "any key in \(ManagedPolicyLocation.publicKeyFile)"
                return .invalid("\(ManagedPolicyLocation.signatureFile) does not verify against \(target)")
            }
            signingKey = index + 1
        }
        switch ManagedPolicy.decode(data) {
        case .failure(let error):
            return .invalid(error.message)
        case .success(let policy):
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return .active(ManagedPolicyBundle(
                policy: policy, sha256: digest, isSigned: signingKey != nil, directory: directory, signingKey: signingKey))
        }
    }

    static func publicKeys(_ data: Data) -> Result<[Curve25519.Signing.PublicKey], ManagedPolicyError> {
        let file = ManagedPolicyLocation.publicKeyFile
        var keys: [Curve25519.Signing.PublicKey] = []
        for (number, line) in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
        {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || text.hasPrefix("#") { continue }
            guard let bytes = Data(base64Encoded: text), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: bytes) else {
                return .failure(ManagedPolicyError("\(file) line \(number + 1) is not a base64 Ed25519 public key"))
            }
            guard keys.count < maximumKeys else {
                return .failure(ManagedPolicyError("\(file) holds more than \(maximumKeys) keys"))
            }
            keys.append(key)
        }
        return keys.isEmpty ? .failure(ManagedPolicyError("\(file) holds no key")) : .success(keys)
    }

    /// (public, private) as base64 raw representations.
    public static func generateKeyPair() -> (publicKey: String, privateKey: String) {
        let key = Curve25519.Signing.PrivateKey()
        return (key.publicKey.rawRepresentation.base64EncodedString(), key.rawRepresentation.base64EncodedString())
    }

    public static func sign(_ data: Data, privateKey: Data) -> String? {
        guard let bytes = base64(privateKey), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: bytes),
            let signature = try? key.signature(for: data)
        else { return nil }
        return signature.base64EncodedString()
    }

    static func base64(_ data: Data) -> Data? {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Data(base64Encoded: text)
    }
}
