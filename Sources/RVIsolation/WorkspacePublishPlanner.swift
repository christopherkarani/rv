#if os(macOS)
import Darwin
import Foundation

/// One planned mutation of the saved tree. Steps run in this order:
/// case-only renames of captured names (shallowest first), new
/// directories, staged new files, in-place updates, installs of staged
/// files and new symlinks, retirement of removed names, then directory
/// modes deepest first. A directory therefore stays writable while its
/// children change.
enum PublishStep: Equatable {
    /// Respell captured `from` as `to`, its case-only variant in the
    /// same directory. `relative` is the new spelling.
    case renameCase(from: String, to: String)
    case makeDirectory(String)
    case stageFile(String, mode_t)
    case updateFile(String, mode_t)
    case replaceSymlink(String, target: String)
    case installFile(String)
    case createSymlink(String, target: String)
    case retire(String)
    case setDirectoryMode(String, mode_t)

    var relative: String {
        switch self {
        case .renameCase(_, let relative), .makeDirectory(let relative), .stageFile(let relative, _),
            .updateFile(let relative, _), .replaceSymlink(let relative, _),
            .installFile(let relative), .createSymlink(let relative, _),
            .retire(let relative), .setDirectoryMode(let relative, _):
            return relative
        }
    }
}

enum PublishPlan: Equatable {
    case planned([PublishStep])
    case rejected([WorkspacePublishRejection])
    case stopped
}

/// The plan and the snapshot as the plan spells it. `stamps` is the
/// snapshot after case-only renames respelled it; it equals the last value
/// `PublishFacts.publishStampsChanged` received, or the input snapshot when
/// the plan stopped before renames were planned.
struct PublishPlanResult {
    let plan: PublishPlan
    let stamps: [String: WorkspaceInodeStamp]
}

/// The filesystem questions the publish planner asks, one closure each.
///
/// The planner calls these in the same order, and as many times, as the
/// pre-extraction `planPublish` did, so the window between a read and the
/// commit, and every cancel-clock stop point, is unchanged.
struct PublishFacts {
    /// The target of the volume symlink at `relative`. Nil when unreadable.
    var volumeLink: (String) -> String?
    /// The saved tree's inode at `relative`. `stamps` is the planner's
    /// current spelling of the snapshot; it always equals the value last
    /// sent to `publishStampsChanged`. Nil when the name is missing or the
    /// walk to it is refused.
    var savedStamp: (String, [String: WorkspaceInodeStamp]) -> WorkspaceInodeStamp?
    /// The target of the saved symlink at `relative`. Nil when unreadable.
    var savedLink: (String) -> String?
    /// Whether the saved tree folds case. Nil is a clock stop.
    var savedFoldsCase: () -> Bool?
    /// Whether every saved name under the removed directory `relative` is
    /// itself in `removed`. Nil when the subtree could not be read.
    var removedSubtreeOwned: (String, Set<String>) -> Bool?
    /// True when the cancel clock has run out and planning must stop.
    var shouldStop: () -> Bool
    /// The planner respelled the snapshot. Called once with the input
    /// snapshot when case-rename planning starts, then after each rename.
    /// The live boundary stores it, because the saved-tree walk behind
    /// `savedStamp`, `savedLink` and `removedSubtreeOwned` checks each
    /// directory it passes against the current spelling.
    var publishStampsChanged: ([String: WorkspaceInodeStamp]) -> Void
}

