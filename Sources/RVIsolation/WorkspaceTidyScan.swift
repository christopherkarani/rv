#if os(macOS)
import Foundation

extension WorkspaceHosts {
    /// What `rv box tidy` decides on (`BoxTidy.plan`), read from the
    /// machine: unclosed boxes and every image their records name, rv
    /// image files nothing has attached, attached images no live box owns,
    /// and the trash. Read-only.
    public static func tidyScan(trash: BoxTrash) -> BoxTidyScan {
        let disk = diskLeftovers()
        let imageFiles = disk.detachedImageFiles.compactMap { path -> BoxTidyImageFile? in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                attributes[.type] as? FileAttributeType == .typeRegular,
                let modified = attributes[.modificationDate] as? Date
            else { return nil }
            return BoxTidyImageFile(path: path, modified: modified)
        }
        let retained = Set(disk.retained.map(\.imagePath))
        let attached = disk.stranded.map {
            BoxTidyAttachedImage(imagePath: $0.imagePath, device: $0.device, retained: retained.contains($0.imagePath))
        }
        guard let directory = WorkspaceHostLocation.configurationDirectory() else {
            // No lifecycle log to read: rv cannot tell which images a box
            // names, so it moves nothing.
            return BoxTidyScan(boxes: [], imageFiles: imageFiles, attachedImages: attached,
                               attachedKnown: false, trash: trash.entries())
        }
        let lifecycleLog = WorkspaceHostLocation.lifecycleLog(in: directory)
        let named = namedImages(lifecycleLog: lifecycleLog)
        // A log with bytes but no record rv can read is torn or corrupt:
        // which images a box names is then unknown, so nothing moves.
        let logBytes = (try? FileManager.default.attributesOfItem(atPath: lifecycleLog.path))?[.size] as? Int ?? 0
        let logRead = logBytes == 0 || WorkspaceLifecycleLog.records(at: lifecycleLog).isEmpty == false
        let unclosed = unclosedWorkspaces()
        let boxes = unclosed.map { found -> BoxTidyBox in
            let state: BoxTidyBox.State
            switch found.attachment {
            case .live: state = .open
            case .starting, .recovering: state = .busy
            case .orphaned, .staleEndpoint, .blocked, .absent, .unsupported: state = .unfinished
            }
            return BoxTidyBox(project: found.project, lastActive: found.recordedAt, state: state,
                              images: named[found.workspace] ?? [])
        }
        // Every unclosed workspace's images stay, listed or not: one whose
        // project folder is gone, or older than its project's newest, is
        // left out of `boxes` but may still hold unsaved work.
        let everyNamed = named.values.flatMap { $0 }
        return BoxTidyScan(boxes: boxes, imageFiles: imageFiles, attachedImages: attached,
                           attachedKnown: disk.attachedKnown && logRead, trash: trash.entries(),
                           alsoKept: everyNamed)
    }

    /// Image paths each unclosed workspace's records name.
    static func namedImages(lifecycleLog: URL) -> [UUID: [String]] {
        var closed: Set<UUID> = []
        var named: [UUID: [String]] = [:]
        for record in WorkspaceLifecycleLog.records(at: lifecycleLog) {
            if record.kind == .closed { closed.insert(record.workspace) }
            if let path = record.identity?.imagePath { named[record.workspace, default: []].append(path) }
        }
        return named.filter { closed.contains($0.key) == false }
    }
}
#endif
