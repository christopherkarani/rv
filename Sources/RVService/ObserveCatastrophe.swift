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
/// device-wide, and so is any write onto a whole disk device under
/// another rule (`cat /dev/zero > /dev/sda`). `ObserveFloor` also reads
/// each segment of a compound command, since a pack deny ends evaluation
/// at the first one (`git push --force; dd of=/dev/sda`).
enum ObserveCatastrophe {
    /// Device-wide wipes, formats, erases and partition-table writes.
    static let diskRules: Set<RuleID> = Set([
        "dd-device", "dd-wipe", "mkfs", "mkfs-variants", "mkswap", "wipefs", "blkdiscard",
        "sgdisk-destroy", "sfdisk-write", "fdisk-edit", "parted-modify", "nvme-erase", "sg-format",
        "hdparm-erase", "cryptsetup-destroy", "badblocks-write", "diskutil-erase", "diskutil-partition",
        "diskutil-apfs-delete", "zpool-destroy", "mdadm-zero-superblock", "gdisk-edit", "ddrescue-force",
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

    /// Whether `result`, the verdict for `command` (the whole command, or
    /// one segment of it), is catastrophic. `command` nil reads the
    /// verdict alone.
    ///
    /// - A disk rule or a fork bomb always is.
    /// - Any deny whose analyzed write, delete or move target is a whole
    ///   disk device (`cat /dev/zero > /dev/sda`, `shred /dev/sda`,
    ///   `cp /dev/zero /dev/sda`), or whose words write one
    ///   (`writesDiskDevice`), is: a disk wipe under another rule.
    /// - A root-delete rule is when a target is a root (`rm -rf /usr/*`
    ///   reads as `/usr`), or one rv cannot know (`~/{}` from `xargs -I{}`).
    ///   With no analyzed target (`xargs rm -rf ~`), the delete segment's
    ///   words decide: one names a root, or one rv cannot know (`$X`,
    ///   `$(…)`, `{}`), fails closed as catastrophic.
    static func isCatastrophic(_ result: EvaluationResult, command: String? = nil, home: HomeDirectory?) -> Bool {
        guard case .deny(let deny) = result.decision else { return false }
        if diskRules.contains(deny.ruleID) || deny.ruleID == forkBomb { return true }
        if let action = result.analysis.filesystemAction, writesTargets(action).contains(where: { target in
            [target.canonical, target.apparent].contains(where: isDiskDevice)
        }) {
            return true
        }
        if let command, writesDiskDevice(command) { return true }
        guard rootDeleteRules.contains(deny.ruleID) else { return false }
        let targets = result.analysis.filesystemAction?.targets ?? []
        guard targets.isEmpty else {
            return targets.contains { target in
                // An analyzed target has its expansions resolved; only an
                // `xargs` placeholder is still unknown.
                [target.canonical, target.apparent].contains { isRoot($0, home: home) || $0.contains("{}") }
            }
        }
        guard let command else { return true }
        return deleteWords(command).contains { word in isRoot(word, home: home) || unknowable(word) }
    }

    /// A word rv cannot know until it runs: an expansion (`$X`, `$(…)`,
    /// a backtick) or an `xargs` placeholder (`{}`).
    private static func unknowable(_ word: String) -> Bool {
        word.contains("$") || word.contains("`") || word.contains("{}")
    }

    /// Verbs whose segment holds a delete's operands (`xargs` feeds one).
    private static let deleteVerbs: Set<String> = ["rm", "xargs", "find", "shred", "unlink", "tar", "srm"]

    /// The words of the segments of `command` that run a delete, so an
    /// expansion elsewhere (`cd $PROJ && … xargs rm -rf ~/build`) is not
    /// read as its target. Every word when no segment names a delete verb.
    private static func deleteWords(_ command: String) -> [String] {
        let segments = shellChainSegments(command).map(words)
        let deleting = segments.filter { segment in
            segment.contains { deleteVerbs.contains($0.split(separator: "/").last.map(String.init) ?? $0) }
        }
        return (deleting.isEmpty ? segments : deleting).flatMap { $0 }
    }

    /// The targets an action writes, deletes or moves onto (a read or a
    /// mode change wipes nothing).
    private static func writesTargets(_ action: FilesystemAction) -> [FilesystemTarget] {
        switch action {
        case .read, .chmod: []
        case .move(let sources, let destination): sources + [destination]
        case .delete, .overwrite, .create: action.targets
        }
    }

    // MARK: Disk devices

    /// A whole disk or one of its partitions: `/dev/sda`, `/dev/sdb1`,
    /// `/dev/nvme0n1`, `/dev/nvme0n1p2`, `/dev/disk2`, `/dev/rdisk2s1`,
    /// `/dev/mmcblk0p1`, `/dev/vda`, `/dev/xvda`, `/dev/hda`, `/dev/md0`,
    /// `/dev/dm-0`, `/dev/loop0`, `/dev/mapper/vg-root`,
    /// `/dev/disk/by-id/…`. Never `/dev/null`, `/dev/zero` or a tty.
    static func isDiskDevice(_ path: String) -> Bool {
        guard path.hasPrefix("/dev/") else { return false }
        let name = String(path.dropFirst("/dev/".count))
        // Device-mapper, md RAID, loop devices and stable disk names.
        for prefix in ["mapper/", "md/", "disk/by-"] where name.hasPrefix(prefix) {
            return name.count > prefix.count && name.hasSuffix("/") == false
        }
        for prefix in ["md", "dm-", "loop"] where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count)
            return rest.isEmpty == false && rest.allSatisfy { $0.isASCII && ($0.isNumber || $0 == "p") }
                && rest.first?.isNumber == true
        }
        func digits(_ text: Substring) -> Bool { text.isEmpty == false && text.allSatisfy { $0.isASCII && $0.isNumber } }
        func letters(_ text: Substring) -> Bool { text.isEmpty == false && text.allSatisfy { $0 >= "a" && $0 <= "z" } }
        // sd/hd/vd/xvd + letters + optional partition digits.
        for prefix in ["xvd", "sd", "hd", "vd"] where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count)
            let head = rest.prefix { $0 >= "a" && $0 <= "z" }
            let tail = rest.dropFirst(head.count)
            return letters(head) && (tail.isEmpty || digits(tail))
        }
        // nvme<N>[n<N>[p<N>]], mmcblk<N>[p<N>], [r]disk<N>[s<N>...].
        let patterns: [(String, [Character])] = [("nvme", ["n", "p"]), ("mmcblk", ["p"]), ("rdisk", ["s"]), ("disk", ["s"])]
        for (prefix, separators) in patterns where name.hasPrefix(prefix) {
            let parts = name.dropFirst(prefix.count).split(omittingEmptySubsequences: false) { separators.contains($0) }
            return parts.allSatisfy(digits)
        }
        return false
    }

    /// Verbs that write every disk-device operand they name.
    private static let deviceWriters: Set<String> = [
        "shred", "truncate", "wipefs", "blkdiscard", "mkswap", "tee",
    ]
    /// Verbs whose last operand is the destination they write.
    private static let deviceCopiers: Set<String> = ["cp", "install", "rsync", "mv"]

    /// Whether any segment of `command` writes a disk device: a redirect
    /// onto one (`> /dev/sda`), `dd of=/dev/sda`, a format or wipe verb
    /// (`mkfs*`, `shred`, `truncate`, `wipefs`, …) naming one, or a copy
    /// whose destination is one (`cp /dev/zero /dev/sda`). Lexical and
    /// conservative: it only ever adds a stop to a would-be deny.
    static func writesDiskDevice(_ command: String) -> Bool {
        shellChainSegments(command).contains { segment in
            let tokens = redirectTokens(segment)
            for (index, token) in tokens.enumerated() {
                if redirectOperators.contains(token), index + 1 < tokens.count, isDiskDevice(tokens[index + 1]) {
                    return true
                }
                if token.hasPrefix("of="), isDiskDevice(String(token.dropFirst(3))) { return true }
            }
            let names = tokens.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
            if let verb = names.firstIndex(where: { deviceWriters.contains($0) || $0.hasPrefix("mkfs") }),
               tokens[(verb + 1)...].contains(where: isDiskDevice) {
                return true
            }
            if names.contains(where: deviceCopiers.contains), let last = tokens.last, isDiskDevice(last) {
                return true
            }
            return false
        }
    }

    private static let redirectOperators: Set<String> = [">", ">>", ">|", "&>", "&>>", "1>", "2>", "1>>", "2>>"]

    /// Words of one segment, quotes removed, with a redirect operator split
    /// from the word it is glued to (`>/dev/sda` → `>`, `/dev/sda`).
    private static func redirectTokens(_ segment: String) -> [String] {
        var spaced = ""
        var previous: Character = " "
        for character in segment where character != "'" && character != "\"" {
            if character == ">" && previous != ">" && previous != "&" && previous != "1" && previous != "2" {
                spaced.append(" ")
            }
            spaced.append(character)
            if character == ">" { spaced.append(" ") }
            previous = character
        }
        // `> >` from `>>` and `> |` from `>|` are glued back.
        let raw = spaced.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var tokens: [String] = []
        for token in raw {
            if let last = tokens.last, last.hasSuffix(">"), token == ">" || token == "|" {
                tokens[tokens.count - 1] = last + token
            } else {
                tokens.append(token)
            }
        }
        return tokens
    }

    /// The words of `command`, split at shell punctuation, quotes removed.
    private static func words(_ command: String) -> [String] {
        command.filter { $0 != "'" && $0 != "\"" }
            .split(whereSeparator: { " \t\n\r;|&()<>,".contains($0) })
            .map(String.init)
    }

    // MARK: Roots

    /// `/`, home, or a top-level system directory, read lexically: quotes
    /// dropped, trailing `/*` globs, slashes and `/.` dropped (`/usr/*` and
    /// `/usr/` are `/usr`), and a trailing `/..` names the parent (`~/..`,
    /// `/usr/local/..`). Home is `~`, `$HOME`, `${HOME}` or any
    /// `${HOME…}` expansion that still names it (`${HOME:?}`,
    /// `${HOME:-/tmp}`, `${HOME%/}`); `${HOME}/x` is below it.
    private static func isRoot(_ path: String, home: HomeDirectory?) -> Bool {
        var trimmed = path.filter { $0 != "'" && $0 != "\"" }
        var parents = 0
        while true {
            if trimmed.hasSuffix("/*") { trimmed.removeLast(2); continue }
            if trimmed.hasSuffix("/..") { trimmed.removeLast(3); parents += 1; continue }
            if trimmed.hasSuffix("/.") { trimmed.removeLast(2); continue }
            if trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast(); continue }
            guard parents > 0 else { break }
            // The parent of `/` or of home is a root too.
            if trimmed.isEmpty || isHomeWord(trimmed) { return true }
            guard let slash = trimmed.lastIndex(of: "/") else { return false }
            trimmed = String(trimmed[..<slash])
            parents -= 1
        }
        if trimmed.isEmpty { trimmed = "/" }
        if systemRoots.contains(trimmed) || isHomeWord(trimmed) { return true }
        guard let home else { return false }
        var homePath = home.rawValue
        while homePath.count > 1, homePath.hasSuffix("/") { homePath.removeLast() }
        return trimmed == homePath
    }

    /// `~`, `$HOME`, `${HOME}`, or `${HOME` with an operator that leaves
    /// home or one of its parents (`:?`, `?`, `:-`, `-`, `:=`, `=`, `:+`,
    /// `+`, `%`), closed by the word's last brace. Never `${HOME_DIR}` or
    /// `${HOME#/}`.
    private static func isHomeWord(_ word: String) -> Bool {
        if word == "~" || word == "$HOME" || word == "${HOME}" { return true }
        guard word.hasPrefix("${HOME") else { return false }
        let rest = word.dropFirst("${HOME".count)
        guard let first = rest.first, ":?-=+%".contains(first) else { return false }
        var depth = 1
        for (offset, char) in rest.enumerated() {
            if char == "{" { depth += 1 }
            if char == "}" {
                depth -= 1
                if depth == 0 { return offset == rest.count - 1 }
            }
        }
        return false
    }
}
