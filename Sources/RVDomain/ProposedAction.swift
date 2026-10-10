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
    /// Non-force remote branch mutation (plain `git push`). Always
    /// mandatory-human: remote history changes are authority-expanding and
    /// hard to reverse, but a fast-forward push is not destructive, so it
    /// asks even on shared branches instead of denying.
    case remoteBranchMutation
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

public struct ActionScope: Sendable, Equatable, Codable {
    public var workingDirectory: WorkingDirectory?

    public init(workingDirectory: WorkingDirectory? = nil) {
        self.workingDirectory = workingDirectory
    }
}

/// Effect-only shell: stored fingerprint/effects/resources with no analyzed subject.
public struct EffectShell: Sendable, Equatable, Codable {
    public var fingerprint: ActionFingerprint
    public var effects: ActionEffects
    public var resources: ResourceScope
    public var scope: ActionScope
    /// Supporting evidence only. Never the primary review input.
    public var supportingCommand: ShellCommand?

    public init(
        fingerprint: ActionFingerprint,
        effects: ActionEffects = ActionEffects(),
        resources: ResourceScope = ResourceScope.none,
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

/// Analyzed shell: effects/resources computed from the non-optional subject.
public struct AnalyzedShell: Sendable, Equatable, Codable {
    public var fingerprint: ActionFingerprint
    public var scope: ActionScope
    /// Supporting evidence only. Never the primary review input.
    public var supportingCommand: ShellCommand?
    public var analysis: SemanticAction

    public var effects: ActionEffects { analysis.effects }
    public var resources: ResourceScope { analysis.resources }

    public init(
        fingerprint: ActionFingerprint,
        scope: ActionScope = ActionScope(),
        supportingCommand: ShellCommand? = nil,
        analysis: SemanticAction
    ) {
        self.fingerprint = fingerprint
        self.scope = scope
        self.supportingCommand = supportingCommand
        self.analysis = analysis
    }

    /// Flat wire shape identical to an analyzed `ShellAction`. `SemanticAction`
    /// is not `Codable`, so the subject round-trips through the XOR labels.
    public init(from decoder: Decoder) throws {
        let shell = try ShellAction(from: decoder)
        guard case .analyzed(let analyzed) = shell else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "AnalyzedShell requires a gitAction or filesystemAction subject"
                )
            )
        }
        self = analyzed
    }

    public func encode(to encoder: Encoder) throws {
        try ShellAction.analyzed(self).encode(to: encoder)
    }
}

/// Semantic shell action: effect-only or analyzed, never both.
///
/// `.effectOnly` stores `effects` and `resources` and has no subject.
/// `.analyzed` computes both bags from its subject, so a stored bag
/// disagreeing with its subject is unrepresentable.
///
/// The raw command, if present, is supporting evidence only.
///
/// Codable keeps the XOR labels `gitAction` and `filesystemAction`, omits the
/// unused key (does not write null), and never encodes `analysis`. Decode fails
/// if both keys have values. Stored bags on an analyzed shell are ignored in
/// favor of the subject projection. Absent bag keys on an effect-only shell
/// use empty defaults.
public enum ShellAction: Sendable, Equatable, Codable {
    case effectOnly(EffectShell)
    case analyzed(AnalyzedShell)

    public var fingerprint: ActionFingerprint {
        switch self {
        case .effectOnly(let shell):
            return shell.fingerprint
        case .analyzed(let shell):
            return shell.fingerprint
        }
    }

    public var effects: ActionEffects {
        switch self {
        case .effectOnly(let shell):
            return shell.effects
        case .analyzed(let shell):
            return shell.effects
        }
    }

    public var resources: ResourceScope {
        switch self {
        case .effectOnly(let shell):
            return shell.resources
        case .analyzed(let shell):
            return shell.resources
        }
    }

    public var scope: ActionScope {
        switch self {
        case .effectOnly(let shell):
            return shell.scope
        case .analyzed(let shell):
            return shell.scope
        }
    }

    public var supportingCommand: ShellCommand? {
        switch self {
        case .effectOnly(let shell):
            return shell.supportingCommand
        case .analyzed(let shell):
            return shell.supportingCommand
        }
    }

    /// Git projection of the analyzed subject. Nil for effect-only shells.
    public var gitAction: GitAction? {
        switch self {
        case .effectOnly:
            return nil
        case .analyzed(let shell):
            if case .git(let action) = shell.analysis {
                return action
            }
            return nil
        }
    }

