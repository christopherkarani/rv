#if os(macOS)
import Foundation

/// A protected workspace that never closed and has no live host: a host or
/// machine died mid-session. Its volume may still be mounted and its saved
/// tree hidden until the project is started (recovers) or abandoned.
public struct WorkspaceLeftover: Sendable, Equatable {
    public var project: String
    public var workspace: UUID
    public var lastEvent: String
    public var recordedAt: Date
    public var attachment: WorkspaceAttachment

    public init(
        project: String,
        workspace: UUID,
        lastEvent: String,
        recordedAt: Date,
        attachment: WorkspaceAttachment
    ) {
        self.project = project
        self.workspace = workspace
        self.lastEvent = lastEvent
        self.recordedAt = recordedAt
        self.attachment = attachment
    }
}

/// An attached rv workspace disk image (`rv-inode-*.sparseimage`).
public struct AttachedWorkspaceImage: Sendable, Equatable {
    public var imagePath: String
    public var device: String?
    public var mountPoint: String?

    public init(imagePath: String, device: String?, mountPoint: String?) {
        self.imagePath = imagePath
        self.device = device
        self.mountPoint = mountPoint
    }

    /// Entries in the plist `images` array. A row with no `image-path` still
    /// counts. Malformed input → nil. `[]` is a successful empty listing.
    public static func listedImageCount(hdiutilInfo data: Data) -> Int? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
            let images = root["images"] as? [[String: Any]]
        else { return nil }
        return images.count
    }

    /// `hdiutil info -plist` output → rv images only. rv mounts slices with
    /// `mount_hfs`, so hdiutil rarely knows the mount point; `mounts`
    /// (device → mount point, from the kernel table) fills it in.
    /// Malformed input → nil. A row with no `image-path` is dropped here
    /// and is not an empty listing; `listedImageCount` still counts it.
    public static func parse(
        hdiutilInfo data: Data,
        mounts: [String: String] = [:]
    ) -> [AttachedWorkspaceImage]? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
            let images = root["images"] as? [[String: Any]]
        else { return nil }
        return images.compactMap { image in
            guard let path = image["image-path"] as? String,
                isWorkspaceImage(path)
            else { return nil }
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            let devices = entities.compactMap { $0["dev-entry"] as? String }
            for entity in entities {
                if let device = entity["dev-entry"] as? String,
                    let mountPoint = (entity["mount-point"] as? String) ?? mounts[device]
                {
                    return AttachedWorkspaceImage(imagePath: path, device: device, mountPoint: mountPoint)
                }
            }
            return AttachedWorkspaceImage(imagePath: path, device: devices.first, mountPoint: nil)
        }
    }

    static func isWorkspaceImage(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix("rv-inode-") && name.hasSuffix(".sparseimage")
    }
}

public struct WorkspaceDiskLeftovers: Sendable, Equatable {
    public var attachedCount: Int
    /// Attached images that are not owned by a live, starting, recovering,
    /// or stale host, and that no live, starting, or recovering identity names.
    public var stranded: [AttachedWorkspaceImage]
    /// Stranded images recovery still needs. Detach would drop the mount
    /// `WorkspaceRecovery.publish` requires. Subset of `stranded`.
    public var retained: [AttachedWorkspaceImage]
    public var detachedImageFiles: [String]
    /// False when the attachment list could not be read. `stranded` is then
    /// empty; `detachedImageFiles` is still filled from the temporary directory.
    public var attachedKnown: Bool

    public init(
        attachedCount: Int,
        stranded: [AttachedWorkspaceImage],
        retained: [AttachedWorkspaceImage],
        detachedImageFiles: [String],
        attachedKnown: Bool
    ) {
        self.attachedCount = attachedCount
        self.stranded = stranded
        self.retained = retained
        self.detachedImageFiles = detachedImageFiles
        self.attachedKnown = attachedKnown
    }
}

/// An open workspace's disk image, with the attachment `inspect` reports
/// for that workspace's project.
struct OpenWorkspaceImage: Equatable, Sendable {
    var imagePath: String
    var attachment: WorkspaceAttachment
}

