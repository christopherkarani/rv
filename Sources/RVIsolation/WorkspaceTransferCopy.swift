#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

// MARK: - Copying (planning and paths: WorkspaceTransfer.swift)

private enum DestinationMode {
    /// Upload into the workspace: an existing directory is merged, an
    /// existing non-directory name is unlinked (never followed) and recreated.
    case replace
    /// Download to the host: every name is created fresh (`O_EXCL`).
    case createOnly
}

private struct TreeCopier {
    let prepared: PreparedTransfer
    let mode: DestinationMode
    let limits: WorkspaceTransferLimits
    var copied: UInt64 = 0

    func display(_ path: [String]) -> String {
        let top = prepared.destinationName.map { [$0] } ?? []
        return WorkspaceTransfer.escaped((prepared.destinationLabel + top + path).joined(separator: "/"))
    }

    /// Copies the planned entries in order (each directory precedes its contents).
    mutating func run() -> WorkspaceTransferRefusal? {
        // Open directory pairs for the current chain: index k holds the
        // directory at depth k (the top is depth 0).
        var sources: [Int32] = []
        var destinations: [Int32] = []
        defer {
            sources.forEach { _ = close($0) }
            destinations.forEach { _ = close($0) }
        }
        for entry in prepared.plan.entries {
            while sources.count > entry.path.count {
                close(sources.removeLast())
                close(destinations.removeLast())
            }
            let sourceParent = entry.path.isEmpty ? prepared.sourceParent : sources[entry.path.count - 1]
            let sourceName = entry.path.last ?? prepared.sourceName
            let destinationParent = entry.path.isEmpty ? prepared.destinationParent : destinations[entry.path.count - 1]
            let destinationName = entry.path.last ?? prepared.destinationName
            if entry.isDirectory {
                let source = openDirectoryAt(sourceParent, sourceName)
                guard source >= 0 else { return .changed(display(entry.path)) }
                guard let info = fstatOf(source), NodeIdentity(info) == entry.identity else {
                    close(source)
                    return .changed(display(entry.path))
                }
                switch makeDirectory(destinationParent, destinationName, path: entry.path) {
                case .failure(let refusal):
                    close(source)
                    return refusal
                case .success(let destination):
                    sources.append(source)
                    destinations.append(destination)
                }
            } else if let refusal = copyFile(entry, from: sourceParent, sourceName, to: destinationParent, destinationName) {
                return refusal
            }
        }
        return nil
    }

    private func makeDirectory(_ parent: Int32, _ name: String?, path: [String]) -> Result<Int32, WorkspaceTransferRefusal> {
        guard let name else {
            let fd = dup(parent)
            return fd >= 0 ? .success(fd) : .failure(.io(display(path), errno))
        }
        if name.withCString({ mkdirat(parent, $0, 0o755) }) != 0 {
            let code = errno
            guard code == EEXIST, mode == .replace else {
                return .failure(code == EEXIST ? .changed(display(path)) : .io(display(path), code))
            }
            let (found, _) = lstatAt(parent, name)
            switch found.map(NodeKind.init) {
            case .directory?: break
            case .symlink?: return .failure(.symlink(display(path)))
            default: return .failure(.destinationConflict(display(path)))
            }
        }
        let fd = openDirectoryAt(parent, name)
        guard fd >= 0 else { return .failure(errno == ELOOP ? .symlink(display(path)) : .io(display(path), errno)) }
        guard let info = fstatOf(fd), UInt64(truncatingIfNeeded: info.st_dev) == prepared.destinationDevice else {
            close(fd)
            return .failure(.otherDevice(display(path)))
        }
        return .success(fd)
    }

    private mutating func copyFile(
        _ entry: PlannedEntry, from sourceParent: Int32, _ sourceName: String,
        to destinationParent: Int32, _ destinationName: String?
    ) -> WorkspaceTransferRefusal? {
        guard let destinationName else { return .unsafePath(".") }
        let source = sourceName.withCString { openat(sourceParent, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard source >= 0 else { return .changed(display(entry.path)) }
        defer { close(source) }
        guard let info = fstatOf(source), NodeKind(info) == .file, NodeIdentity(info) == entry.identity else {
            return .changed(display(entry.path))
        }
        if mode == .replace {
            let (found, _) = lstatAt(destinationParent, destinationName)
            if let existing = found {
                guard NodeKind(existing) != .directory else { return .destinationConflict(display(entry.path)) }
                if destinationName.withCString({ unlinkat(destinationParent, $0, 0) }) != 0, errno != ENOENT {
                    return .io(display(entry.path), errno)
                }
            }
        }
        let permissions: mode_t = entry.executable ? 0o755 : 0o644
        let destination = destinationName.withCString {
            openat(destinationParent, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, permissions)
        }
        guard destination >= 0 else {
            return errno == EEXIST ? .changed(display(entry.path)) : .io(display(entry.path), errno)
        }
        defer { close(destination) }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            if count < 0 { return .io(display(entry.path), errno) }
            if count == 0 { return nil }
            copied += UInt64(count)
            if copied > limits.maxBytes { return .tooLarge(limits.maxBytes) }
            var offset = 0
            while offset < count {
                let written = buffer[offset..<count].withUnsafeBytes { write(destination, $0.baseAddress, $0.count) }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return .io(display(entry.path), errno) }
                offset += written
            }
        }
    }
}

extension WorkspaceTransfer {
    static func copyUpload(_ prepared: PreparedTransfer, limits: WorkspaceTransferLimits) -> Result<WorkspaceTransferSummary, WorkspaceTransferRefusal> {
        var copier = TreeCopier(prepared: prepared, mode: .replace, limits: limits)
        if let refusal = copier.run() { return .failure(refusal) }
        return .success(summary(prepared.plan, copied: copier.copied))
    }

    static func copyDownload(_ prepared: PreparedTransfer, limits: WorkspaceTransferLimits) -> Result<WorkspaceTransferSummary, WorkspaceTransferRefusal> {
        var copier = TreeCopier(prepared: prepared, mode: .createOnly, limits: limits)
        if let refusal = copier.run() {
            // Only names this copy created live under the new top.
            if let name = prepared.destinationName { removeTree(prepared.destinationParent, name) }
            return .failure(refusal)
        }
        return .success(summary(prepared.plan, copied: copier.copied))
    }

    private static func summary(_ plan: TransferPlan, copied: UInt64) -> WorkspaceTransferSummary {
        let planned = plan.summary
        return WorkspaceTransferSummary(files: planned.files, directories: planned.directories, bytes: copied, ignored: planned.ignored)
    }

    /// Removes `name` below `parent` without following links.
    private static func removeTree(_ parent: Int32, _ name: String) {
        let (found, _) = lstatAt(parent, name)
        guard let info = found else { return }
        if NodeKind(info) == .directory {
            let fd = openDirectoryAt(parent, name)
            if fd >= 0 {
                for child in directoryNames(fd) ?? [] {
                    if let childName = String(validating: child, as: UTF8.self) { removeTree(fd, childName) }
                }
                close(fd)
            }
            _ = name.withCString { unlinkat(parent, $0, AT_REMOVEDIR) }
        } else {
            _ = name.withCString { unlinkat(parent, $0, 0) }
        }
    }
}
