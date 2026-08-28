/// Security scope after canonicalize. Protected wins over repository boundary.
public enum FilesystemScope: String, Sendable, Equatable, Codable {
    case insideRepository
    case outsideRepository
    case protectedPath
    case unknown
}

/// File kind when path evidence exists. Generated and source stay distinct.
public enum FilesystemResourceKind: String, Sendable, Equatable, Codable {
    case generatedOutput
    case sourceCode
    case unknown
}

/// How a target path was resolved. Uncertain never extra-allows.
public enum FilesystemResolution: String, Sendable, Equatable, Codable {
    case resolved
    case lexical
    case uncertain
}

/// Observed or injected resolution of one operand.
public struct FilesystemPathFact: Sendable, Equatable, Codable {
    public var apparent: String
    public var canonical: String
    public var followedSymlink: Bool
    public var resolution: FilesystemResolution

    public init(
        apparent: String,
        canonical: String,
        followedSymlink: Bool = false,
        resolution: FilesystemResolution = .lexical
    ) {
        self.apparent = apparent
        self.canonical = canonical
        self.followedSymlink = followedSymlink
        self.resolution = resolution
    }
}

/// One filesystem target after canonicalize and classification.
public struct FilesystemTarget: Sendable, Equatable, Codable {
    public var apparent: String
    public var canonical: String
    public var scope: FilesystemScope
    public var kind: FilesystemResourceKind
    public var followedSymlink: Bool
    public var resolution: FilesystemResolution

    public init(
        apparent: String,
        canonical: String,
        scope: FilesystemScope,
        kind: FilesystemResourceKind,
        followedSymlink: Bool = false,
        resolution: FilesystemResolution = .lexical
    ) {
        self.apparent = apparent
        self.canonical = canonical
        self.scope = scope
        self.kind = kind
        self.followedSymlink = followedSymlink
        self.resolution = resolution
    }
}

/// High-value filesystem mutation. Flags and typed targets live on the case.
public enum FilesystemAction: Sendable, Equatable, Codable {
    case delete(targets: [FilesystemTarget], recursive: Bool, force: Bool)
    case move(sources: [FilesystemTarget], destination: FilesystemTarget)
    case overwrite(targets: [FilesystemTarget])
    case chmod(targets: [FilesystemTarget], mode: String?, recursive: Bool)

    public var targets: [FilesystemTarget] {
        switch self {
        case .delete(let targets, _, _), .overwrite(let targets), .chmod(let targets, _, _):
            return targets
        case .move(let sources, let destination):
            return sources + [destination]
        }
    }

    public var primaryTarget: FilesystemTarget? {
        targets.max(by: Self.isLessSevere)
    }

    public var effects: ActionEffects {
        ActionEffects(kinds: effectKinds)
    }

    public var resources: ActionResources {
        let target = primaryTarget
        return ActionResources(
            path: target?.canonical,
            filesystemScope: target?.scope,
            resourceKind: target?.kind
        )
    }

    public var explainAction: String {
        switch self {
        case .delete:
            return "delete"
        case .move:
            return "move"
        case .overwrite:
            return "overwrite"
        case .chmod:
            return "chmod"
        }
    }

    public var explainScope: String {
        switch primaryTarget?.scope {
        case .insideRepository:
            return "inside repo"
        case .outsideRepository:
            return "outside repo"
        case .protectedPath:
            return "protected path"
        case .unknown, nil:
            return "unknown"
        }
    }

    public var explainEffect: String? {
        explainKind
    }

    public var explainPath: String? {
        primaryTarget?.canonical
    }

    public var explainKind: String? {
        switch primaryTarget?.kind {
        case .generatedOutput:
            return "generated output"
        case .sourceCode:
            return "source code"
        case .unknown, nil:
            return nil
        }
    }

    public func proposedAction(
        command: ShellCommand,
        workingDirectory: WorkingDirectory?
    ) -> ProposedAction {
        .shell(
            ShellAction(
                fingerprint: ActionFingerprint(rawValue: fingerprint),
                effects: effects,
                resources: resources,
                scope: ActionScope(workingDirectory: workingDirectory),
                supportingCommand: command
            )
        )
    }

    private var effectKinds: [ActionEffectKind] {
        var kinds: [ActionEffectKind] = []
        switch self {
        case .delete:
            kinds.append(.filesystemDelete)
        case .move:
            kinds.append(.filesystemMove)
        case .overwrite:
            kinds.append(.filesystemOverwrite)
        case .chmod:
            kinds.append(.filesystemModeChange)
        }
        if targets.contains(where: { $0.scope == .protectedPath && $0.resolution != .uncertain }) {
            kinds.append(.protectedPathMutation)
        }
        return kinds
    }

    private var fingerprint: String {
        let paths = targets.map(\.canonical).joined(separator: ",")
        switch self {
        case .delete(_, let recursive, let force):
            return "shell:fs.delete:\(recursive):\(force):\(paths)"
        case .move:
            return "shell:fs.move:\(paths)"
        case .overwrite:
            return "shell:fs.overwrite:\(paths)"
        case .chmod(_, let mode, let recursive):
            return "shell:fs.chmod:\(recursive):\(mode ?? ""):\(paths)"
        }
    }

    private static func isLessSevere(_ left: FilesystemTarget, _ right: FilesystemTarget) -> Bool {
        if left.scope != right.scope {
            return scopeRank(left.scope) < scopeRank(right.scope)
        }
        return kindRank(left.kind) < kindRank(right.kind)
    }

    private static func scopeRank(_ scope: FilesystemScope) -> Int {
        switch scope {
        case .unknown:
            return 0
        case .insideRepository:
            return 1
        case .outsideRepository:
            return 2
        case .protectedPath:
            return 3
        }
    }

    private static func kindRank(_ kind: FilesystemResourceKind) -> Int {
        switch kind {
        case .unknown:
            return 0
        case .generatedOutput:
            return 1
        case .sourceCode:
            return 2
        }
    }
}
