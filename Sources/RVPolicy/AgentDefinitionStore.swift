#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain

public enum AgentDefinitionStoreError: Error, Sendable, Equatable {
    case unsafeLocation
    case unreadable
    case oversized
    case invalidDocument
    case unsupportedVersion
}

/// One loaded definition paired with the PR1 canonical revision of its
/// RESOLVED state. The revision digests the resolved resource-profile
/// content, not just the profile name, so a profile edit changes the
/// revision even when the definition file is untouched.
public struct ResolvedAgentDefinition: Sendable, Equatable {
    public let definition: AgentDefinition
    public let revision: AgentDefinitionRevision

    init(definition: AgentDefinition, revision: AgentDefinitionRevision) {
        self.definition = definition
        self.revision = revision
    }
}

public struct AgentDefinitionSet: Sendable, Equatable {
    public let resolved: [ResolvedAgentDefinition]

    public init(resolved: [ResolvedAgentDefinition]) {
        self.resolved = resolved
    }

    public static let empty = AgentDefinitionSet(resolved: [])

    public func definition(id: AgentDefinitionID) -> AgentDefinition? {
        resolved.first(where: { $0.definition.id == id })?.definition
    }

    /// PR1 canonical revision of the loaded resolved definition.
    public func revision(of id: AgentDefinitionID) -> AgentDefinitionRevision? {
        resolved.first(where: { $0.definition.id == id })?.revision
    }
}

/// Operator-selected snapshot for an explicitly launched custom executable.
///
/// A custom executable NEVER inherits a named agent's identity or credential
/// grants from its filename, agent tag, or HookHost (spec I2/I10/I11: the
/// workload never chooses the trusted facts that establish its identity).
/// The snapshot therefore carries a reserved definition id that operator
/// config cannot define, no credential bindings, an empty authority
/// ceiling, no integration metadata, and a locked-down resource profile
/// with no eligible projects. It always pins the executable content digest;
/// an unpinned custom launch gets no definition at all and fails closed.
public struct AdHocAgentSnapshot: Sendable, Equatable {
    public let definition: AgentDefinition
    public let revision: AgentDefinitionRevision

    /// Builds the snapshot, or nil when the digest is malformed.
    public static func make(expectedContentDigestSHA256 digest: String) -> AdHocAgentSnapshot? {
        guard isSHA256HexDigest(digest) else { return nil }
        let definition = AgentDefinition(
            id: AgentDefinitionID(rawValue: AgentDefinitionStore.reservedSnapshotID),
            displayName: "Ad-hoc custom executable",
            blurb: "Operator-selected custom executable. Carries no named identity and no credential grants.",
            executableRequirement: ExecutableRequirement(expectedContentDigestSHA256: digest),
            hookHost: nil,
            agentTag: nil,
            resourceProfile: RuntimeResourceProfile(
                id: AgentDefinitionStore.reservedSnapshotID, projects: []
            ),
            credentialBindings: [],
            requiredAssurance: .unattested,
            authorityCeiling: .none
        )
        return AdHocAgentSnapshot(
            definition: definition, revision: AgentDefinitionRevision.resolve(definition)
        )
    }
}

/// Loads trusted operator agent definitions from `agent-definitions.json`.
///
/// Definitions come ONLY from this operator config file. They are never
/// read from repo files, agent output, executable basenames, HookHost, or
/// agent tags. The default location resolves via the real OS account root
/// (`HomeDirectory.process()` + `RVPolicyPaths`); no API here accepts a
/// request-provided HOME, so untrusted input cannot redirect the trusted
/// root. Every failure mode fails closed (spec I14).
public enum AgentDefinitionStore {
    public static let maximumBytes = 65_536

    /// Definition id reserved for `AdHocAgentSnapshot`. Operator config
    /// cannot define it, so a named definition and a snapshot can never
    /// share an identity.
    public static let reservedSnapshotID = "adhoc"

    /// Default trusted file, or nil when the OS HOME is unavailable.
    /// Derived from `HomeDirectory.process()` only.
    public static func defaultConfigFile() -> URL? {
        guard let home = HomeDirectory.process() else { return nil }
        return RVPolicyPaths.agentDefinitionsFile(
            inConfigDir: RVPolicyPaths.configDirectory(home: home)
        )
    }

    /// Loads from the default trusted location. Fails closed when no OS
    /// HOME establishes a trusted root. `resourcePolicy` must be the
    /// already-loaded trusted resource policy; definition profile names
    /// resolve against it.
    public static func loadFromOperatorConfig(
        resourcePolicy: RuntimeResourcePolicy
    ) -> Result<AgentDefinitionSet, AgentDefinitionStoreError> {
        guard let home = HomeDirectory.process() else { return .failure(.unsafeLocation) }
        return load(
            from: RVPolicyPaths.configDirectory(home: home), resourcePolicy: resourcePolicy
        )
    }

