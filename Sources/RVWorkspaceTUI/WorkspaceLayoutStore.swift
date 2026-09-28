#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import RVDomain

public enum WorkspaceLayoutStoreError: Error, Equatable {
    case invalidProject
    case unsafeDirectory
    case invalidView
    case io
    /// Rename may be visible, but directory durability could not be confirmed.
    case commitUncertain(ViewID)
    case requiresReopen
}

public enum WorkspaceLayoutNotice: Equatable, Sendable {
    case corrupt
    case newerVersion(Int)
}

public struct WorkspaceLayoutOpenResult {
    public let session: WorkspaceLayoutSession
    public let notice: WorkspaceLayoutNotice?
}

/// The caller retains this session for the lifetime of its view and writer lock.
public final class WorkspaceLayoutSession {
    public let viewID: ViewID
    public let isPrimary: Bool
    public let directoryURL: URL
    public private(set) var view: WorkspaceView
    public private(set) var revision: UInt64
    public private(set) var requiresReopen = false

    private let directoryFD: Int32
    private let lockFD: Int32
    private let projectKey: String
    private let failDirectorySyncAfterRename: Bool

    fileprivate init(viewID: ViewID, isPrimary: Bool, directoryURL: URL, directoryFD: Int32,
                     lockFD: Int32, projectKey: String, view: WorkspaceView, revision: UInt64,
                     failDirectorySyncAfterRename: Bool) {
        self.viewID = viewID
        self.isPrimary = isPrimary
        self.directoryURL = directoryURL
        self.directoryFD = directoryFD
        self.lockFD = lockFD
        self.projectKey = projectKey
        self.view = view
        self.revision = revision
        self.failDirectorySyncAfterRename = failDirectorySyncAfterRename
    }

    deinit {
        _ = flock(lockFD, LOCK_UN)
        _ = close(lockFD)
        _ = close(directoryFD)
    }

    /// After an uncertain commit, discard this session and reopen to reconcile the visible revision.
    public func save(_ next: WorkspaceView) throws {
        guard !requiresReopen else { throw WorkspaceLayoutStoreError.requiresReopen }
        guard next.id == viewID, WorkspaceLayoutStore.valid(next), revision < UInt64.max else {
            throw WorkspaceLayoutStoreError.invalidView
        }
        let document = SavedLayout(version: 1, projectKey: projectKey, viewID: viewID.rawValue,
                                   revision: revision + 1, view: next)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(document)
        guard bytes.count <= WorkspaceLayoutStore.maximumDocumentBytes else {
            throw WorkspaceLayoutStoreError.invalidView
        }
        do {
            try WorkspaceLayoutStore.atomicWrite(bytes, in: directoryFD,
                                                  name: "\(viewID.rawValue.uuidString).json",
                                                  viewID: viewID,
                                                  failDirectorySyncAfterRename: failDirectorySyncAfterRename)
        } catch WorkspaceLayoutStoreError.commitUncertain {
            requiresReopen = true
            throw WorkspaceLayoutStoreError.commitUncertain(viewID)
        }
        view = next
        revision += 1
    }
}

public enum WorkspaceLayoutStore {
    public static let maximumDocumentBytes = 65_536

    /// `canonicalOriginalProject` is the host's resolved original project path, never a mounted workspace path.
    public static func open(canonicalOriginalProject: String,
                            configurationDirectory: URL? = nil) throws -> WorkspaceLayoutOpenResult {
        try openImpl(canonicalOriginalProject: canonicalOriginalProject,
                     configurationDirectory: configurationDirectory,
                     failDirectorySyncAfterRename: false)
    }

    /// Instance-local fault seam used by disposable-root durability tests.
    static func openForTesting(canonicalOriginalProject: String, configurationDirectory: URL,
                               failDirectorySyncAfterRename: Bool) throws -> WorkspaceLayoutOpenResult {
        try openImpl(canonicalOriginalProject: canonicalOriginalProject,
                     configurationDirectory: configurationDirectory,
                     failDirectorySyncAfterRename: failDirectorySyncAfterRename)
    }

