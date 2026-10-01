import Foundation

/// A component identity does not confer human or Agent Principal authority.
public enum TrustedRVComponentRole: String, Sendable, Codable, CaseIterable, Hashable {
    case cli, service, workspaceHost
    /// Trusted native operator UI. Establishes that this is genuine RV operator
    /// UI code — never that the human authorized anything. Least privilege:
    /// review ceremonies only; no execution, policy, approval, or secret access.
    case operatorUI
}

public struct PeerCodeIdentity: Sendable, Equatable {
    public let identifier: String
    public let teamIdentifier: String?
    public let cdHash: Data
    public let executablePath: String
    public let isAdHoc: Bool
    public let hardenedRuntime: Bool
    public let injectionExceptions: Set<String>
}

/// Non-wire evidence. Only platform authenticators construct it.
public struct PlatformPeerEvidence: Sendable, Equatable {
    public let processID: Int32
    public let effectiveUserID: UInt32
    public let auditToken: Data?
    public let codeIdentity: PeerCodeIdentity
    public let componentRole: TrustedRVComponentRole?

    init(processID: Int32, effectiveUserID: UInt32, auditToken: Data?,
         codeIdentity: PeerCodeIdentity, componentRole: TrustedRVComponentRole?) {
        self.processID = processID
        self.effectiveUserID = effectiveUserID
        self.auditToken = auditToken
        self.codeIdentity = codeIdentity
        self.componentRole = componentRole
    }
}

public enum PeerAuthenticationError: Error, Sendable, Equatable {
    case missingPeerEvidence
    case inconsistentPeerEvidence
    case codeLookup(Int32)
    case invalidCode(Int32)
    case invalidTrustConfiguration
}

#if os(macOS)
import Darwin
import Security

/// No environment variable or user-owned file can add a component role.
/// An administrator installs this manifest and its artifacts under protected paths.
public struct ProtectedPeerTrustConfiguration: Sendable {
    struct Entry: Codable, Sendable {
        var role: TrustedRVComponentRole
        var requirement: String
        var requiredIdentifier: String?
        var requiredTeamIdentifier: String?
        var developmentCDHash: String?
        var developmentExecutablePath: String?
    }
    private let entries: [Entry]
    public static let denyAll = ProtectedPeerTrustConfiguration(entries: [])
    public static let installedURL = URL(fileURLWithPath: "/Library/Application Support/RV/peer-trust.json")

    public static func installed() throws -> Self { try load(from: installedURL) }

    private init(entries: [Entry]) { self.entries = entries }