    public static func load(
        from configDirectory: URL, resourcePolicy: RuntimeResourcePolicy
    ) -> Result<AgentDefinitionSet, AgentDefinitionStoreError> {
        let directory = configDirectory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        if directory < 0 {
            return errno == ENOENT ? .success(.empty) : .failure(.unsafeLocation)
        }
        defer { close(directory) }
        var directoryStatus = stat()
        guard fstat(directory, &directoryStatus) == 0,
            directoryStatus.st_uid == getuid(),
            (directoryStatus.st_mode & 0o022) == 0
        else {
            return .failure(.unsafeLocation)
        }
        let file = "agent-definitions.json".withCString {
            openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if file < 0 {
            return errno == ENOENT ? .success(.empty) : .failure(.unsafeLocation)
        }
        defer { close(file) }
        var fileStatus = stat()
        guard fstat(file, &fileStatus) == 0,
            (fileStatus.st_mode & S_IFMT) == S_IFREG,
            fileStatus.st_uid == getuid(),
            (fileStatus.st_mode & 0o177) == 0
        else {
            return .failure(.unsafeLocation)
        }
        guard fileStatus.st_size >= 0, fileStatus.st_size <= Int64(maximumBytes) else {
            return .failure(.oversized)
        }
        var bytes = [UInt8](repeating: 0, count: maximumBytes + 1)
        var count = 0
        while count < bytes.count {
            let remaining = bytes.count - count
            let result = bytes.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return -1 }
                return read(file, base.advanced(by: count), remaining)
            }
            if result > 0 { count += result; continue }
            if result == 0 { break }
            if errno == EINTR { continue }
            return .failure(.unreadable)
        }
        guard count <= maximumBytes else { return .failure(.oversized) }
        return decode(Data(bytes.prefix(count)), resourcePolicy: resourcePolicy)
    }

    public static func decode(
        _ data: Data, resourcePolicy: RuntimeResourcePolicy
    ) -> Result<AgentDefinitionSet, AgentDefinitionStoreError> {
        guard data.count <= maximumBytes else { return .failure(.oversized) }
        guard let document = try? JSONDecoder().decode(AgentDefinitionDocument.self, from: data) else {
            return .failure(.invalidDocument)
        }
        guard document.version == 1 else { return .failure(.unsupportedVersion) }
        guard document.definitions.count <= 32 else { return .failure(.invalidDocument) }
        var seen = Set<String>()
        var resolved: [ResolvedAgentDefinition] = []
        for dto in document.definitions {
            guard seen.insert(dto.id).inserted else { return .failure(.invalidDocument) }
            guard let definition = resolve(dto, resourcePolicy: resourcePolicy) else {
                return .failure(.invalidDocument)
            }
            resolved.append(
                ResolvedAgentDefinition(
                    definition: definition,
                    revision: AgentDefinitionRevision.resolve(definition)
                )
            )
        }
        return .success(AgentDefinitionSet(resolved: resolved))
    }

    private static func resolve(
        _ dto: AgentDefinitionDTO, resourcePolicy: RuntimeResourcePolicy
    ) -> AgentDefinition? {
        guard let id = AgentDefinitionID(validating: dto.id),
            dto.id != reservedSnapshotID,
            displayText(dto.displayName, maxBytes: 256, allowEmpty: false),
            displayText(dto.blurb, maxBytes: 1024, allowEmpty: true),
            let executable = resolveExecutable(dto.executable),
            dto.agentTag.map(AgentTagValidator.isValid) ?? true,
            dto.resourceProfile.utf8.count <= 64,
            let profile = resourcePolicy.profiles.first(where: { $0.id == dto.resourceProfile }),
            dto.credentialBindings.count <= 32,
            dto.credentialBindings.allSatisfy(identifier),
            Set(dto.credentialBindings).count == dto.credentialBindings.count,
            dto.authorityCeiling.count <= 64,
            dto.authorityCeiling.allSatisfy(scopeName),
            Set(dto.authorityCeiling).count == dto.authorityCeiling.count
        else {
            return nil
        }
        return AgentDefinition(
            id: id,
            displayName: dto.displayName,
            blurb: dto.blurb,
            executableRequirement: executable,
            hookHost: dto.hookHost,
            agentTag: dto.agentTag,
            resourceProfile: profile,
            credentialBindings: dto.credentialBindings,
            requiredAssurance: dto.requiredAssurance,
            authorityCeiling: AgentAuthority(scopes: dto.authorityCeiling)
        )
    }

    /// A requirement pins at least one evidence anchor or explicitly allows
    /// unsigned workloads. A vacuous requirement (nothing pinned, unsigned
    /// refused) could never be satisfied honestly, so it fails closed.
    private static func resolveExecutable(
        _ dto: ExecutableRequirementDTO
    ) -> ExecutableRequirement? {
        if let digest = dto.expectedContentDigestSHA256 {
            guard isSHA256HexDigest(digest) else { return nil }
        }
        if let teamID = dto.requiredTeamID {
            guard isTeamID(teamID) else { return nil }
        }
        if let requirement = dto.requiredCodeRequirement {
            guard isCodeRequirement(requirement) else { return nil }
        }
        let pins =
            (dto.expectedContentDigestSHA256 == nil ? 0 : 1)
            + (dto.requiredTeamID == nil ? 0 : 1)
            + (dto.requiredCodeRequirement == nil ? 0 : 1)
        guard pins > 0 || dto.allowsUnsigned else { return nil }
        return ExecutableRequirement(
            expectedContentDigestSHA256: dto.expectedContentDigestSHA256,
            requiredTeamID: dto.requiredTeamID,
            requiredCodeRequirement: dto.requiredCodeRequirement,
            allowsUnsigned: dto.allowsUnsigned
        )
    }

    private static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    /// Authority scope names are opaque operator-defined strings. The
    /// charset admits hierarchical separators (`:` `/`) but no whitespace
    /// or control bytes.
    private static func scopeName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46 || $0 == 95
                || $0 == 58 || $0 == 47
        }
    }

    private static func displayText(_ value: String, maxBytes: Int, allowEmpty: Bool) -> Bool {
        (allowEmpty || value.isEmpty == false) && value.utf8.count <= maxBytes
            && !value.contains("\0") && !value.contains("\n") && !value.contains("\r")
    }

    private static func isTeamID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 32 && value.utf8.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57)
        }
    }

    private static func isCodeRequirement(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1_024
            && !value.contains("\0") && !value.contains("\n") && !value.contains("\r")
    }
}

