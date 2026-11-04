import Containerization
import ContainerizationArchive
import ContainerizationExtras
import ContainerizationOCI
import CryptoKit
import Darwin
import Foundation
import RVMicroVMCore

struct AssetError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Root filesystem capacity. The ext4 file is sparse, and every launch gets
/// a clonefile copy, so unused capacity costs nothing.
let rootfsCapacity: UInt64 = 8.gib()
let guestPlatform = Platform(arch: "arm64", os: "linux")

/// Downloads, verifies and caches everything a launch needs. The launch
/// path never touches the network: `run` only reads what this wrote.
/// Every file is written to a temporary name and renamed into place.
struct AssetPreparer {
    let layout: MicroVMLayout

    func prepare(image reference: String?, relayBinary: URL) async throws {
        let lock = try FileLock(path: layout.lockFile)
        defer { lock.release() }
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        try installGuestRelay(from: relayBinary)
        try await prepareKernel()
        let store = try ImageStore(path: layout.store)
        try await prepareInitfs(store: store)
        if let reference {
            try await prepareImage(reference, store: store)
        }
    }

    private func installGuestRelay(from source: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: source.path) else {
            throw AssetError("guest relay binary not found at \(source.path)")
        }
        try FileManager.default.createDirectory(at: layout.guestTools, withIntermediateDirectories: true)
        if FileManager.default.contentsEqual(atPath: source.path, andPath: layout.guestRelay.path) { return }
        let staged = layout.guestTools.appendingPathComponent(".\(MicroVMGuest.relayName).\(getpid())")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.copyItem(at: source, to: staged)
        guard chmod(staged.path, 0o755) == 0, rename(staged.path, layout.guestRelay.path) == 0 else {
            throw AssetError("cannot install guest relay: \(String(cString: strerror(errno)))")
        }
    }

    private func prepareKernel() async throws {
        if (try? sha256(of: layout.kernel)) == MicroVMPins.kernelSHA256 { return }
        try FileManager.default.createDirectory(at: layout.kernelDirectory, withIntermediateDirectories: true)
        report("downloading guest kernel (kata-containers 3.32.0, ~700 MB, once)")
        let (downloaded, response) = try await URLSession.shared.download(from: MicroVMPins.kernelArchiveURL)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw AssetError("kernel download failed: HTTP \(http.statusCode)")
        }
        let archiveDigest = try sha256(of: downloaded)
        guard archiveDigest == MicroVMPins.kernelArchiveSHA256 else {
            throw AssetError("kernel archive digest mismatch: got \(archiveDigest)")
        }
        let staged = layout.kernelDirectory.appendingPathComponent(".vmlinux.\(getpid())")
        defer { try? FileManager.default.removeItem(at: staged) }
        try extractMember(MicroVMPins.kernelMemberPath, from: downloaded, to: staged)
        let kernelDigest = try sha256(of: staged)
        guard kernelDigest == MicroVMPins.kernelSHA256 else {
            throw AssetError("kernel digest mismatch: got \(kernelDigest)")
        }
        guard rename(staged.path, layout.kernel.path) == 0 else {
            throw AssetError("cannot install kernel: \(String(cString: strerror(errno)))")
        }
    }

    private func extractMember(_ member: String, from archive: URL, to destination: URL) throws {
        let reader = try ArchiveReader(file: archive)
        for (entry, stream) in reader.makeStreamingIterator() {
            guard let path = entry.path, path == member || path == "./\(member)" else { continue }
            guard FileManager.default.createFile(atPath: destination.path, contents: nil),
                let handle = FileHandle(forWritingAtPath: destination.path)
            else { throw AssetError("cannot create \(destination.path)") }
            defer { try? handle.close() }
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 20)
            defer { buffer.deallocate() }
            while true {
                let count = stream.read(buffer, maxLength: 1 << 20)
                if count < 0 { throw AssetError("kernel archive is corrupt") }
                if count == 0 { break }
                try handle.write(contentsOf: Data(bytesNoCopy: buffer, count: count, deallocator: .none))
            }
            return
        }
        try reader.throwIfStreamFailed()
        throw AssetError("kernel archive has no \(member)")
    }

    private func prepareInitfs(store: ImageStore) async throws {
        if FileManager.default.fileExists(atPath: layout.initfs.path) { return }
        report("fetching \(MicroVMPins.initImageReference)")
        let directory = layout.initfs.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = directory.appendingPathComponent(".initfs.\(getpid()).ext4")
        try? FileManager.default.removeItem(at: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        let initImage = try await store.getInitImage(reference: MicroVMPins.initImageReference)
        _ = try await initImage.initBlock(at: staged, for: .linuxArm)
        guard rename(staged.path, layout.initfs.path) == 0 else {
            throw AssetError("cannot install init filesystem: \(String(cString: strerror(errno)))")
        }
        // Drop init filesystems cached under an older pin.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where name.hasPrefix("vminit-") && name.hasSuffix(".ext4") && name != layout.initfs.lastPathComponent {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func prepareImage(_ reference: String, store: ImageStore) async throws {
        let image: Containerization.Image
        if let cached = try await store.getOrNil(reference: reference) {
            image = cached
        } else {
            report("pulling \(reference)")
            image = try await store.pull(reference: reference, platform: guestPlatform)
        }
        guard let destination = layout.rootfs(forDigest: image.digest) else {
            throw AssetError("unsupported image digest \(image.digest)")
        }
        if FileManager.default.fileExists(atPath: destination.path) { return }
        report("unpacking \(reference)")
        try FileManager.default.createDirectory(at: layout.rootfsCache, withIntermediateDirectories: true)
        let staged = layout.rootfsCache.appendingPathComponent(".\(destination.lastPathComponent).\(getpid())")
        try? FileManager.default.removeItem(at: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        _ = try await EXT4Unpacker(capacityInBytes: rootfsCapacity).unpack(image, for: guestPlatform, at: staged)
        guard rename(staged.path, destination.path) == 0 else {
            throw AssetError("cannot install root filesystem: \(String(cString: strerror(errno)))")
        }
    }
}

/// Readiness of the cached assets, without network access.
struct AssetStatus {
    let layout: MicroVMLayout

    /// Problems that would stop `run`, empty when ready.
    func problems(image reference: String?) async -> [String] {
        var problems: [String] = []
        let files = FileManager.default
        if !files.fileExists(atPath: layout.kernel.path) { problems.append("guest kernel is not installed") }
        if !files.fileExists(atPath: layout.initfs.path) { problems.append("guest init filesystem is not installed") }
        if !files.isExecutableFile(atPath: layout.guestRelay.path) { problems.append("guest relay is not installed") }
        guard let reference else { return problems }
        do {
            _ = try await cachedRootfs(reference)
        } catch {
            problems.append("\(error)")
        }
        return problems
    }

    /// The image and its cached root filesystem, or an error naming what to prepare.
    func cachedRootfs(_ reference: String) async throws -> (Containerization.Image, URL) {
        let store = try ImageStore(path: layout.store)
        guard let image = try await store.getOrNil(reference: reference),
            let rootfs = layout.rootfs(forDigest: image.digest),
            FileManager.default.fileExists(atPath: rootfs.path)
        else {
            throw AssetError("image \(reference) is not prepared")
        }
        return (image, rootfs)
    }
}

func sha256(of file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Exclusive advisory lock that serializes `prepare` runs.
final class FileLock {
    private let descriptor: Int32

    init(path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        descriptor = open(path.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AssetError("cannot open \(path.path): \(String(cString: strerror(errno)))") }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                close(descriptor)
                throw AssetError("cannot lock \(path.path): \(String(cString: strerror(errno)))")
            }
        }
    }

    func release() {
        close(descriptor)
    }
}
