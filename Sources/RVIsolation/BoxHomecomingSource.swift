import Foundation

/// Where an open box's two trees are: the project path (the box's volume
/// is mounted over it while the box is open) and the saved tree rv hid
/// beside it when the box started, read from the workspace lifecycle log.
public struct BoxHomecomingSource: Equatable, Sendable {
    /// The project folder, which shows the box while it is open.
    public var project: String
    /// The project as it was, `<parent>/.rv-saved-<token>`.
    public var savedRoot: String
    /// When the box started: edits to the saved tree after this are yours.
    public var startedAt: Date

    public init(project: String, savedRoot: String, startedAt: Date) {
        self.project = project
        self.savedRoot = savedRoot
        self.startedAt = startedAt
    }

    /// The `created` record of `workspace`. The saved tree it names must
    /// sit beside the project under rv's `.rv-saved-` name; anything else
    /// is not trusted as the project's past.
    static func find(workspace: UUID, in records: [WorkspaceLifecycleRecord]) -> BoxHomecomingSource? {
        guard let created = records.last(where: { $0.kind == .created && $0.workspace == workspace }),
            let saved = created.identity?.savedPath
        else { return nil }
        let project = created.originalPath
        let parent = (project as NSString).deletingLastPathComponent
        guard (saved as NSString).deletingLastPathComponent == parent,
            (saved as NSString).lastPathComponent.hasPrefix(".rv-saved-"),
            saved.contains("\0") == false, project.hasPrefix("/")
        else { return nil }
        return BoxHomecomingSource(project: project, savedRoot: saved, startedAt: created.recordedAt)
    }

    /// `find`, from the lifecycle log at `lifecycleLog`.
    public static func read(workspace: UUID, lifecycleLog: URL) -> BoxHomecomingSource? {
        find(workspace: workspace, in: WorkspaceLifecycleLog.records(at: lifecycleLog))
    }

    #if os(macOS)
    /// `read`, from this account's lifecycle log.
    public static func live(workspace: UUID) -> BoxHomecomingSource? {
        guard let directory = WorkspaceHostLocation.configurationDirectory() else { return nil }
        return read(workspace: workspace, lifecycleLog: WorkspaceHostLocation.lifecycleLog(in: directory))
    }
    #endif
}
