/// Legacy spelling of `ResourceScope`.
///
/// Kept (not removed) because consumers outside the T2 write set construct
/// and read the old 5-optional shape: `ReviewSanitizer`, `HTTPCanonical`,
/// `AgentNormalization`, `RuntimeAdmissionNormalize`, `HostCodec`,
/// `RulePinning`, `ReviewPromptBuilder`, `PendingIPC`, and their tests.
/// New code uses `ResourceScope` directly; the compatibility init and
/// accessors below preserve the old call sites with identical behavior.
public typealias ActionResources = ResourceScope

/// A git branch name. Distinct from a refspec or tag so the two cannot be
/// conflated where a branch is required (shared-branch matching).
public struct BranchName: RawRepresentable, Hashable, Sendable, Equatable, Codable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// A git remote name.
public struct RemoteName: RawRepresentable, Hashable, Sendable, Equatable, Codable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// A git tag name. Never a branch: tags travel as `.tag`, never `.branch`.
public struct TagName: RawRepresentable, Hashable, Sendable, Equatable, Codable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// The git ref a resource points at. A push/delete refspec is always
/// `.refspec`, even when it spells a plain branch name — a refspec is never
/// observable as `BranchName`.
public enum GitRef: Sendable, Equatable, Codable {
    case branch(BranchName)
    case refspec(String)
    case tag(TagName)
}

/// Closed resource subject. A git resource cannot carry a path and a
/// filesystem resource cannot carry a branch — the old 5-optional bag
/// allowed both at once.
public enum ResourceScope: Sendable, Equatable, Codable {
    case git(remote: RemoteName?, ref: GitRef?)
    case filesystem(path: String, scope: FilesystemScope, kind: FilesystemResourceKind)
    case none

    /// Remote of a git resource. Nil for filesystem resources and `.none`.
    public var gitRemote: RemoteName? {
        if case .git(let remote, _) = self {
            return remote
        }
        return nil
    }

    /// Ref of a git resource. Nil for filesystem resources and `.none`, and
    /// for git resources with no ref (e.g. an implicit-HEAD push).
    public var gitRef: GitRef? {
        if case .git(_, let ref) = self {
            return ref
        }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case remoteName
        case branchName
        case refspec
        case tagName
        case path
        case filesystemScope
        case resourceKind
    }

    /// Decode precedence: `refspec` / `tagName` (emitted only by new
    /// code, never co-emitted) win over legacy `branchName`, which wins
    /// over filesystem keys, matching the compatibility init's
    /// branch-wins rule for mixed legacy bags.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let remote = try container.decodeIfPresent(String.self, forKey: .remoteName)
            .map(RemoteName.init(rawValue:))
        if let refspec = try container.decodeIfPresent(String.self, forKey: .refspec) {
            self = .git(remote: remote, ref: .refspec(refspec))
        } else if let tag = try container.decodeIfPresent(String.self, forKey: .tagName) {
            self = .git(remote: remote, ref: .tag(TagName(rawValue: tag)))
        } else if let branch = try container.decodeIfPresent(String.self, forKey: .branchName) {
            self = .git(remote: remote, ref: Self.classifyLegacyBranch(branch))
        } else {
            let path = try container.decodeIfPresent(String.self, forKey: .path)
            let scope = try container.decodeIfPresent(
                FilesystemScope.self,
                forKey: .filesystemScope
            )
            let kind = try container.decodeIfPresent(
                FilesystemResourceKind.self,
                forKey: .resourceKind
            )
            if path != nil || scope != nil || kind != nil {
                self = .filesystem(
                    path: path ?? "",
                    scope: scope ?? .unknown,
                    kind: kind ?? .unknown
                )
            } else if remote != nil {
                self = .git(remote: remote, ref: nil)
            } else {
                self = .none
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .git(let remote, let ref):
            try container.encodeIfPresent(remote?.rawValue, forKey: .remoteName)
            switch ref {
            case .some(.branch(let name)):
                try container.encode(name.rawValue, forKey: .branchName)
            case .some(.refspec(let spec)):
                // Distinct spelling: a refspec never re-encodes as `branchName`,
                // so the old conflation cannot round-trip back into a branch.
                try container.encode(spec, forKey: .refspec)
            case .some(.tag(let name)):
                // Distinct spelling: tags keep their identity on the wire.
                try container.encode(name.rawValue, forKey: .tagName)
            case nil:
                break
            }
        case .filesystem(let path, let scope, let kind):
            try container.encode(path, forKey: .path)
            try container.encode(scope, forKey: .filesystemScope)
            try container.encode(kind, forKey: .resourceKind)
        case .none:
            break
        }
    }

    /// Legacy heuristic: old wire stored refspecs in `branchName`. A value
    /// containing `:` or starting with `+` / `refs/` is a refspec; anything
    /// else is a branch. Old tag values (which also traveled in `branchName`)
    /// decode as `.branch` — behaviorally inert, since tag resources never
    /// match branch predicates; fresh tags encode under `tagName` and
    /// round-trip exactly.
    private static func classifyLegacyBranch(_ name: String) -> GitRef {
        if name.contains(":") || name.hasPrefix("+") || name.hasPrefix("refs/") {
            return .refspec(name)
        }
        return .branch(BranchName(rawValue: name))
    }
}

extension ResourceScope {
    /// Legacy 5-optional construction. A present `branchName` wins and yields
    /// `.git` (refspec-looking values classify as `.refspec`); otherwise any
    /// filesystem key yields `.filesystem` with `.unknown` defaults; a lone
    /// `remoteName` yields `.git` with no ref; all nil yields `.none`.
    public init(
        remoteName: String? = nil,
        branchName: String? = nil,
        path: String? = nil,
        filesystemScope: FilesystemScope? = nil,
        resourceKind: FilesystemResourceKind? = nil
    ) {
        if let branchName {
            self = .git(
                remote: remoteName.map(RemoteName.init(rawValue:)),
                ref: Self.classifyLegacyBranch(branchName)
            )
        } else if path != nil || filesystemScope != nil || resourceKind != nil {
            self = .filesystem(
                path: path ?? "",
                scope: filesystemScope ?? .unknown,
                kind: resourceKind ?? .unknown
            )
        } else if let remoteName {
            self = .git(remote: RemoteName(rawValue: remoteName), ref: nil)
        } else {
            self = .none
        }
    }

    /// Legacy remote read. The remote of a `.git` resource, else nil.
    public var remoteName: String? {
        gitRemote?.rawValue
    }

    /// Legacy branch read. The ref string of a `.git` resource regardless of
    /// ref kind (a `.refspec` or `.tag` reads back its string, as before T2),
    /// else nil. New code switches on `gitRef` instead.
    public var branchName: String? {
        switch gitRef {
        case .branch(let name):
            return name.rawValue
        case .refspec(let spec):
            return spec
        case .tag(let name):
            return name.rawValue
        case nil:
            return nil
        }
    }

    /// Legacy path read. The path of a `.filesystem` resource, else nil.
    public var path: String? {
        if case .filesystem(let path, _, _) = self {
            return path
        }
        return nil
    }

    /// Legacy scope read. The scope of a `.filesystem` resource, else nil.
    public var filesystemScope: FilesystemScope? {
        if case .filesystem(_, let scope, _) = self {
            return scope
        }
        return nil
    }

    /// Legacy kind read. The kind of a `.filesystem` resource, else nil.
    public var resourceKind: FilesystemResourceKind? {
        if case .filesystem(_, _, let kind) = self {
            return kind
        }
        return nil
    }
}