/// Decides every publish name without writing. Inode checks, kind checks,
/// the symlink policy, case handling, and the removed-subtree check all run
/// here; the filesystem is read only through `PublishFacts`.
enum WorkspacePublishPlanner {
    /// `special` names volume entries publish cannot copy.
    static func plan(
        volumeEntries: [String: TreeEntry],
        special: [String],
        snapshot: [String: WorkspaceInodeStamp],
        facts: PublishFacts
    ) -> PublishPlanResult {
        var rejections: [WorkspacePublishRejection] = []
        func reject(_ relative: String, _ reason: WorkspacePublishRejection.Reason) {
            rejections.append(WorkspacePublishRejection(relative: relative, reason: reason))
        }
        for relative in special {
            reject(relative, .unsupportedFileType)
        }
        var links: [String: String] = [:]
        for (relative, entry) in volumeEntries where entry.kind == .symlink {
            if facts.shouldStop() { return PublishPlanResult(plan: .stopped, stamps: snapshot) }
            guard let target = facts.volumeLink(relative) else {
                reject(relative, .unreadable)
                continue
            }
            links[relative] = target
        }
        let linkTable = WorkspaceLinkTable(links)
        let present = volumeEntries.keys.sorted { (pathDepth($0), $0) < (pathDepth($1), $1) }
        guard let caseInsensitive = facts.savedFoldsCase() else {
            return PublishPlanResult(plan: .stopped, stamps: snapshot)
        }
        // Two volume names one case-insensitive directory cannot hold.
        let collided = caseInsensitive ? caseVariantNames(present) : []
        for relative in present where collided.contains(relative) {
            reject(relative, .caseCollision)
        }
        var stamps = snapshot
        guard let renames = planCaseRenames(
            volumeEntries,
            present: present,
            skipping: collided,
            stamps: &stamps,
            facts: facts,
            reject: reject
        ) else {
            return PublishPlanResult(plan: .stopped, stamps: stamps)
        }
        func stopped() -> PublishPlanResult { PublishPlanResult(plan: .stopped, stamps: stamps) }
        var makes: [PublishStep] = []
        var stages: [PublishStep] = []
        var updates: [PublishStep] = []
        var installs: [PublishStep] = []
        var modes: [PublishStep] = []
        // Saved inodes an on-volume name resolves to. None of them may be
        // retired, whatever the snapshot says about another spelling.
        var claimed = Set<WorkspaceInodeKey>()
        for relative in present where collided.contains(relative) == false {
            if facts.shouldStop() { return stopped() }
            guard let entry = volumeEntries[relative] else { continue }
            let saved = facts.savedStamp(relative, stamps)
            if let saved { claimed.insert(WorkspaceInodeKey(saved)) }
            switch workspacePublishDecision(snapshot: stamps[relative], saved: saved, onVolume: true) {
            case .update:
                guard let saved, saved.kind == entry.kind else {
                    reject(relative, .kindChanged)
                    continue
                }
                switch entry.kind {
                case .directory:
                    modes.append(.setDirectoryMode(relative, entry.mode))
                case .regular:
                    updates.append(.updateFile(relative, entry.mode))
                case .symlink:
                    guard let target = links[relative] else { continue }
                    guard let current = facts.savedLink(relative) else {
                        reject(relative, .unreadable)
                        continue
                    }
                    // An untouched link is not rewritten, so a link the
                    // project already had is never judged by the policy.
                    if current == target { continue }
                    guard workspaceSymlinkTargetStaysInside(link: relative, target: target, links: linkTable) else {
                        reject(relative, .symlinkEscapesWorkspace)
                        continue
                    }
                    updates.append(.replaceSymlink(relative, target: target))
                }
            case .create:
                switch entry.kind {
                case .directory:
                    makes.append(.makeDirectory(relative))
                    modes.append(.setDirectoryMode(relative, entry.mode))
                case .regular:
                    guard stageNameIsFree(relative, volumeEntries, stamps: stamps) else {
                        reject(relative, .unreadable)
                        continue
                    }
                    stages.append(.stageFile(relative, entry.mode))
                    installs.append(.installFile(relative))
                case .symlink:
                    guard let target = links[relative] else { continue }
                    guard workspaceSymlinkTargetStaysInside(link: relative, target: target, links: linkTable) else {
                        reject(relative, .symlinkEscapesWorkspace)
                        continue
                    }
                    installs.append(.createSymlink(relative, target: target))
                }
            case .remove, .leave, .reject:
                reject(relative, .inodeChanged)
            }
        }
        var removed = Set<String>()
        for relative in stamps.keys.sorted() where volumeEntries[relative] == nil {
            if facts.shouldStop() { return stopped() }
            let saved = facts.savedStamp(relative, stamps)
            switch workspacePublishDecision(snapshot: stamps[relative], saved: saved, onVolume: false) {
            case .remove:
                if let saved, claimed.contains(WorkspaceInodeKey(saved)) {
                    // Another spelling on the volume reaches this inode.
                    reject(relative, .inodeChanged)
                } else {
                    removed.insert(relative)
                }
            case .leave:
                break
            case .update, .create, .reject:
                reject(relative, .inodeChanged)
            }
        }
        var retires: [PublishStep] = []
        for relative in removed.sorted() where removed.contains(parentRelative(relative)) == false {
            if stamps[relative]?.kind == .directory {
                switch facts.removedSubtreeOwned(relative, removed) {
                case nil:
                    if facts.shouldStop() { return stopped() }
                    reject(relative, .unreadable)
                    continue
                case false:
                    reject(relative, .unexpectedNameInRemovedDirectory)
                    continue
                case true:
                    break
                }
            }
            retires.append(.retire(relative))
        }
        guard rejections.isEmpty else {
            return PublishPlanResult(
                plan: .rejected(rejections.sorted { $0.relative < $1.relative }),
                stamps: stamps
            )
        }
        return PublishPlanResult(
            plan: .planned(renames + makes + stages + updates + installs + retires + modes.reversed()),
            stamps: stamps
        )
    }

