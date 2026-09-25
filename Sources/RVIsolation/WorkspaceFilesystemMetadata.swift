/// Reserved names emitted by filesystems used for workspace volumes. A name
/// is ignored only at the workspace root when it is a root-owned directory;
/// user content with a matching name remains part of the checked tree.
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
        ownerID: UInt32
    ) -> Bool {
        isRootChild && isBookkeepingName(name) && isDirectory && !isSymbolicLink && ownerID == 0
    }
}
