/// Stable identity for grants, audit, and replay.
///
/// IR owns host-door fingerprint construction via `make(host:session:cwd:command:)`
/// and `make(host:session:cwd:file:)`. Semantic `GitAction` /
/// `FilesystemAction` fingerprints remain distinct until a later IR
/// composition ticket.
public struct ActionFingerprint: RawRepresentable, Hashable, Sendable, Equatable, Codable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Host-door fingerprint. Nil session and cwd occupy empty field slots.
    public static func make(
        host: HookHost,
        session: SessionID?,
        cwd: WorkingDirectory?,
        command: ShellCommand
    ) -> ActionFingerprint {
        ActionFingerprint(
            rawValue: "\(host.rawValue):\(session?.rawValue ?? ""):\(cwd?.rawValue ?? ""):\(command.rawValue)"
        )
    }

    /// File-tool fingerprint. Cannot collide with the shell spelling.
    /// Nil session and cwd occupy empty field slots.
    /// Spelling: `file:<host>:<session>:<cwd>:<kind>:<path>`
    public static func make(
        host: HookHost,
        session: SessionID?,
        cwd: WorkingDirectory?,
        file: FileToolAction
    ) -> ActionFingerprint {
        ActionFingerprint(
            rawValue: "file:\(host.rawValue):\(session?.rawValue ?? ""):\(cwd?.rawValue ?? ""):\(file.kind.rawValue):\(file.path.rawValue)"
        )
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

    public init(
        remoteName: String? = nil,
        branchName: String? = nil,
        path: String? = nil,
        filesystemScope: FilesystemScope? = nil,
        resourceKind: FilesystemResourceKind? = nil
    ) {
        self.remoteName = remoteName
        self.branchName = branchName
        self.path = path
        self.filesystemScope = filesystemScope
        self.resourceKind = resourceKind
    }
}

public struct ActionScope: Sendable, Equatable, Codable {
    public var workingDirectory: WorkingDirectory?

    public init(workingDirectory: WorkingDirectory? = nil) {
        self.workingDirectory = workingDirectory
    }
}

/// Semantic shell action. The raw command, if present, is supporting evidence only.
/// Analysis is git or filesystem, never both.
public struct ShellAction: Sendable, Equatable, Codable {
    public var fingerprint: ActionFingerprint
    public var effects: ActionEffects
    public var resources: ActionResources
    public var scope: ActionScope
    /// Supporting evidence only. Never the primary review input.
    public var supportingCommand: ShellCommand?
    /// Closed git ⊕ filesystem analysis. Nil means unknown, stripped, or unanalyzed.
    public var analysis: SemanticAction?

    public var gitAction: GitAction? {
        if case .git(let action) = analysis {
            return action
        }
        return nil
    }

    public var filesystemAction: FilesystemAction? {
        if case .filesystem(let action) = analysis {
            return action
        }
        return nil
    }

    public init(
        fingerprint: ActionFingerprint,
        effects: ActionEffects = ActionEffects(),
        resources: ActionResources = ActionResources(),
        scope: ActionScope = ActionScope(),
        supportingCommand: ShellCommand? = nil,
        analysis: SemanticAction? = nil
    ) {
        self.fingerprint = fingerprint
        self.effects = effects
        self.resources = resources
        self.scope = scope
        self.supportingCommand = supportingCommand
        self.analysis = analysis
    }

    public init(
        fingerprint: ActionFingerprint,
        effects: ActionEffects = ActionEffects(),
        resources: ActionResources = ActionResources(),
        scope: ActionScope = ActionScope(),
        supportingCommand: ShellCommand? = nil,
        gitAction: GitAction
    ) {
        self.init(
            fingerprint: fingerprint,
            effects: effects,
            resources: resources,
            scope: scope,
            supportingCommand: supportingCommand,
            analysis: .git(gitAction)
        )
    }

