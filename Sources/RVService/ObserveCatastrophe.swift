import RVDomain
import RVPolicy

/// The catastrophic commands observe mode still stops (Q5): a pack deny
/// that wipes a disk or a filesystem, or deletes the root, the home
/// directory or a top-level system directory as a whole. Observe enforces
/// such a deny with its own rule id, row and allow-once path, as enforce
/// does (`ObserveFloor.rule`, rule 3).
///
/// Lexical scope: the pack rule names the class, the analyzed targets
/// name the place. A delete rule (`core.filesystem:rm-rf-root-home` and
/// kin) matches any path under `/` or `~`, so it is catastrophic only
/// when a target is that root itself (`rm -rf ~`, `rm -rf /usr`), never
/// for `rm -rf ~/project/build`. A disk rule (`system.disk`) is always
/// device-wide.
enum ObserveCatastrophe {
    /// Device-wide wipes, formats, erases and partition-table writes.
    static let diskRules: Set<RuleID> = Set([
        "dd-device", "dd-wipe", "mkfs", "mkfs-variants", "mkswap", "wipefs", "blkdiscard",
        "sgdisk-destroy", "sfdisk-write", "fdisk-edit", "parted-modify", "nvme-erase", "sg-format",
        "hdparm-erase", "cryptsetup-destroy", "badblocks-write", "diskutil-erase", "diskutil-partition",
        "diskutil-apfs-delete", "zpool-destroy", "mdadm-zero-superblock",
    ].map { RuleID(pack: .systemDisk, pattern: $0) })

    /// Recursive or bulk deletes, catastrophic only on a root target.
    static let rootDeleteRules: Set<RuleID> = Set([
        "rm-rf-root-home", "rm-r-f-separate-root-home", "rm-recursive-force-root-home",
        "find-delete-root-home", "shred-root-home", "tar-remove-files-root-home",
    ].map { RuleID(pack: .coreFilesystem, pattern: $0) })

    static let forkBomb = RuleID(pack: .coreFilesystem, pattern: "fork-bomb")

    /// Top-level directories whose loss breaks the machine (Linux and macOS).
    static let systemRoots: Set<String> = [
        "/", "/bin", "/boot", "/dev", "/etc", "/home", "/lib", "/lib64", "/opt", "/proc", "/root",
        "/sbin", "/sys", "/usr", "/var", "/Applications", "/Library", "/System", "/Users", "/Volumes",
        "/private", "/private/etc", "/private/var",
    ]

    static func isCatastrophic(_ result: EvaluationResult, home: HomeDirectory?) -> Bool {
        guard case .deny(let deny) = result.decision else { return false }
        if diskRules.contains(deny.ruleID) || deny.ruleID == forkBomb { return true }
        guard rootDeleteRules.contains(deny.ruleID) else { return false }
        let targets = result.analysis.filesystemAction?.targets ?? []
        return targets.contains { target in
            [target.canonical, target.apparent].contains { isRoot($0, home: home) }
        }
    }

    private static func isRoot(_ path: String, home: HomeDirectory?) -> Bool {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        if systemRoots.contains(trimmed) || ["~", "$HOME", "${HOME}"].contains(trimmed) { return true }
        guard let home else { return false }
        var homePath = home.rawValue
        while homePath.count > 1, homePath.hasSuffix("/") { homePath.removeLast() }
        return trimmed == homePath
    }
}
