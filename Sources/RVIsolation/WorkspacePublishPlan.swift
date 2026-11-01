import Foundation

/// Why one name kept a publish from starting. Any rejection means nothing
/// was written to the saved tree.
struct WorkspacePublishRejection: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// The saved name is a different inode, or a file's link count changed.
        case inodeChanged
        /// The volume entry's kind differs from the saved inode's kind.
        case kindChanged
        /// A new or retargeted symlink is absolute, or resolves outside the
        /// workspace root.
        case symlinkEscapesWorkspace
        /// A removed directory holds a saved name the snapshot does not own.
        case unexpectedNameInRemovedDirectory
        /// The entry could not be read, or its staging name is taken.
        case unreadable
    }

    var relative: String
    var reason: Reason
}

/// What the last publish left in the saved tree.
enum WorkspacePublishOutcome: Equatable, Sendable {
    case notRun
    /// Every step applied. `leftovers` are host paths of rollback material
    /// that could not be deleted; the published tree itself is complete.
    case committed(leftovers: [String])
    /// Validation refused the publish. Nothing was written.
    case rejected([WorkspacePublishRejection])
    /// A step failed after earlier steps applied. Every applied step was
    /// undone; the saved tree is what it was before the publish.
    case rolledBack(failedAt: String)
    /// A step failed and these saved names could not be put back. Every
    /// other name is as it was before the publish.
    case residual(failedAt: String, unrestored: [String])
    /// The copy clock stopped after steps applied. The workspace rename is
    /// fenced and recovery resumes the publish forward.
    case interrupted(at: String)
}

/// Test seam: return true to fail commit step `index` (naming `relative`)
/// as a finished failure.
enum WorkspacePublishFaults {
    @TaskLocal static var commitFault: (@Sendable (_ index: Int, _ relative: String) -> Bool)?
}

/// Whether `target`, stored in the symlink at workspace-relative `link`,
/// resolves inside the workspace root.
///
/// Resolution is lexical from the link's directory. A component that names
/// another symlink in `links` (workspace-relative name to target, the tree
/// being published) is resolved through that link, so `y -> p/..` with
/// `p -> .` is refused. Absolute targets, empty targets, a `..` above the
/// root, and more than 32 link hops are refused.
func workspaceSymlinkTargetStaysInside(
    link: String,
    target: String,
    links: [String: String]
) -> Bool {
    var hops = 32
    let base = link.split(separator: "/").dropLast().map(String.init)
    return resolveInsideWorkspace(base: base, target: target, links: links, hops: &hops) != nil
}

private func resolveInsideWorkspace(
    base: [String],
    target: String,
    links: [String: String],
    hops: inout Int
) -> [String]? {
    guard target.isEmpty == false, target.hasPrefix("/") == false else { return nil }
    var stack = base
    for part in target.split(separator: "/").map(String.init) {
        switch part {
        case ".":
            continue
        case "..":
            guard stack.isEmpty == false else { return nil }
            stack.removeLast()
        default:
            stack.append(part)
            guard let next = links[stack.joined(separator: "/")] else { continue }
            hops -= 1
            guard hops > 0 else { return nil }
            stack.removeLast()
            guard let resolved = resolveInsideWorkspace(
                base: stack,
                target: next,
                links: links,
                hops: &hops
            ) else { return nil }
            stack = resolved
        }
    }
    return stack
}

/// Deterministic staging name for a new file published as `name`. It sits in
/// the destination's directory so the install rename is atomic, and a
/// resumed publish finds a stale stage by name.
func workspacePublishStageName(for name: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in name.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    let hex = String(hash, radix: 16)
    return ".rv-ps-" + String(repeating: "0", count: 16 - hex.count) + hex
}