    /// Volume names that share a directory and differ only by case.
    static func caseVariantNames(_ present: [String]) -> Set<String> {
        var groups: [String: [String]] = [:]
        for relative in present {
            let folded = parentRelative(relative) + "/" + (relative as NSString).lastPathComponent.lowercased()
            groups[folded, default: []].append(relative)
        }
        return Set(groups.values.filter { $0.count > 1 }.joined())
    }

    /// Find case-only renames of captured names and respell `stamps` to
    /// match, so the rest of the plan sees one name per inode.
    ///
    /// On a case-insensitive saved tree a volume name with no snapshot stamp
    /// can resolve to a captured inode under another spelling (`README.md`
    /// reaching `readme.md`). Planning that as an update plus a removal
    /// would write the inode and then retire it. When the resolved inode is
    /// the captured one, has one owner, sits in the same directory, and the
    /// names differ only by case, the saved name is renamed first and every
    /// later step uses the new spelling. Anything else that aliases a
    /// captured inode is refused. Nil is a clock stop.
    private static func planCaseRenames(
        _ volumeEntries: [String: TreeEntry],
        present: [String],
        skipping collided: Set<String>,
        stamps: inout [String: WorkspaceInodeStamp],
        facts: PublishFacts,
        reject: (String, WorkspacePublishRejection.Reason) -> Void
    ) -> [PublishStep]? {
        facts.publishStampsChanged(stamps)
        var owners = workspaceUniqueInodeOwners(stamps)
        var renames: [PublishStep] = []
        for relative in present where collided.contains(relative) == false {
            if facts.shouldStop() { return nil }
            guard stamps[relative] == nil,
                let saved = facts.savedStamp(relative, stamps),
                let origin = owners[WorkspaceInodeKey(saved)]
            else { continue }
            guard parentRelative(origin) == parentRelative(relative),
                (origin as NSString).lastPathComponent.lowercased()
                    == (relative as NSString).lastPathComponent.lowercased(),
                let captured = stamps[origin],
                workspaceInodeAcceptableForPublish(captured: captured, live: saved)
            else {
                reject(relative, .inodeChanged)
                continue
            }
            guard volumeEntries[origin] == nil else {
                reject(relative, .caseCollision)
                continue
            }
            renames.append(.renameCase(from: origin, to: relative))
            workspaceRespellStamps(from: origin, to: relative, stamps: &stamps, owners: &owners)
            facts.publishStampsChanged(stamps)
        }
        return renames
    }

    private static func parentRelative(_ relative: String) -> String {
        (relative as NSString).deletingLastPathComponent
    }

    /// Whether a new file's staging name is free: no snapshot name and no
    /// volume entry already uses it.
    private static func stageNameIsFree(
        _ relative: String,
        _ volumeEntries: [String: TreeEntry],
        stamps: [String: WorkspaceInodeStamp]
    ) -> Bool {
        let parent = parentRelative(relative)
        let stage = workspacePublishStageName(for: (relative as NSString).lastPathComponent)
        let staged = parent.isEmpty ? stage : parent + "/" + stage
        return stamps[staged] == nil && volumeEntries[staged] == nil
    }
}
#endif
