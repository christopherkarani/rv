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

    private enum CodingKeys: String, CodingKey {
        case gitPush
    }

    private enum GitPushKeys: String, CodingKey {
        case force
        case branch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nested = try container.nestedContainer(keyedBy: GitPushKeys.self, forKey: .gitPush)
        let force: GitPushForceConstraint
        if nested.contains(.force) {
            force = try nested.decode(GitPushForceConstraint.self, forKey: .force)
        } else {
            force = .any
        }
        let branch = try nested.decodeIfPresent(String.self, forKey: .branch)
        self = .gitPush(force: force, branch: branch)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var nested = container.nestedContainer(keyedBy: GitPushKeys.self, forKey: .gitPush)
        switch self {
        case .gitPush(let force, let branch):
            switch force {
            case .any:
                break
            case .exactly(let value):
                try nested.encode(value, forKey: .force)
            }
            try nested.encodeIfPresent(branch, forKey: .branch)
        }
    }
}

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