extension WorkspaceHosts {
    /// Disk-level leftovers: attached rv images no open workspace owns, and
    /// image files nothing has attached. When `hdiutil info` fails, the
    /// attached section is unknown and the temporary-directory scan still runs.
    public static func diskLeftovers() -> WorkspaceDiskLeftovers {
        let temporaryDirectory = FileManager.default.temporaryDirectory.path
        let files = (try? FileManager.default.contentsOfDirectory(atPath: temporaryDirectory)) ?? []
        guard let directory = WorkspaceHostLocation.configurationDirectory(),
            let data = hdiutilInfo(),
            let images = AttachedWorkspaceImage.parse(hdiutilInfo: data, mounts: mountTable())
        else {
            return diskLeftovers(
                images: [],
                temporaryDirectory: temporaryDirectory,
                temporaryFiles: files,
                inspect: { _ in .unsupported },
                openImages: [],
                attachedKnown: false
            )
        }
        let inspect: (String) -> WorkspaceAttachment = {
            WorkspaceDiscovery.inspect(project: $0, configurationDirectory: directory)
        }
        return diskLeftovers(
            images: images,
            temporaryDirectory: temporaryDirectory,
            temporaryFiles: files,
            inspect: inspect,
            openImages: openWorkspaceImages(
                lifecycleLog: WorkspaceHostLocation.lifecycleLog(in: directory),
                inspect: inspect
            ),
            attachedKnown: true
        )
    }

    /// Image paths named by unclosed workspaces, classified by `inspect` of
    /// the project. A later record without an identity keeps the earlier path.
    static func openWorkspaceImages(
        lifecycleLog: URL,
        inspect: (String) -> WorkspaceAttachment
    ) -> [OpenWorkspaceImage] {
        var closed: Set<UUID> = []
        var named: [UUID: (path: String, project: String, at: Date)] = [:]
        for record in WorkspaceLifecycleLog.records(at: lifecycleLog) {
            if record.kind == .closed { closed.insert(record.workspace) }
            guard let imagePath = record.identity?.imagePath else { continue }
            if let existing = named[record.workspace], existing.at > record.recordedAt { continue }
            named[record.workspace] = (imagePath, record.originalPath, record.recordedAt)
        }
        return named.compactMap { id, info in
            guard closed.contains(id) == false else { return nil }
            return OpenWorkspaceImage(imagePath: info.path, attachment: inspect(info.project))
        }
    }

    static func diskLeftovers(
        images: [AttachedWorkspaceImage],
        temporaryDirectory: String,
        temporaryFiles: [String],
        inspect: (String) -> WorkspaceAttachment,
        openImages: [OpenWorkspaceImage] = [],
        attachedKnown: Bool = true
    ) -> WorkspaceDiskLeftovers {
        let stranded = images.filter { owned($0, inspect: inspect, openImages: openImages) == false }
            .sorted { ($0.mountPoint ?? $0.imagePath) < ($1.mountPoint ?? $1.imagePath) }
        let retained = stranded.filter { retains($0, inspect: inspect, openImages: openImages) }
        let attachedNames = Set(images.map { ($0.imagePath as NSString).lastPathComponent })
        let detached = temporaryFiles
            .filter { AttachedWorkspaceImage.isWorkspaceImage($0) && attachedNames.contains($0) == false }
            .map { (temporaryDirectory as NSString).appendingPathComponent($0) }
            .sorted()
        return WorkspaceDiskLeftovers(
            attachedCount: attachedKnown ? images.count : 0,
            stranded: attachedKnown ? stranded : [],
            retained: attachedKnown ? retained : [],
            detachedImageFiles: detached,
            attachedKnown: attachedKnown
        )
    }

    /// Live, starting, recovering, and stale mounts are in use. So is an
    /// image a live, starting, or recovering identity names before it has a
    /// mount (`hdiutil attach -nomount` runs before `mount_hfs`).
    private static func owned(
        _ image: AttachedWorkspaceImage,
        inspect: (String) -> WorkspaceAttachment,
        openImages: [OpenWorkspaceImage]
    ) -> Bool {
        if let mountPoint = image.mountPoint {
            switch inspect(mountPoint) {
            case .live, .starting, .recovering, .staleEndpoint:
                return true
            case .absent, .orphaned, .blocked, .unsupported:
                break
            }
        }
        return openImages.contains { claim in
            sameImagePath(claim.imagePath, image.imagePath) && liveOwner(claim.attachment)
        }
    }

