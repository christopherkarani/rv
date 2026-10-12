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

    /// `hdiutil info -plist` output → rv images only. rv mounts slices with
    /// `mount_hfs`, so hdiutil rarely knows the mount point; `mounts`
    /// (device → mount point, from the kernel table) fills it in.
    /// Malformed input → nil.
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
    /// Attached images whose mount point has no live or starting host,
    /// or that are attached without any mount.
    public var stranded: [AttachedWorkspaceImage]
    public var detachedImageFiles: [String]
}

#if os(macOS)
extension WorkspaceHosts {
    /// Disk-level leftovers: attached rv images with no live host, and image
    /// files nothing has attached. Nil when the attachment list is unreadable.
    public static func diskLeftovers() -> WorkspaceDiskLeftovers? {
        guard let directory = WorkspaceHostLocation.configurationDirectory(),
            let data = hdiutilInfo(),
            let images = AttachedWorkspaceImage.parse(hdiutilInfo: data, mounts: mountTable())
        else { return nil }
        let files = (try? FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return diskLeftovers(
            images: images,
            temporaryDirectory: FileManager.default.temporaryDirectory.path,
            temporaryFiles: files
        ) {
            WorkspaceDiscovery.inspect(project: $0, configurationDirectory: directory)
        }
    }

    static func diskLeftovers(
        images: [AttachedWorkspaceImage],
        temporaryDirectory: String,
        temporaryFiles: [String],
        inspect: (String) -> WorkspaceAttachment
    ) -> WorkspaceDiskLeftovers {
        let stranded = images.filter { image in
            guard let mountPoint = image.mountPoint else { return true }
            switch inspect(mountPoint) {
            case .live, .starting:
                return false
            case .absent, .orphaned, .recovering, .blocked, .staleEndpoint, .unsupported:
                return true
            }
        }
        .sorted { ($0.mountPoint ?? $0.imagePath) < ($1.mountPoint ?? $1.imagePath) }
        let attachedNames = Set(images.map { ($0.imagePath as NSString).lastPathComponent })
        let detached = temporaryFiles
            .filter { AttachedWorkspaceImage.isWorkspaceImage($0) && attachedNames.contains($0) == false }
            .map { (temporaryDirectory as NSString).appendingPathComponent($0) }
            .sorted()
        return WorkspaceDiskLeftovers(attachedCount: images.count, stranded: stranded, detachedImageFiles: detached)
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