    private static func openImpl(canonicalOriginalProject: String, configurationDirectory: URL?,
                                 failDirectorySyncAfterRename: Bool) throws -> WorkspaceLayoutOpenResult {
        guard canonicalOriginalProject.hasPrefix("/"),
              let resolved = realpath(canonicalOriginalProject, nil) else {
            throw WorkspaceLayoutStoreError.invalidProject
        }
        defer { free(resolved) }
        guard canonicalOriginalProject == String(cString: resolved) else {
            throw WorkspaceLayoutStoreError.invalidProject
        }
        var projectStatus = stat()
        guard stat(canonicalOriginalProject, &projectStatus) == 0,
              projectStatus.st_mode & S_IFMT == S_IFDIR else {
            throw WorkspaceLayoutStoreError.invalidProject
        }
        let digest = SHA256.hash(data: Data(canonicalOriginalProject.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let primaryID = ViewID(deterministicUUID(digest))
        let root: URL
        if let configurationDirectory {
            root = configurationDirectory
        } else {
            guard let home = ProcessInfo.processInfo.environment["HOME"],
                  home.hasPrefix("/"), !home.contains("\0") else {
                throw WorkspaceLayoutStoreError.unsafeDirectory
            }
            root = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".config/rv", isDirectory: true)
        }
        let directoryURL = root.appendingPathComponent("workspace-layouts", isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
        let directoryFD = try createTrustedDirectory(directoryURL.path, privateFrom: root.path)
        var directoryTransferred = false
        do {
            let primaryLock = try acquireLock("primary.lock", in: directoryFD)
            let primary: SavedLayout?
            let notice: WorkspaceLayoutNotice?
            do {
                primary = try readDocument(in: directoryFD, name: "\(primaryID.rawValue.uuidString).json",
                                           projectKey: digest, viewID: primaryID)
                notice = nil
            } catch let error as DocumentError {
                primary = nil
                switch error {
                case .corrupt: notice = .corrupt
                case .newer(let version): notice = .newerVersion(version)
                }
            }
            if let primaryLock, notice == nil {
                let view = primary?.makeView() ?? WorkspaceView(id: primaryID)
                directoryTransferred = true
                return WorkspaceLayoutOpenResult(
                    session: WorkspaceLayoutSession(viewID: primaryID, isPrimary: true,
                                                    directoryURL: directoryURL, directoryFD: directoryFD,
                                                    lockFD: primaryLock, projectKey: digest,
                                                    view: view, revision: primary?.revision ?? 0,
                                                    failDirectorySyncAfterRename: failDirectorySyncAfterRename),
                    notice: nil)
            }
            if let primaryLock { _ = close(primaryLock) }
            let secondaryID = ViewID()
            let secondaryLock = try acquireLock("\(secondaryID.rawValue.uuidString).lock", in: directoryFD)
            guard let secondaryLock else { throw WorkspaceLayoutStoreError.io }
            let copied = primary?.makeView(id: secondaryID) ?? WorkspaceView(id: secondaryID)
            directoryTransferred = true
            let session = WorkspaceLayoutSession(viewID: secondaryID, isPrimary: false,
                                                 directoryURL: directoryURL, directoryFD: directoryFD,
                                                 lockFD: secondaryLock, projectKey: digest,
                                                 view: copied, revision: 0,
                                                 failDirectorySyncAfterRename: failDirectorySyncAfterRename)
            // A busy primary yields an independently committed view immediately. A damaged
            // primary remains untouched, and its temporary replacement saves only on demand.
            if notice == nil && primary != nil { try session.save(copied) }
            return WorkspaceLayoutOpenResult(session: session, notice: notice)
        } catch {
            if !directoryTransferred { _ = close(directoryFD) }
            throw error
        }
    }

    fileprivate static func valid(_ view: WorkspaceView) -> Bool {
        guard view.tabs.count <= PaneTree.maximumLeaves,
              view.panes.count <= PaneTree.maximumLeaves else { return false }
        var totalNodes = 0
        for tab in view.tabs {
            var pending = [tab.tree]
            while let tree = pending.popLast() {
                totalNodes += 1
                if totalNodes > 15 { return false }
                if case .split(_, _, let ratio, let first, let second) = tree {
                    if !(1...999).contains(ratio.thousandths) { return false }
                    pending.append(first)
                    pending.append(second)
                }
            }
            if !validTitle(tab.userTitle) { return false }
        }
        for pane in view.panes.values where !validTitle(pane.userTitle) { return false }
        return view.validate().isEmpty
    }

    private static func validTitle(_ title: String?) -> Bool {
        guard let title else { return true }
        return title.utf8.count <= 256 && !title.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }

    private static func deterministicUUID(_ digest: String) -> UUID {
        let head = String(digest.prefix(32))
        let formatted = "\(head.prefix(8))-\(head.dropFirst(8).prefix(4))-\(head.dropFirst(12).prefix(4))-\(head.dropFirst(16).prefix(4))-\(head.dropFirst(20).prefix(12))"
        return UUID(uuidString: formatted) ?? UUID()
    }

    private static func createTrustedDirectory(_ path: String, privateFrom root: String) throws -> Int32 {
        guard path.hasPrefix("/") else { throw WorkspaceLayoutStoreError.unsafeDirectory }
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw WorkspaceLayoutStoreError.io }
        let components = path.split(separator: "/").map(String.init)
        let privateIndex = root.split(separator: "/").count - 1
        for (index, component) in components.enumerated() {
            guard component != ".", component != ".." else {
                _ = close(current)
                throw WorkspaceLayoutStoreError.unsafeDirectory
            }
            if mkdirat(current, component, 0o700) != 0 && errno != EEXIST {
                _ = close(current)
                throw WorkspaceLayoutStoreError.io
            }
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            _ = close(current)
            guard next >= 0 else { throw WorkspaceLayoutStoreError.unsafeDirectory }
            var status = stat()
            guard fstat(next, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
                  status.st_uid == geteuid() || status.st_uid == 0 else {
                _ = close(next)
                throw WorkspaceLayoutStoreError.unsafeDirectory
            }
            if index >= privateIndex, status.st_uid == geteuid(), status.st_mode & 0o077 != 0,
               status.st_mode & 0o022 == 0 {
                // A sibling tool may have created our subtree with default
                // (non-other-writable) permissions. Tightening an owned
                // directory via its fd can only remove access; re-stat
                // before trusting the result. Other-writable directories
                // still fail closed below.
                guard fchmod(next, 0o700) == 0, fstat(next, &status) == 0 else {
                    _ = close(next)
                    throw WorkspaceLayoutStoreError.unsafeDirectory
                }
            }
            let writableByOthers = status.st_mode & 0o022 != 0
            let stickyRoot = status.st_uid == 0 && status.st_mode & 0o1000 != 0
            if (index >= privateIndex && (status.st_uid != geteuid() || status.st_mode & 0o077 != 0)) ||
                (writableByOthers && !stickyRoot) {
                _ = close(next)
                throw WorkspaceLayoutStoreError.unsafeDirectory
            }
            current = next
        }
        return current
    }

    private static func acquireLock(_ name: String, in directoryFD: Int32) throws -> Int32? {
        let fd = openat(directoryFD, name, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WorkspaceLayoutStoreError.io }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(), status.st_mode & 0o077 == 0, status.st_nlink == 1 else {
            _ = close(fd)
            throw WorkspaceLayoutStoreError.unsafeDirectory
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            _ = close(fd)
            if code == EWOULDBLOCK || code == EAGAIN { return nil }
            throw WorkspaceLayoutStoreError.io
        }
        return fd
    }

    private static func readDocument(in directoryFD: Int32, name: String,
                                     projectKey: String, viewID: ViewID) throws -> SavedLayout? {
        let fd = openat(directoryFD, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw DocumentError.corrupt
        }
        defer { _ = close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(), status.st_mode & 0o077 == 0,
              status.st_nlink == 1, status.st_size >= 0,
              status.st_size <= maximumDocumentBytes else { throw DocumentError.corrupt }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw DocumentError.corrupt
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            if data.count > maximumDocumentBytes { throw DocumentError.corrupt }
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["version"] as? Int else { throw DocumentError.corrupt }
        if version > 1 { throw DocumentError.newer(version) }
        guard version == 1, boundedJSON(root),
              let document = try? JSONDecoder().decode(SavedLayout.self, from: data),
              document.projectKey == projectKey, document.viewID == viewID.rawValue,
              document.panes.count <= PaneTree.maximumLeaves,
              Set(document.panes.map(\.id)).count == document.panes.count,
              valid(document.makeView()) else { throw DocumentError.corrupt }
        return document
    }

    private static func boundedJSON(_ root: [String: Any]) -> Bool {
        var pending: [(Any, Int)] = [(root, 0)]
        var nodes = 0
        while let (value, depth) = pending.popLast() {
            nodes += 1
            if nodes > 512 || depth > 32 { return false }
            if let dictionary = value as? [String: Any] {
                pending.append(contentsOf: dictionary.values.map { ($0, depth + 1) })
            } else if let array = value as? [Any] {
                pending.append(contentsOf: array.map { ($0, depth + 1) })
            } else if let string = value as? String, string.utf8.count > 1024 {
                return false
            }
        }
        return true
    }

    fileprivate static func atomicWrite(_ bytes: Data, in directoryFD: Int32, name: String,
                                        viewID: ViewID, failDirectorySyncAfterRename: Bool) throws {
        let temporary = ".\(UUID().uuidString).tmp"
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WorkspaceLayoutStoreError.io }
        var committed = false
        defer {
            _ = close(fd)
            if !committed { _ = unlinkat(directoryFD, temporary, 0) }
        }
        guard fchmod(fd, 0o600) == 0 else { throw WorkspaceLayoutStoreError.io }
        try bytes.withUnsafeBytes { raw in
            guard let start = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, start.advanced(by: offset), raw.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw WorkspaceLayoutStoreError.io }
                offset += written
            }
        }
        guard fsync(fd) == 0, renameat(directoryFD, temporary, directoryFD, name) == 0 else {
            throw WorkspaceLayoutStoreError.io
        }
        committed = true
        guard !failDirectorySyncAfterRename, fsync(directoryFD) == 0 else {
            throw WorkspaceLayoutStoreError.commitUncertain(viewID)
        }
    }
}