    /// Orphaned, recovering, blocked, and stale mounts still belong to an
    /// open workspace. So does any attached image an open identity names.
    /// Absent and unsupported mounts, and images nobody names, may be detached.
    private static func retains(
        _ image: AttachedWorkspaceImage,
        inspect: (String) -> WorkspaceAttachment,
        openImages: [OpenWorkspaceImage]
    ) -> Bool {
        if let mountPoint = image.mountPoint {
            switch inspect(mountPoint) {
            case .orphaned, .recovering, .blocked, .staleEndpoint:
                return true
            case .absent, .unsupported:
                return false
            case .live, .starting:
                break
            }
        }
        return openImages.contains { sameImagePath($0.imagePath, image.imagePath) }
    }

    private static func liveOwner(_ attachment: WorkspaceAttachment) -> Bool {
        switch attachment {
        case .live, .starting, .recovering:
            return true
        case .absent, .orphaned, .blocked, .staleEndpoint, .unsupported:
            return false
        }
    }

    private static func sameImagePath(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let left = URL(fileURLWithPath: lhs).resolvingSymlinksInPath().standardizedFileURL.path
        let right = URL(fileURLWithPath: rhs).resolvingSymlinksInPath().standardizedFileURL.path
        return left == right
    }

    /// Device → mount point for every mounted file system.
    static func mountTable() -> [String: String] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [:] }
        var table: [String: String] = [:]
        for index in 0..<Int(count) {
            var entry = buffer[index]
            let device = withUnsafeBytes(of: &entry.f_mntfromname) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            let mountPoint = withUnsafeBytes(of: &entry.f_mntonname) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            table[device] = mountPoint
        }
        return table
    }

    /// DiskArbitration can wedge; never wait on it unbounded.
    private static func hdiutilInfo(timeout: TimeInterval = 15) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let collected = DataBox()
        output.fileHandleForReading.readabilityHandler = { handle in
            collected.append(handle.availableData)
        }
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            output.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        output.fileHandleForReading.readabilityHandler = nil
        collected.append(output.fileHandleForReading.readDataToEndOfFile())
        guard process.terminationStatus == 0 else { return nil }
        return collected.value
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

extension WorkspaceHosts {
    /// Read-only scan across every project in the lifecycle log.
    public static func leftovers() -> [WorkspaceLeftover] {
        guard let directory = WorkspaceHostLocation.configurationDirectory() else { return [] }
        return leftovers(
            lifecycleLog: WorkspaceHostLocation.lifecycleLog(in: directory),
            projectExists: { FileManager.default.fileExists(atPath: $0) },
            inspect: { WorkspaceDiscovery.inspect(project: $0, configurationDirectory: directory) }
        )
    }

    static func leftovers(
        lifecycleLog: URL,
        projectExists: (String) -> Bool,
        inspect: (String) -> WorkspaceAttachment
    ) -> [WorkspaceLeftover] {
        var closed: Set<UUID> = []
        var latest: [UUID: WorkspaceLifecycleRecord] = [:]
        for record in WorkspaceLifecycleLog.records(at: lifecycleLog) {
            if record.kind == .closed { closed.insert(record.workspace) }
            latest[record.workspace] = record
        }
        var newestPerProject: [String: WorkspaceLifecycleRecord] = [:]
        for (id, record) in latest where closed.contains(id) == false {
            let project = record.originalPath
            if let existing = newestPerProject[project], existing.recordedAt >= record.recordedAt { continue }
            newestPerProject[project] = record
        }
        return newestPerProject.values
            .filter { projectExists($0.originalPath) }
            .sorted { $0.recordedAt < $1.recordedAt }
            .compactMap { record in
                let attachment = inspect(record.originalPath)
                switch attachment {
                case .orphaned, .recovering, .blocked, .staleEndpoint:
                    return WorkspaceLeftover(
                        project: record.originalPath,
                        workspace: record.workspace,
                        lastEvent: record.kind.rawValue,
                        recordedAt: record.recordedAt,
                        attachment: attachment
                    )
                case .absent, .live, .starting, .unsupported:
                    return nil
                }
            }
    }
}
#endif
