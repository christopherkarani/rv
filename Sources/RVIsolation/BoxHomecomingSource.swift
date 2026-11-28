#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Where an open box's two trees are: the project path (the box's volume
/// is mounted over it while the box is open) and the saved tree rv hid
/// beside it when the box started, read from the workspace lifecycle log,
/// with the identities the host recorded then.
public struct BoxHomecomingSource: Equatable, Sendable {
    /// The project folder, which shows the box while it is open.
    public var project: String
    /// The project as it was, `<parent>/.rv-saved-<token>`.
    public var savedRoot: String
    /// When the box started: edits to the saved tree after this are yours.
    public var startedAt: Date
    /// The saved tree's device and inode, as recorded.
    public var saved: (device: UInt64, inode: UInt64)?
    /// The box volume's device, as recorded.
    public var volumeDevice: UInt64?
    /// Every saved name's identity when the box started.
    public var snapshot: BoxSnapshot?

    public init(
        project: String, savedRoot: String, startedAt: Date,
        saved: (device: UInt64, inode: UInt64)? = nil, volumeDevice: UInt64? = nil, snapshot: BoxSnapshot? = nil
    ) {
        self.project = project
        self.savedRoot = savedRoot
        self.startedAt = startedAt
        self.saved = saved
        self.volumeDevice = volumeDevice
        self.snapshot = snapshot
    }

    public static func == (lhs: BoxHomecomingSource, rhs: BoxHomecomingSource) -> Bool {
        lhs.project == rhs.project && lhs.savedRoot == rhs.savedRoot && lhs.startedAt == rhs.startedAt
            && lhs.saved?.device == rhs.saved?.device && lhs.saved?.inode == rhs.saved?.inode
            && lhs.volumeDevice == rhs.volumeDevice && lhs.snapshot == rhs.snapshot
    }

    /// Whether `boxRoot` is still the recorded volume and the saved tree
    /// the recorded folder. rv writes in neither unless both are.
    public func rootsMatch(boxRoot: String) -> Bool {
        var info = stat()
        if let volumeDevice {
            guard stat(boxRoot, &info) == 0, UInt64(info.st_dev) == volumeDevice else { return false }
        }
        if let saved {
            guard lstat(savedRoot, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                UInt64(info.st_dev) == saved.device, UInt64(info.st_ino) == saved.inode
            else { return false }
        }
        return true
    }

    /// The `created` record of `workspace`. The saved tree it names must
    /// sit beside the project under rv's `.rv-saved-` name; anything else
    /// is not trusted as the project's past.
    static func find(workspace: UUID, in records: [WorkspaceLifecycleRecord]) -> BoxHomecomingSource? {
        guard let created = records.last(where: { $0.kind == .created && $0.workspace == workspace }),
            let identity = created.identity
        else { return nil }
        let saved = identity.savedPath
        let project = created.originalPath
        guard project.hasPrefix("/"), project.contains("\0") == false, saved.contains("\0") == false,
            BoxPath.parent(saved) == BoxPath.parent(project),
            BoxPath.name(saved).hasPrefix(".rv-saved-")
        else { return nil }
        return BoxHomecomingSource(
            project: project, savedRoot: saved, startedAt: created.recordedAt,
            saved: (identity.savedDevice, identity.savedInode), volumeDevice: identity.volumeDevice)
    }

    /// `find`, from the lifecycle log at `lifecycleLog`, with the snapshot
    /// it names. Nil when the snapshot is recorded but can't be read as
    /// the recorded file: without it rv can't tell what publish refuses.
    public static func read(workspace: UUID, lifecycleLog: URL) -> BoxHomecomingSource? {
        let records = WorkspaceLifecycleLog.records(at: lifecycleLog)
        guard var source = find(workspace: workspace, in: records),
            let identity = records.last(where: { $0.kind == .created && $0.workspace == workspace })?.identity,
            let snapshot = BoxSnapshot.read(
                path: identity.snapshotPath, device: identity.snapshotDevice, inode: identity.snapshotInode)
        else { return nil }
        source.snapshot = snapshot
        return source
    }

    #if os(macOS)
    /// `read`, from this account's lifecycle log.
    public static func live(workspace: UUID) -> BoxHomecomingSource? {
        guard let directory = WorkspaceHostLocation.configurationDirectory() else { return nil }
        return read(workspace: workspace, lifecycleLog: WorkspaceHostLocation.lifecycleLog(in: directory))
    }
    #endif
}
