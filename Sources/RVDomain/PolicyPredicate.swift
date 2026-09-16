/// Unspecified force (TOML omit) versus a pinned `GitPushForce`.
/// `.any` is not `GitPushForce.none`; `.none` is non-force.
public enum GitPushForceConstraint: Sendable, Equatable {
    case any
    case exactly(GitPushForce)
}

/// Closed policy matcher. Branch nil is unspecified.
/// Write `.exactly(.none)` for a non-force push; `.any` when force is omitted.
public enum PolicyPredicate: Sendable, Equatable, Codable {
    /// Matches `GitAction.push`. `supportingCommand` is not part of this form.
    case gitPush(force: GitPushForceConstraint, branch: String?)
    /// Matches discard / restore-to-worktree. Nil pathspec is unspecified.
    case gitDiscardWorktree(pathspec: String?)
    /// Matches `GitAction.reset`. Nil mode is unspecified.
    case gitReset(mode: GitResetMode?)
    /// Matches `GitAction.clean`. Nil flags are unspecified.
    case gitClean(force: Bool?, directories: Bool?)
    /// Matches `FilesystemAction.delete`. Nil flags are unspecified.
    case filesystemDelete(recursive: Bool?, force: Bool?)
    /// Matches `FilesystemAction.move`.
    case filesystemMove

    private enum CodingKeys: String, CodingKey {
        case gitPush
        case gitDiscardWorktree
        case gitReset
        case gitClean
        case filesystemDelete
        case filesystemMove
    }

    private enum GitPushKeys: String, CodingKey {
        case force
        case branch
    }

    private enum PathspecKeys: String, CodingKey {
        case pathspec
    }

    private enum ResetKeys: String, CodingKey {
        case mode
    }

    private enum CleanKeys: String, CodingKey {
        case force
        case directories
    }

    private enum DeleteKeys: String, CodingKey {
        case recursive
        case force
    }

    private enum EmptyKeys: CodingKey {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.gitPush) {
            let nested = try container.nestedContainer(keyedBy: GitPushKeys.self, forKey: .gitPush)
            let force: GitPushForceConstraint
            if nested.contains(.force) {
                force = try nested.decode(GitPushForceConstraint.self, forKey: .force)
            } else {
                force = .any
            }
            let branch = try nested.decodeIfPresent(String.self, forKey: .branch)
            self = .gitPush(force: force, branch: branch)
            return
        }
        if container.contains(.gitDiscardWorktree) {
            let nested = try container.nestedContainer(keyedBy: PathspecKeys.self, forKey: .gitDiscardWorktree)
            self = .gitDiscardWorktree(pathspec: try nested.decodeIfPresent(String.self, forKey: .pathspec))
            return
        }
        if container.contains(.gitReset) {
            let nested = try container.nestedContainer(keyedBy: ResetKeys.self, forKey: .gitReset)
            self = .gitReset(mode: try nested.decodeIfPresent(GitResetMode.self, forKey: .mode))
            return
        }
        if container.contains(.gitClean) {
            let nested = try container.nestedContainer(keyedBy: CleanKeys.self, forKey: .gitClean)
            self = .gitClean(
                force: try nested.decodeIfPresent(Bool.self, forKey: .force),
                directories: try nested.decodeIfPresent(Bool.self, forKey: .directories)
            )
            return
        }
        if container.contains(.filesystemDelete) {
            let nested = try container.nestedContainer(keyedBy: DeleteKeys.self, forKey: .filesystemDelete)
            self = .filesystemDelete(
                recursive: try nested.decodeIfPresent(Bool.self, forKey: .recursive),
                force: try nested.decodeIfPresent(Bool.self, forKey: .force)
            )
            return
        }
        if container.contains(.filesystemMove) {
            _ = try container.nestedContainer(keyedBy: EmptyKeys.self, forKey: .filesystemMove)
            self = .filesystemMove
            return
        }
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "unknown PolicyPredicate")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .gitPush(let force, let branch):
            var nested = container.nestedContainer(keyedBy: GitPushKeys.self, forKey: .gitPush)
            switch force {
            case .any:
                break
            case .exactly(let value):
                try nested.encode(value, forKey: .force)
            }
            try nested.encodeIfPresent(branch, forKey: .branch)
        case .gitDiscardWorktree(let pathspec):
            var nested = container.nestedContainer(keyedBy: PathspecKeys.self, forKey: .gitDiscardWorktree)
            try nested.encodeIfPresent(pathspec, forKey: .pathspec)
        case .gitReset(let mode):
            var nested = container.nestedContainer(keyedBy: ResetKeys.self, forKey: .gitReset)
            try nested.encodeIfPresent(mode, forKey: .mode)
        case .gitClean(let force, let directories):
            var nested = container.nestedContainer(keyedBy: CleanKeys.self, forKey: .gitClean)
            try nested.encodeIfPresent(force, forKey: .force)
            try nested.encodeIfPresent(directories, forKey: .directories)
        case .filesystemDelete(let recursive, let force):
            var nested = container.nestedContainer(keyedBy: DeleteKeys.self, forKey: .filesystemDelete)
            try nested.encodeIfPresent(recursive, forKey: .recursive)
            try nested.encodeIfPresent(force, forKey: .force)
        case .filesystemMove:
            try container.encode(EmptyObject(), forKey: .filesystemMove)
        }
    }
}

private struct EmptyObject: Codable {}

extension GitPushForceConstraint: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .any
            return
        }
        self = .exactly(try container.decode(GitPushForce.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .any:
            try container.encodeNil()
        case .exactly(let force):
            try container.encode(force)
        }
    }
}
