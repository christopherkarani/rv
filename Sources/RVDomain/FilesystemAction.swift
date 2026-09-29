/// Security scope after canonicalize. Protected wins over repository boundary.
public enum FilesystemScope: Sendable, Equatable, Codable {
    case insideRepository
    case outsideRepository
    case protectedPath(SecretPathMatch)
    case unknown

    /// Case name for display. Associated match is not part of this string.
    public var rawValue: String {
        switch self {
        case .insideRepository:
            return "insideRepository"
        case .outsideRepository:
            return "outsideRepository"
        case .protectedPath:
            return "protectedPath"
        case .unknown:
            return "unknown"
        }
    }

    public var protectedMatch: SecretPathMatch? {
        if case .protectedPath(let match) = self {
            return match
        }
        return nil
    }
}

/// Closed filesystem mutation family used by policy. Write covers overwrite and mode change.
package enum FilesystemOperationKind: String, Sendable, Equatable, Codable {
    case read
    case write
    case create
    case move
    case delete
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

    public var protectedMatch: SecretPathMatch? {
        scope.protectedMatch
    }

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
    case create(targets: [FilesystemTarget])
    case read(targets: [FilesystemTarget])

    package var operationKind: FilesystemOperationKind {
        switch self {
        case .read:
            return .read
        case .overwrite, .chmod:
            return .write
        case .create:
            return .create
        case .move:
            return .move
        case .delete:
            return .delete
        }
    }

    public var targets: [FilesystemTarget] {
        switch self {
        case .delete(let targets, _, _),
            .overwrite(let targets),
            .chmod(let targets, _, _),
            .create(let targets),
            .read(let targets):
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
        case .create:
            return "create"
        case .read:
            return "read"
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

    /// Display string for the protected category (e.g. "ssh", "keychain").
    /// Kept as `String?` not `SecretPathCategory` to keep `RVPresentation`/`RVTUI`
    /// decoupled from the domain enum and to avoid leaking the enum via Codable.
    public var explainCategory: String? {
        primaryTarget?.protectedMatch?.category.rawValue
    }

    public var explainCatalogRule: String? {
        primaryTarget?.protectedMatch.map { $0.ruleID.slashDisplay }
    }

    public func proposedAction(
        command: ShellCommand,
        workingDirectory: WorkingDirectory?
    ) -> ProposedAction {
        .shell(
            ShellAction(
                fingerprint: ActionFingerprint(rawValue: fingerprint),
                scope: ActionScope(workingDirectory: workingDirectory),
                supportingCommand: command,
                filesystemAction: self
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
        case .create:
            kinds.append(.filesystemCreate)
        case .read:
            kinds.append(.filesystemRead)
        }
        if targets.contains(where: { $0.resolution == .uncertain || $0.scope == .unknown }) {
            kinds.append(.unresolvedFilesystem)
        }
        if operationKind != .read,
            targets.contains(where: { $0.scope == .outsideRepository && $0.resolution != .uncertain })
        {
            kinds.append(.outsideRepositoryMutation)
        }
        // Guard reads like `outsideRepositoryMutation`: `cat ~/.ssh/config` is
        // still denied via `SecretPathGuard` (core.secrets), but the filesystem
        // effect is conservative and only marks mutating operations.
        if operationKind != .read,
            targets.contains(where: { $0.scope.protectedMatch != nil })
        {
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
        case .create:
            return "shell:fs.create:\(paths)"
        case .read:
            return "shell:fs.read:\(paths)"
        }
    }

    /// Rank by security class, then resource kind. Do not use `FilesystemScope.==`:
    /// `.protectedPath` carries a match payload, which is not a different class.
    private static func isLessSevere(_ left: FilesystemTarget, _ right: FilesystemTarget) -> Bool {
        let leftScope = scopeRank(left.scope)
        let rightScope = scopeRank(right.scope)
        if leftScope != rightScope {
            return leftScope < rightScope
        }
        return kindRank(left.kind) < kindRank(right.kind)
    }

    private static func scopeRank(_ scope: FilesystemScope) -> Int {
        switch scope {
        case .insideRepository:
            return 1
        case .outsideRepository:
            return 2
        case .unknown:
            return 3
        case .protectedPath:
            return 4
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
