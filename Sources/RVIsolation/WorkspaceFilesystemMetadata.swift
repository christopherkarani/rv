#if os(macOS)
import Darwin
#endif

/// Reserved names emitted by filesystems used for workspace volumes. A
/// root-level directory with a bookkeeping name is skipped when it is owned
/// by root, or when the containing filesystem ignores ownership: workspace
/// volumes mount that way, so the daemon's own directories already show the
/// user's uid and the owner gate cannot discriminate there. On filesystems
/// that honor ownership a user-owned copy is project content and stays in
/// the checked tree. Nested same-named directories always stay.
enum WorkspaceFilesystemMetadata {
    static func isBookkeepingName(_ name: String) -> Bool {
        switch name {
        case ".fseventsd", ".Trashes", ".Spotlight-V100", ".TemporaryItems",
            ".DocumentRevisions-V100", ".vol", ".HFS+ Private Directory Data",
            ".apdisk", ".metadata_never_index":
            true
        default:
            false
        }
    }

    static func shouldSkip(
        name: String,
        isRootChild: Bool,
        isDirectory: Bool,
        isSymbolicLink: Bool,
        ownerUid: UInt32,
        ownersIgnored: Bool
    ) -> Bool {
        isRootChild && isBookkeepingName(name) && isDirectory && !isSymbolicLink
            && (ownersIgnored || ownerUid == 0)
    }

#if os(macOS)
    /// True when the filesystem containing `path` ignores ownership
    /// (`MNT_IGNORE_OWNERSHIP`), so `st_uid` cannot identify the daemon's
    /// copy. Unknown paths fail closed toward honoring ownership.
    static func filesystemIgnoresOwnership(path: String) -> Bool {
        var info = statfs()
        guard path.withCString({ statfs($0, &info) == 0 }) else { return false }
        return info.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0
    }

    /// Same check for an already-open directory descriptor.
    static func filesystemIgnoresOwnership(descriptor: Int32) -> Bool {
        var info = statfs()
        guard fstatfs(descriptor, &info) == 0 else { return false }
        return info.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0
    }
#endif
}