    public static func load(from url: URL) throws -> Self {
        guard protectedPath(url.path, file: true) else {
            throw PeerAuthenticationError.invalidTrustConfiguration
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PeerAuthenticationError.invalidTrustConfiguration }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, safe(info), hasNoAllowACL(fd: fd),
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= 65_536 else {
            throw PeerAuthenticationError.invalidTrustConfiguration
        }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw PeerAuthenticationError.invalidTrustConfiguration }
            if n == 0 { break }
            bytes.append(contentsOf: buffer.prefix(n))
            guard bytes.count <= 65_536 else { throw PeerAuthenticationError.invalidTrustConfiguration }
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: bytes),
              Set(entries.map(\.role)).count == entries.count else {
            throw PeerAuthenticationError.invalidTrustConfiguration
        }
        for entry in entries {
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(entry.requirement as CFString, [], &requirement) == errSecSuccess,
                  requirement != nil else { throw PeerAuthenticationError.invalidTrustConfiguration }
            if let hash = entry.developmentCDHash {
                guard hash.count == 40, hash.allSatisfy({ $0.isHexDigit }),
                      let path = entry.developmentExecutablePath,
                      protectedPath(path, file: true),
                      entry.requirement == "cdhash H\"\(hash.lowercased())\"" else {
                    throw PeerAuthenticationError.invalidTrustConfiguration
                }
            } else {
                guard entry.developmentExecutablePath == nil,
                      let identifier = entry.requiredIdentifier,
                      let team = entry.requiredTeamIdentifier,
                      !identifier.isEmpty, !team.isEmpty,
                      identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }),
                      team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
                    throw PeerAuthenticationError.invalidTrustConfiguration
                }
            }
        }
        return Self(entries: entries)
    }

    func role(code: SecCode, identity: PeerCodeIdentity) -> TrustedRVComponentRole? {
        // Protected bytes and a matching signature do not stop same-user
        // DYLD/debugger injection into an unhardened process. Such a process
        // remains factual code evidence but receives no component authority.
        guard identity.hardenedRuntime, identity.injectionExceptions.isEmpty else { return nil }
        for entry in entries {
            if let hash = entry.developmentCDHash {
                guard identity.cdHash.map({ String(format: "%02x", $0) }).joined() == hash.lowercased(),
                      identity.executablePath == entry.developmentExecutablePath,
                      Self.protectedPath(identity.executablePath, file: true) else { continue }
            } else {
                // Production identity must have a live non-ad-hoc team signature.
                guard !identity.isAdHoc,
                      identity.identifier == entry.requiredIdentifier,
                      identity.teamIdentifier == entry.requiredTeamIdentifier,
                      let teamIdentifier = identity.teamIdentifier else { continue }
                var productionRequirement: SecRequirement?
                let expression = "anchor apple generic and identifier \"\(identity.identifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
                guard SecRequirementCreateWithString(expression as CFString, [], &productionRequirement) == errSecSuccess,
                      let productionRequirement,
                      SecCodeCheckValidity(code, [], productionRequirement) == errSecSuccess else { continue }
            }
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(entry.requirement as CFString, [], &requirement) == errSecSuccess,
                  let requirement,
                  SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { continue }
            return entry.role
        }
        return nil
    }

    private static func safe(_ info: stat) -> Bool {
        info.st_uid == 0 && (info.st_mode & 0o022) == 0
    }

    // POSIX mode bits do not describe ACL authority. Conservatively reject every
    // allow entry (including read-only ones); platform deny-only ACLs are safe.
    static func hasNoAllowACL(path: String) -> Bool {
        guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        return hasNoAllowACL(acl)
    }

    static func hasNoAllowACL(fd: Int32) -> Bool {
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        return hasNoAllowACL(acl)
    }

    private static func hasNoAllowACL(_ acl: acl_t) -> Bool {
        guard acl_valid(acl) == 0 else { return false }
        var entry: acl_entry_t?
        var selector = Int32(ACL_FIRST_ENTRY.rawValue)
        while true {
            errno = 0
            let result = acl_get_entry(acl, selector, &entry)
            if result != 0 {
                // Darwin documents EINVAL at end-of-list. The ACL has already
                // been validated and selectors are exclusively FIRST/NEXT.
                return errno == EINVAL
            }
            guard let entry else { return false }
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0, tag == ACL_EXTENDED_DENY else { return false }
            selector = Int32(ACL_NEXT_ENTRY.rawValue)
        }
    }

    private static func protectedPath(_ path: String, file: Bool) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0"),
              URL(fileURLWithPath: path).standardizedFileURL.path == path else { return false }
        var current = path
        var first = true
        while true {
            var info = stat()
            guard lstat(current, &info) == 0, safe(info), hasNoAllowACL(path: current),
                  (info.st_mode & S_IFMT) == (first && file ? S_IFREG : S_IFDIR) else { return false }
            if current == "/" { return true }
            current = (current as NSString).deletingLastPathComponent
            first = false
        }
    }
}

public enum WorkspacePeerAuthenticator {
    /// Connection credentials identify the connector, not writers of forwarded FDs.
    public static func capture(
        fd: Int32, trust: ProtectedPeerTrustConfiguration = .denyAll
    ) throws -> PlatformPeerEvidence {
        var uid: uid_t = 0
        var gid: gid_t = 0
        var pid: pid_t = 0
        var pidLength = socklen_t(MemoryLayout<pid_t>.size)
        var token = audit_token_t()
        var tokenLength = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getpeereid(fd, &uid, &gid) == 0,
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidLength) == 0,
              pidLength == MemoryLayout<pid_t>.size, pid > 0,
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenLength) == 0,
              tokenLength == MemoryLayout<audit_token_t>.size else {
            throw PeerAuthenticationError.missingPeerEvidence
        }
        let words = withUnsafeBytes(of: token) { Array($0.bindMemory(to: UInt32.self)) }
        guard words.count == 8, words[1] == uid, words[5] == UInt32(pid), words[7] != 0 else {
            throw PeerAuthenticationError.inconsistentPeerEvidence
        }
        let tokenBytes = withUnsafeBytes(of: token) { Data($0) }
        var code: SecCode?
        let result = SecCodeCopyGuestWithAttributes(nil,
            [kSecGuestAttributeAudit: tokenBytes] as CFDictionary, [], &code)
        guard result == errSecSuccess, let code else { throw PeerAuthenticationError.codeLookup(result) }
        return try MacOSPeerCodeVerifier.capture(code: code, processID: pid,
            effectiveUserID: uid, auditToken: tokenBytes, trust: trust)
    }
}