    /// Filesystem projection of the analyzed subject. Nil for effect-only shells.
    public var filesystemAction: FilesystemAction? {
        switch self {
        case .effectOnly:
            return nil
        case .analyzed(let shell):
            if case .filesystem(let action) = shell.analysis {
                return action
            }
            return nil
        }
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
        let fingerprint = try container.decode(ActionFingerprint.self, forKey: .fingerprint)
        let scope = try container.decodeIfPresent(ActionScope.self, forKey: .scope) ?? ActionScope()
        let supportingCommand = try container.decodeIfPresent(
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
            self = .analyzed(
                AnalyzedShell(
                    fingerprint: fingerprint,
                    scope: scope,
                    supportingCommand: supportingCommand,
                    analysis: .git(git)
                )
            )
        } else if let filesystem {
            self = .analyzed(
                AnalyzedShell(
                    fingerprint: fingerprint,
                    scope: scope,
                    supportingCommand: supportingCommand,
                    analysis: .filesystem(filesystem)
                )
            )
        } else {
            self = .effectOnly(
                EffectShell(
                    fingerprint: fingerprint,
                    effects: try container.decodeIfPresent(ActionEffects.self, forKey: .effects)
                        ?? ActionEffects(),
                    resources: try container.decodeIfPresent(ResourceScope.self, forKey: .resources)
                        ?? ResourceScope.none,
                    scope: scope,
                    supportingCommand: supportingCommand
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fingerprint, forKey: .fingerprint)
        try container.encode(effects, forKey: .effects)
        try container.encode(resources, forKey: .resources)
        try container.encode(scope, forKey: .scope)
        try container.encodeIfPresent(supportingCommand, forKey: .supportingCommand)
        switch self {
        case .effectOnly:
            break
        case .analyzed(let shell):
            switch shell.analysis {
            case .git(let git):
                try container.encode(git, forKey: .gitAction)
            case .filesystem(let filesystem):
                try container.encode(filesystem, forKey: .filesystemAction)
            }
        }
    }
}

/// Catalog-only Read / Edit / Write action. Never a `ShellCommand`.
///
/// `effects` and `resources` are computed from `file`, so a stored bag
/// disagreeing with its subject is unrepresentable (ShellAction analyzed
/// pattern). `scope` stays stored: it is request context, not a file fact.
public struct FileAction: Sendable, Equatable, Codable {
    public var fingerprint: ActionFingerprint
    public var file: FileToolAction
    public var scope: ActionScope

    /// File tools carry no typed effects; policy reviews the subject.
    public var effects: ActionEffects { ActionEffects() }

    /// Path-only filesystem projection of `file`.
    public var resources: ResourceScope {
        .filesystem(path: file.path.rawValue, scope: .unknown, kind: .unknown)
    }

    public init(
        fingerprint: ActionFingerprint,
        file: FileToolAction,
        scope: ActionScope = ActionScope()
    ) {
        self.fingerprint = fingerprint
        self.file = file
        self.scope = scope
    }

    enum CodingKeys: String, CodingKey {
        case fingerprint
        case file
        case effects
        case resources
        case scope
    }

    /// Legacy keys decode tolerantly: stored bags are ignored in favor
    /// of the subject projection. Disagreeing bags resolve to derived
    /// values. Encode keeps the legacy keys so wire bytes are unchanged.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fingerprint = try container.decode(ActionFingerprint.self, forKey: .fingerprint)
        file = try container.decode(FileToolAction.self, forKey: .file)
        scope = try container.decodeIfPresent(ActionScope.self, forKey: .scope) ?? ActionScope()
        _ = try container.decodeIfPresent(ActionEffects.self, forKey: .effects)
        _ = try container.decodeIfPresent(ResourceScope.self, forKey: .resources)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fingerprint, forKey: .fingerprint)
        try container.encode(file, forKey: .file)
        try container.encode(effects, forKey: .effects)
        try container.encode(resources, forKey: .resources)
        try container.encode(scope, forKey: .scope)
    }
}

/// Closed action family. File tools are Read / Edit / Write only.
public enum ProposedAction: Sendable, Equatable, Codable {
    case shell(ShellAction)
    case file(FileAction)
    case http(HTTPAction)

    public var fingerprint: ActionFingerprint {
        switch self {
        case .shell(let action):
            return action.fingerprint
        case .file(let action):
            return action.fingerprint
        case .http(let action):
            return action.fingerprint
        }
    }

    /// Supporting evidence only. Reviewers must use `effects` / `resources` / `scope`.
    /// File tools never carry a `ShellCommand`.
    public var supportingCommand: ShellCommand? {
        switch self {
        case .shell(let action):
            return action.supportingCommand
        case .file, .http:
            return nil
        }
    }

    public var effects: ActionEffects {
        switch self {
        case .shell(let action):
            return action.effects
        case .file(let action):
            return action.effects
        case .http(let action):
            return action.effects
        }
    }

    public var resources: ResourceScope {
        switch self {
        case .shell(let action):
            return action.resources
        case .file(let action):
            return action.resources
        case .http(let action):
            return action.resources
        }
    }

    public var scope: ActionScope {
        switch self {
        case .shell(let action):
            return action.scope
        case .file(let action):
            return action.scope
        case .http(let action):
            return action.scope
        }
    }

    public var gitAction: GitAction? {
        switch self {
        case .shell(let action):
            return action.gitAction
        case .file, .http:
            return nil
        }
    }
}