/// SHA-256 content digest in PR1 form: exactly 64 lowercase hex digits.
private func isSHA256HexDigest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy {
        ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
    }
}

private struct StrictKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ value: String) {
        stringValue = value
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        nil
    }
}

private func rejectUnknownKeys(
    _ container: KeyedDecodingContainer<StrictKey>, allowed: Set<String>
) throws {
    for key in container.allKeys where allowed.contains(key.stringValue) == false {
        throw DecodingError.dataCorruptedError(
            forKey: key, in: container,
            debugDescription: "unknown field: \(key.stringValue)"
        )
    }
}

/// Versioned operator document. The key sets below are closed: unknown
/// fields fail closed, so a security-critical field RV does not understand
/// (or a secret value smuggled under any name) can never slip through.
/// Definitions carry credential binding names only, never secret values.
private struct AgentDefinitionDocument: Decodable {
    let version: Int
    let definitions: [AgentDefinitionDTO]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictKey.self)
        try rejectUnknownKeys(container, allowed: ["version", "definitions"])
        version = try container.decode(Int.self, forKey: StrictKey("version"))
        definitions = try container.decode([AgentDefinitionDTO].self, forKey: StrictKey("definitions"))
    }
}

private struct AgentDefinitionDTO: Decodable {
    let id: String
    let displayName: String
    let blurb: String
    let executable: ExecutableRequirementDTO
    let hookHost: HookHost?
    let agentTag: String?
    let resourceProfile: String
    let credentialBindings: [String]
    let requiredAssurance: ExecutableAssurance
    let authorityCeiling: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictKey.self)
        try rejectUnknownKeys(
            container,
            allowed: [
                "id", "displayName", "blurb", "executable", "hookHost", "agentTag",
                "resourceProfile", "credentialBindings", "requiredAssurance", "authorityCeiling",
            ]
        )
        id = try container.decode(String.self, forKey: StrictKey("id"))
        displayName = try container.decode(String.self, forKey: StrictKey("displayName"))
        blurb = try container.decode(String.self, forKey: StrictKey("blurb"))
        executable = try container.decode(ExecutableRequirementDTO.self, forKey: StrictKey("executable"))
        hookHost = try container.decodeIfPresent(HookHost.self, forKey: StrictKey("hookHost"))
        agentTag = try container.decodeIfPresent(String.self, forKey: StrictKey("agentTag"))
        resourceProfile = try container.decode(String.self, forKey: StrictKey("resourceProfile"))
        credentialBindings = try container.decode(
            [String].self, forKey: StrictKey("credentialBindings")
        )
        requiredAssurance = try container.decode(
            ExecutableAssurance.self, forKey: StrictKey("requiredAssurance")
        )
        authorityCeiling = try container.decode([String].self, forKey: StrictKey("authorityCeiling"))
    }
}

private struct ExecutableRequirementDTO: Decodable {
    let expectedContentDigestSHA256: String?
    let requiredTeamID: String?
    let requiredCodeRequirement: String?
    let allowsUnsigned: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictKey.self)
        try rejectUnknownKeys(
            container,
            allowed: [
                "expectedContentDigestSHA256", "requiredTeamID",
                "requiredCodeRequirement", "allowsUnsigned",
            ]
        )
        expectedContentDigestSHA256 = try container.decodeIfPresent(
            String.self, forKey: StrictKey("expectedContentDigestSHA256")
        )
        requiredTeamID = try container.decodeIfPresent(
            String.self, forKey: StrictKey("requiredTeamID")
        )
        requiredCodeRequirement = try container.decodeIfPresent(
            String.self, forKey: StrictKey("requiredCodeRequirement")
        )
        allowsUnsigned = try container.decodeIfPresent(
            Bool.self, forKey: StrictKey("allowsUnsigned")
        ) ?? false
    }
}