/// Consumes a dynamic code object derived at a trusted transport boundary.
public enum MacOSPeerCodeVerifier {
    public static func capture(
        code: SecCode, processID: Int32, effectiveUserID: UInt32, auditToken: Data? = nil,
        trust: ProtectedPeerTrustConfiguration = .denyAll
    ) throws -> PlatformPeerEvidence {
        let valid = SecCodeCheckValidity(code, [], nil)
        guard valid == errSecSuccess else { throw PeerAuthenticationError.invalidCode(valid) }
        var staticCode: SecStaticCode?
        let staticResult = SecCodeCopyStaticCode(code, [], &staticCode)
        guard staticResult == errSecSuccess, let staticCode else {
            throw PeerAuthenticationError.codeLookup(staticResult)
        }
        var raw: CFDictionary?
        let result = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &raw)
        guard result == errSecSuccess, let info = raw as? [String: Any],
              let identifier = info[kSecCodeInfoIdentifier as String] as? String,
              let hash = info[kSecCodeInfoUnique as String] as? Data,
              let executable = info[kSecCodeInfoMainExecutable as String] as? URL,
              let flags = info[kSecCodeInfoFlags as String] as? NSNumber else {
            throw PeerAuthenticationError.codeLookup(result)
        }
        let injectionKeys = [
            "com.apple.security.cs.allow-dyld-environment-variables",
            "com.apple.security.cs.disable-library-validation",
            "com.apple.security.get-task-allow",
            "get-task-allow",
            "com.apple.security.cs.allow-unsigned-executable-memory",
            "com.apple.security.cs.disable-executable-page-protection",
        ]
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        let injectionExceptions = Set(injectionKeys.filter { key in
            guard let value = entitlements[key] else { return false }
            // Missing/explicit false is acceptable; unknown types fail closed.
            return (value as? NSNumber)?.boolValue != false
        })
        let identity = PeerCodeIdentity(identifier: identifier,
            teamIdentifier: info[kSecCodeInfoTeamIdentifier as String] as? String,
            cdHash: hash, executablePath: executable.path,
            // Public CSCommon.h kSecCodeSignatureAdhoc = 0x0002 is not
            // imported by Swift. Dynamic requirement validation remains separate.
            isAdHoc: flags.uint32Value & 0x0002 != 0,
            // Public CSCommon.h kSecCodeSignatureRuntime = 0x10000.
            hardenedRuntime: flags.uint32Value & 0x10000 != 0,
            injectionExceptions: injectionExceptions)
        // SecCodeCopyStaticCode's filesystem link alone is not security proof.
        // Rebind copied signing metadata to the original live code's exact hash.
        let hashText = hash.map { String(format: "%02x", $0) }.joined()
        var hashRequirement: SecRequirement?
        let parsed = SecRequirementCreateWithString("cdhash H\"\(hashText)\"" as CFString, [], &hashRequirement)
        guard parsed == errSecSuccess, let hashRequirement else {
            throw PeerAuthenticationError.invalidCode(parsed)
        }
        let bound = SecCodeCheckValidity(code, [], hashRequirement)
        guard bound == errSecSuccess else { throw PeerAuthenticationError.invalidCode(bound) }
        return PlatformPeerEvidence(processID: processID, effectiveUserID: effectiveUserID,
            auditToken: auditToken, codeIdentity: identity, componentRole: trust.role(code: code, identity: identity))
    }
}
#endif
