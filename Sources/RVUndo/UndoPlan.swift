import Foundation
import RVDomain

/// Why rv kept a copy: the command went through in watch mode, or after
/// the person unlocked it.
public enum UndoReason: String, Sendable, Equatable, Codable {
    case watched
    case unlocked
}

/// What a destructive command would throw away, as far as a copy goes.
public enum UndoTarget: Sendable, Equatable {
    /// Unsaved changes to tracked files and where HEAD is (`reset --hard`,
    /// `checkout -- .`, `restore`, `switch -f`): kept as git refs.
    case gitWorkingTree
    /// Untracked files (`git clean -f`): kept as file copies.
    case gitUntracked
    /// Paths a delete removes (`rm`, `find -delete`, `unlink`), absolute
    /// and not resolved past their last component (a symlink is the link).
    case paths([UndoPath])
}

/// One path a delete names.
public struct UndoPath: Sendable, Equatable, Codable {
    public var path: String
    /// rv's secret-path matcher named it: never copied.
    public var isSecret: Bool

    public init(path: String, isSecret: Bool = false) {
        self.path = path
        self.isSecret = isSecret
    }
}

/// A request to keep a copy, before the command runs.
public struct UndoRequest: Sendable, Equatable {
    public var target: UndoTarget
    /// The command's working directory; its repository is the scope.
    public var cwd: String
    /// The command as rv's records show it (redacted).
    public var command: String
    /// The agent host that ran it (`claude`).
    public var host: String
    public var reason: UndoReason
    /// The longest the copy may take; past it, rv skips with a note.
    public var budget: Duration

    public init(
        target: UndoTarget, cwd: String, command: String, host: String, reason: UndoReason,
        budget: Duration = UndoLimits.defaultBudget
    ) {
        self.target = target
        self.cwd = cwd
        self.command = command
        self.host = host
        self.reason = reason
        self.budget = budget
    }
}

/// Bounds that keep a copy from slowing a hook or filling a disk.
public enum UndoLimits {
    /// Copies older than this are pruned.
    public static let retention: TimeInterval = 7 * 24 * 60 * 60
    /// Largest copy, in bytes, before rv skips it with a note.
    public static let maxBytes: UInt64 = 256 * 1024 * 1024
    /// Most files and directories one copy may hold.
    public static let maxEntries = 20_000
    /// Deepest a kept tree may nest.
    public static let maxDepth = 64
    /// The whole store: at most this many copies and bytes; the oldest
    /// go first.
    public static let storeMaxCopies = 50
    public static let storeMaxBytes: UInt64 = 2 * 1024 * 1024 * 1024
    /// Free space a copy must leave on the disk.
    public static let freeSpaceFloor: UInt64 = 1024 * 1024 * 1024
    /// The longest a copy may take on the hook path.
    public static let defaultBudget: Duration = .milliseconds(1_500)
}

/// Which commands get a copy. Pure: the analysis rv already made decides,
/// so only the destructive classes ever pay for a copy.
public enum UndoPlan {
    /// The copy `analysis` calls for, or nil when it throws nothing away
    /// that a copy could bring back.
    public static func target(for analysis: SemanticAnalysis, cwd: String) -> UndoTarget? {
        if let git = analysis.gitAction { return target(for: git) }
        if case .delete(let targets, _, _)? = analysis.filesystemAction {
            let paths = targets.compactMap { path(for: $0, cwd: cwd) }
            return paths.isEmpty ? nil : .paths(paths)
        }
        return nil
    }

    static func target(for git: GitAction) -> UndoTarget? {
        switch git {
        case .reset(.hard, _), .reset(.merge, _), .discardWorktree, .switchBranch(_, true),
            .restore(_, .worktree, _), .restore(_, .worktreeAndIndex, _):
            return .gitWorkingTree
        case .clean(true, false, _):
            return .gitUntracked
        default:
            return nil
        }
    }

    /// The path a delete removes. A target rv resolved through a symlink
    /// is kept as written, so the copy is of the link, never of what it
    /// points at. A path rv could not place (`~`, a variable) is left out.
    static func path(for target: FilesystemTarget, cwd: String) -> UndoPath? {
        let isSecret = target.protectedMatch != nil
        if target.followedSymlink == false, target.canonical.hasPrefix("/") {
            return UndoPath(path: target.canonical, isSecret: isSecret)
        }
        let apparent = target.apparent
        guard apparent.isEmpty == false, apparent.hasPrefix("~") == false, apparent.contains("$") == false
        else { return nil }
        let joined = apparent.hasPrefix("/") ? apparent : (cwd.hasSuffix("/") ? cwd : cwd + "/") + apparent
        return UndoPath(path: lexicallyNormalized(joined), isSecret: isSecret)
    }

    /// `/a/./b/../c/` → `/a/c`. No filesystem access.
    static func lexicallyNormalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if parts.isEmpty == false { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }
}
