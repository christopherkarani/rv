#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import RVDomain

/// Where clients find a live workspace host. A socket path alone is not ownership.
public struct WorkspaceEndpoint: Sendable, Equatable {
    public var host: WorkspaceHostID
    public var workspace: UUID
    public var canonicalPath: String
    public var socketPath: String
    public var socketDevice: UInt64
    public var socketInode: UInt64
    /// Same-account binding secret. It is not a capability and not an org credential.
    public var ownerToken: UUID
    public var uid: UInt32
}

public struct WorkspaceDescription: Sendable, Equatable {
    public var host: WorkspaceHostID
    public var workspace: UUID
    public var project: String
    public var phase: WorkspaceLifecycle
    public var attached: Int
}

public enum WorkspaceAttachment: Sendable, Equatable {
    case absent
    case live(WorkspaceEndpoint)
    case starting(UUID?)
    case orphaned(UUID)
    case recovering(UUID)
    case blocked(WorkspaceRecoveryBlock)
    case staleEndpoint
    case unsupported
}

enum WorkspaceHostLocation {
    static let directoryName = "wh"

    static func configurationDirectory() -> URL? {
        WorkspaceLifecycleLog.productionURL()?.deletingLastPathComponent()
    }

    static func lifecycleLog(in directory: URL) -> URL {
        directory.appendingPathComponent("workspace-sessions.jsonl")
    }

    static func runtimeLog(in directory: URL) -> URL {
        directory.appendingPathComponent("runtime-sessions.jsonl")
    }

    static func digest(_ canonicalPath: String) -> String {
        SHA256.hash(data: Data(canonicalPath.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func endpointFile(in directory: URL, canonicalPath: String) -> URL {
        directory
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(digest(canonicalPath))
            .appendingPathExtension("json")
    }
}

struct WorkspaceEndpointDraft: Equatable {
    var record: WorkspaceEndpointRecord
    var socketDirectory: String
    var removeSocketDirectory: Bool
    var endpointFile: URL
}

struct WorkspaceEndpointRecord: Codable, Equatable {
    var v: Int
    var host: UUID
    var workspace: UUID
    var canonicalPath: String
    var socketPath: String
    var socketDevice: UInt64
    var socketInode: UInt64
    var ownerToken: UUID
    var lockPath: String
    var lockDevice: UInt64
    var lockInode: UInt64
    var uid: UInt32

    func endpoint() -> WorkspaceEndpoint {
        WorkspaceEndpoint(
            host: WorkspaceHostID(rawValue: host),
            workspace: workspace,
            canonicalPath: canonicalPath,
            socketPath: socketPath,
            socketDevice: socketDevice,
            socketInode: socketInode,
            ownerToken: ownerToken,
            uid: uid
        )
    }
}

enum WorkspaceEndpointStore {
    static func prepareSocket(
        configurationDirectory: URL,
        canonicalPath: String
    ) -> Result<(path: String, directory: String, removeDirectory: Bool), WorkspaceSocketError> {
        let digest = WorkspaceHostLocation.digest(canonicalPath)
        let shared = configurationDirectory
            .appendingPathComponent(WorkspaceHostLocation.directoryName, isDirectory: true)
        let preferred = shared.appendingPathComponent(String(digest.prefix(32))).appendingPathExtension("sock").path
        if WorkspaceControlSocket.fits(preferred),
            WorkspaceControlSocket.prepareDirectory(shared.path)
        {
            return .success((preferred, shared.path, false))
        }
        guard let temporary = makeSocketDirectory() else { return .failure(.permission) }
        let path = URL(fileURLWithPath: temporary, isDirectory: true).appendingPathComponent("s").path
        guard WorkspaceControlSocket.fits(path) else { return .failure(.pathTooLong) }
        return .success((path, temporary, true))
    }

    static func write(
        _ record: WorkspaceEndpointRecord,
        to url: URL
    ) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record) else { return false }
        return writeOwnerFile(data, to: url)
    }

    static func load(from url: URL) -> WorkspaceEndpointRecord? {
        guard let data = try? Data(contentsOf: url),
            data.count <= WorkspaceControlLimits.maxBodyBytes,
            let record = try? JSONDecoder().decode(WorkspaceEndpointRecord.self, from: data),
            record.v == WorkspaceControlLimits.version
        else {
            return nil
        }
        return record
    }

    /// Removes a previous endpoint only when its socket inode still matches.
    static func retireStale(at url: URL) {
        guard let record = load(from: url) else { return }
        if let identity = WorkspaceControlSocket.identity(record.socketPath),
            identity.device == record.socketDevice,
            identity.inode == record.socketInode
        {
            _ = WorkspaceControlSocket.unlinkOwnedSocket(record.socketPath)
            let parent = (record.socketPath as NSString).deletingLastPathComponent
            if parent.hasPrefix("/tmp/rvh") {
                _ = parent.withCString { rmdir($0) }
            }
        }
        _ = url.path.withCString { unlink($0) }
    }

    static func validate(
        _ record: WorkspaceEndpointRecord,
        workspace: UUID,
        canonicalPath: String,
        credentialToken: UUID,
        lockDevice: UInt64,
        lockInode: UInt64
    ) -> WorkspaceEndpoint? {
        guard record.v == WorkspaceControlLimits.version,
            record.workspace == workspace,
            record.canonicalPath == canonicalPath,
            record.uid == UInt32(getuid()),
            record.ownerToken == credentialToken,
            record.lockDevice == lockDevice,
            record.lockInode == lockInode,
            WorkspaceOwnerLock.token(at: record.lockPath) == credentialToken,
            WorkspaceControlSocket.fits(record.socketPath),
            WorkspaceSocketMode.isOwnerSocket(record.socketPath)
        else {
            return nil
        }
        let parent = (record.socketPath as NSString).deletingLastPathComponent
        guard WorkspaceSocketMode.isOwnerDirectory(parent) else { return nil }
        guard let identity = WorkspaceControlSocket.identity(record.socketPath),
            identity.device == record.socketDevice,
            identity.inode == record.socketInode
        else {
            return nil
        }
        var lockStatus = stat()
        guard record.lockPath.withCString({ lstat($0, &lockStatus) == 0 }),
            UInt64(lockStatus.st_dev) == lockDevice,
            UInt64(lockStatus.st_ino) == lockInode,
            (lockStatus.st_mode & S_IFMT) == S_IFREG
        else {
            return nil
        }
        return record.endpoint()
    }

    private static func makeSocketDirectory() -> String? {
        var bytes = Array("/tmp/rvhXXXXXX".utf8CString)
        let path = bytes.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let base = buffer.baseAddress, mkdtemp(base) != nil else { return nil }
            return String(cString: base)
        }
        guard let path, WorkspaceSocketMode.isOwnerDirectory(path) else { return nil }
        return path
    }

