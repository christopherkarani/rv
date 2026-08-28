/// Stable identity for grants, audit, and replay. Caller-supplied until a later
/// IR ticket owns fingerprint construction.
public struct ActionFingerprint: RawRepresentable, Hashable, Sendable, Equatable, Codable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Typed effects the semantic policy engine matches. Further IR growth is OPE-156.
public enum ActionEffectKind: String, Sendable, Equatable, Codable {
    case remoteSharedBranchMutation
    case localBranchCreate
    case workingTreeDiscard
    case filesystemDelete
    case filesystemMove
    case filesystemOverwrite
    case filesystemModeChange
    case filesystemCreate
    case filesystemRead
    case protectedPathMutation
    case outsideRepositoryMutation
    case unresolvedFilesystem
}

public struct ActionEffects: Sendable, Equatable, Codable {
    public var kinds: [ActionEffectKind]

    public init(kinds: [ActionEffectKind] = []) {
        self.kinds = kinds
    }
}

public struct ActionResources: Sendable, Equatable, Codable {
    public var remoteName: String?
    public var branchName: String?
    public var path: String?
    public var filesystemScope: FilesystemScope?
    public var resourceKind: FilesystemResourceKind?
    public var protectedMatch: SecretPathMatch?

    public init(
        remoteName: String? = nil,
        branchName: String? = nil,
        path: String? = nil,
        filesystemScope: FilesystemScope? = nil,
        resourceKind: FilesystemResourceKind? = nil,
        protectedMatch: SecretPathMatch? = nil
    ) {
        self.remoteName = remoteName
        self.branchName = branchName
        self.path = path
        self.filesystemScope = filesystemScope
        self.resourceKind = resourceKind
        self.protectedMatch = protectedMatch
    }
}

public struct ActionScope: Sendable, Equatable, Codable {
    public var workingDirectory: WorkingDirectory?

    public init(workingDirectory: WorkingDirectory? = nil) {
        self.workingDirectory = workingDirectory
    }
}

/// Semantic shell action. The raw command, if present, is supporting evidence only.
public struct ShellAction: Sendable, Equatable, Codable {
    public var fingerprint: ActionFingerprint
    public var effects: ActionEffects
    public var resources: ActionResources
    public var scope: ActionScope
    /// Supporting evidence only. Never the primary review input.
    public var supportingCommand: ShellCommand?

    public init(
        fingerprint: ActionFingerprint,
        effects: ActionEffects = ActionEffects(),
        resources: ActionResources = ActionResources(),
        scope: ActionScope = ActionScope(),
        supportingCommand: ShellCommand? = nil
    ) {
        self.fingerprint = fingerprint
        self.effects = effects
        self.resources = resources
        self.scope = scope
        self.supportingCommand = supportingCommand
    }
}

/// Closed action family. v1 starts at `.shell`; further cases stay off this slice.
public enum ProposedAction: Sendable, Equatable, Codable {
    case shell(ShellAction)

    public var fingerprint: ActionFingerprint {
        switch self {
        case .shell(let action):
            return action.fingerprint
        }
    }

    /// Supporting evidence only. Reviewers must use `effects` / `resources` / `scope`.
    public var supportingCommand: ShellCommand? {
        switch self {
        case .shell(let action):
            return action.supportingCommand
        }
    }

    public var effects: ActionEffects {
        switch self {
        case .shell(let action):
            return action.effects
        }
    }

    public var resources: ActionResources {
        switch self {
        case .shell(let action):
            return action.resources
        }
    }

    public var scope: ActionScope {
        switch self {
        case .shell(let action):
            return action.scope
        }
    }
}