    public init(
        fingerprint: ActionFingerprint,
        effects: ActionEffects = ActionEffects(),
        resources: ActionResources = ActionResources(),
        scope: ActionScope = ActionScope(),
        supportingCommand: ShellCommand? = nil,
        filesystemAction: FilesystemAction
    ) {
        self.init(
            fingerprint: fingerprint,
            effects: effects,
            resources: resources,
            scope: scope,
            supportingCommand: supportingCommand,
            analysis: .filesystem(filesystemAction)
        )
    }

    enum CodingKeys: String, CodingKey {
        case fingerprint
        case effects
        case resources
        case scope
        case supportingCommand
        case gitAction
        case filesystemAction
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fingerprint = try container.decode(ActionFingerprint.self, forKey: .fingerprint)
        effects = try container.decodeIfPresent(ActionEffects.self, forKey: .effects)
            ?? ActionEffects()
        resources = try container.decodeIfPresent(ActionResources.self, forKey: .resources)
            ?? ActionResources()
        scope = try container.decodeIfPresent(ActionScope.self, forKey: .scope) ?? ActionScope()
        supportingCommand = try container.decodeIfPresent(
            ShellCommand.self,
            forKey: .supportingCommand
        )
        let git = try container.decodeIfPresent(GitAction.self, forKey: .gitAction)
        let filesystem = try container.decodeIfPresent(
            FilesystemAction.self,
            forKey: .filesystemAction
        )
        if git != nil, filesystem != nil {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "ShellAction cannot decode both gitAction and filesystemAction"
                )
            )
        }
        if let git {
            analysis = .git(git)
        } else if let filesystem {
            analysis = .filesystem(filesystem)
        } else {
            analysis = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fingerprint, forKey: .fingerprint)
        try container.encode(effects, forKey: .effects)
        try container.encode(resources, forKey: .resources)
        try container.encode(scope, forKey: .scope)
        try container.encodeIfPresent(supportingCommand, forKey: .supportingCommand)
        switch analysis {
        case .git(let git):
            try container.encode(git, forKey: .gitAction)
        case .filesystem(let filesystem):
            try container.encode(filesystem, forKey: .filesystemAction)
        case nil:
            break
        }
    }
}

/// Catalog-only Read / Edit / Write action. Never a `ShellCommand`.
public struct FileAction: Sendable, Equatable, Codable {
    public var fingerprint: ActionFingerprint
    public var file: FileToolAction
    public var effects: ActionEffects
    public var resources: ActionResources
    public var scope: ActionScope

    public init(
        fingerprint: ActionFingerprint,
        file: FileToolAction,
        effects: ActionEffects = ActionEffects(),
        resources: ActionResources = ActionResources(),
        scope: ActionScope = ActionScope()
    ) {
        self.fingerprint = fingerprint
        self.file = file
        self.effects = effects
        self.resources = resources
        self.scope = scope
    }
}

/// Closed action family. File tools are Read / Edit / Write only.
public enum ProposedAction: Sendable, Equatable, Codable {
    case shell(ShellAction)
    case file(FileAction)

    public var fingerprint: ActionFingerprint {
        switch self {
        case .shell(let action):
            return action.fingerprint
        case .file(let action):
            return action.fingerprint
        }
    }

    /// Supporting evidence only. Reviewers must use `effects` / `resources` / `scope`.
    /// File tools never carry a `ShellCommand`.
    public var supportingCommand: ShellCommand? {
        switch self {
        case .shell(let action):
            return action.supportingCommand
        case .file:
            return nil
        }
    }

    public var effects: ActionEffects {
        switch self {
        case .shell(let action):
            return action.effects
        case .file(let action):
            return action.effects
        }
    }

    public var resources: ActionResources {
        switch self {
        case .shell(let action):
            return action.resources
        case .file(let action):
            return action.resources
        }
    }

    public var scope: ActionScope {
        switch self {
        case .shell(let action):
            return action.scope
        case .file(let action):
            return action.scope
        }
    }

    public var gitAction: GitAction? {
        switch self {
        case .shell(let action):
            return action.gitAction
        case .file:
            return nil
        }
    }
}