    private static func writeOwnerFile(_ data: Data, to url: URL) -> Bool {
        let directory = url.deletingLastPathComponent()
        guard WorkspaceControlSocket.prepareDirectory(directory.path) else { return false }
        let temporary = url.appendingPathExtension("tmp")
        _ = temporary.path.withCString { unlink($0) }
        let fd = temporary.path.withCString {
            open($0, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard fd >= 0 else { return false }
        var offset = 0
        let bytes = [UInt8](data)
        var wrote = true
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
            }
            if count > 0 {
                offset += count
                continue
            }
            if count < 0, errno == EINTR { continue }
            wrote = false
            break
        }
        if wrote {
            wrote = fsync(fd) == 0 && fchmod(fd, 0o600) == 0
        }
        close(fd)
        guard wrote else {
            _ = temporary.path.withCString { unlink($0) }
            return false
        }
        guard temporary.path.withCString({ source in
            url.path.withCString { destination in
                rename(source, destination) == 0
            }
        }) else {
            _ = temporary.path.withCString { unlink($0) }
            return false
        }
        let parent = directory.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        if parent >= 0 {
            _ = fsync(parent)
            close(parent)
        }
        return true
    }
}

enum WorkspaceDiscovery {
    static func inspect(
        project: String,
        configurationDirectory: URL
    ) -> WorkspaceAttachment {
        guard project.contains("\0") == false,
            let directory = WorkingDirectory(validating: project)
        else {
            return .blocked(WorkspaceRecoveryBlock(workspace: nil, reason: .corrupt))
        }
        let life = WorkspaceHostLocation.lifecycleLog(in: configurationDirectory)
        let runtime = WorkspaceHostLocation.runtimeLog(in: configurationDirectory)
        let assessment = WorkspaceRecovery.assess(directory, lifecycleLog: life, runtimeLog: runtime)
        switch assessment {
        case .clean:
            return .absent
        case .orphaned(let id):
            return .orphaned(id)
        case .recoveryInProgress(let id):
            return .recovering(id)
        case .blocked(let block):
            return .blocked(block)
        case .liveOwner(let id):
            guard let id else { return .starting(nil) }
            return live(id, project: directory, log: life, configurationDirectory: configurationDirectory)
        }
    }

    private static func live(
        _ workspace: UUID,
        project: WorkingDirectory,
        log: URL,
        configurationDirectory: URL
    ) -> WorkspaceAttachment {
        guard let canonical = canonical(project) else {
            return .blocked(WorkspaceRecoveryBlock(workspace: workspace, reason: .corrupt))
        }
        guard let created = WorkspaceLifecycleLog.records(at: log).last(where: {
            $0.workspace == workspace && $0.kind == .created
        }), let identity = created.identity else {
            return .starting(workspace)
        }
        let file = WorkspaceHostLocation.endpointFile(in: configurationDirectory, canonicalPath: canonical)
        guard let record = WorkspaceEndpointStore.load(from: file) else {
            return .starting(workspace)
        }
        guard let endpoint = WorkspaceEndpointStore.validate(
            record,
            workspace: workspace,
            canonicalPath: canonical,
            credentialToken: identity.ownerToken,
            lockDevice: identity.lockDevice,
            lockInode: identity.lockInode
        ) else {
            return .staleEndpoint
        }
        return .live(endpoint)
    }

    private static func canonical(_ project: WorkingDirectory) -> String? {
        switch existingResolvedWorkspacePath(project) {
        case .success(let path):
            return path
        case .failure:
            return nil
        }
    }
}
#endif