private enum DocumentError: Error {
    case corrupt
    case newer(Int)
}

private struct SavedLayout: Codable {
    let version: Int
    let projectKey: String
    let viewID: UUID
    let revision: UInt64
    let tabs: [SavedTab]
    let activeTabID: TabID?
    let panes: [SavedPane]

    init(version: Int, projectKey: String, viewID: UUID, revision: UInt64, view: WorkspaceView) {
        self.version = version
        self.projectKey = projectKey
        self.viewID = viewID
        self.revision = revision
        tabs = view.tabs.map { SavedTab(id: $0.id, title: $0.userTitle,
                                        tree: $0.tree, focusedPaneID: $0.focusedPaneID) }
        activeTabID = view.activeTabID
        panes = view.panes.values.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
            .map { SavedPane(id: $0.id, title: $0.userTitle,
                             binding: $0.binding.map { SavedBinding(workspace: $0.workspace.rawValue,
                                                                     runtime: $0.runtime.rawValue) }) }
    }

    func makeView(id: ViewID? = nil) -> WorkspaceView {
        let restoredID = id ?? ViewID(viewID)
        let restored = panes.map { pane in
            WorkspacePane(id: pane.id, userTitle: pane.title,
                          binding: pane.binding.map {
                              RuntimeBinding(workspace: WorkspaceSessionID(rawValue: $0.workspace),
                                             runtime: RuntimeSessionID(rawValue: $0.runtime), generation: 0)
                          }, lifecycle: pane.binding == nil ? .empty : .disconnected)
        }
        return WorkspaceView(id: restoredID,
                             tabs: tabs.map { WorkspaceTab(id: $0.id, userTitle: $0.title,
                                                            tree: $0.tree, focusedPaneID: $0.focusedPaneID) },
                             activeTabID: activeTabID,
                             panes: Dictionary(uniqueKeysWithValues: restored.map { ($0.id, $0) }))
    }
}

private struct SavedTab: Codable {
    let id: TabID
    let title: String?
    let tree: PaneTree
    let focusedPaneID: PaneID
}

private struct SavedPane: Codable {
    let id: PaneID
    let title: String?
    let binding: SavedBinding?
}

private struct SavedBinding: Codable {
    let workspace: UUID
    let runtime: UUID
}
#endif
