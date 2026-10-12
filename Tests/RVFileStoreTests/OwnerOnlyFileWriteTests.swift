#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
import RVFileStore

struct OwnerOnlyFileWriteTests {
    @Test func stageWrites0600TempWithExactBytes() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dirFd = try openDirectory(directory)
        defer { close(dirFd) }
        for policy in [OwnerOnlyFileWritePolicy.once, OwnerOnlyFileWritePolicy.all] {
            let staged = try #require(
                OwnerOnlyFileWrite.stage(
                    bytes: Data("abc".utf8), fileName: "live.json", tag: "probe",
                    inDirectory: dirFd, policy: policy, attempts: 1
                )
            )
            close(staged.fd)
            let tempURL = directory.appendingPathComponent(staged.name)
            #expect(try posixPermissions(of: tempURL) == 0o600)
            #expect(try Data(contentsOf: tempURL) == Data("abc".utf8))
            #expect(staged.name.hasPrefix(".live.json.probe-"))
            try FileManager.default.removeItem(at: tempURL)
        }
    }

    @Test func stageBadDirectoryFailsWithoutLitter() throws {
        #expect(
            OwnerOnlyFileWrite.stage(
                bytes: Data("x".utf8), fileName: "live.json", tag: "probe",
                inDirectory: -1, policy: .once, attempts: 1
            ) == nil
        )
        #expect(
            OwnerOnlyFileWrite.stage(
                bytes: Data("x".utf8), fileName: "live.json", tag: "probe",
                inDirectory: -1, policy: .all, attempts: 8
            ) == nil
        )
    }

    @Test func zeroAttemptsStillTriesOnce() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dirFd = try openDirectory(directory)
        defer { close(dirFd) }
        let staged = try #require(
            OwnerOnlyFileWrite.stage(
                bytes: Data("x".utf8), fileName: "live.json", tag: "probe",
                inDirectory: dirFd, policy: .once, attempts: 0
            )
        )
        close(staged.fd)
        try FileManager.default.removeItem(at: directory.appendingPathComponent(staged.name))
    }

    @Test func commitRenamesOverLiveWithoutLitter() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dirFd = try openDirectory(directory)
        defer { close(dirFd) }
        let live = directory.appendingPathComponent("live.json")
        try Data("old".utf8).write(to: live)
        let staged = try #require(
            OwnerOnlyFileWrite.stage(
                bytes: Data("new".utf8), fileName: "live.json", tag: "probe",
                inDirectory: dirFd, policy: .all, attempts: 8
            )
        )
        defer { close(staged.fd) }
        #expect(OwnerOnlyFileWrite.commit(staged: staged, as: "live.json", inDirectory: dirFd))
        #expect(try Data(contentsOf: live) == Data("new".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["live.json"])
    }

    @Test func commitFailureUnlinksTemp() throws {
        // A directory wearing the live name makes renameat fail; the temp
        // must be unlinked, not littered.
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("live.json", isDirectory: true),
            withIntermediateDirectories: true
        )
        let dirFd = try openDirectory(directory)
        defer { close(dirFd) }
        let staged = try #require(
            OwnerOnlyFileWrite.stage(
                bytes: Data("x".utf8), fileName: "live.json", tag: "probe",
                inDirectory: dirFd, policy: .once, attempts: 1
            )
        )
        defer { close(staged.fd) }
        #expect(OwnerOnlyFileWrite.commit(staged: staged, as: "live.json", inDirectory: dirFd) == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["live.json"])
    }

    @Test func writeBytesPolicies() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for policy in [OwnerOnlyFileWritePolicy.once, OwnerOnlyFileWritePolicy.all] {
            let file = directory.appendingPathComponent("w-\(policy == .once ? "once" : "all")")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let fd = file.path.withCString { open($0, O_WRONLY | O_CLOEXEC) }
            #expect(fd >= 0)
            defer { close(fd) }
            #expect(OwnerOnlyFileWrite.writeBytes(Data("abc".utf8), to: fd, policy: policy))
            #expect(OwnerOnlyFileWrite.writeBytes(Data("abc".utf8), to: -1, policy: policy) == false)
            #expect(OwnerOnlyFileWrite.writeBytes(Data(), to: fd, policy: policy))
            #expect(try Data(contentsOf: file) == Data("abc".utf8))
        }
    }

    @Test func writeBytesAllLandsLargePayload() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("big")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let fd = file.path.withCString { open($0, O_WRONLY | O_CLOEXEC) }
        #expect(fd >= 0)
        defer { close(fd) }
        let big = Data(repeating: 0x61, count: 1_000_000)
        #expect(OwnerOnlyFileWrite.writeBytes(big, to: fd, policy: .all))
        #expect(try Data(contentsOf: file) == big)
    }

    @Test func verifyIdentityMatchesOnlyTheLiveFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let live = directory.appendingPathComponent("live.json")
        try Data("v1".utf8).write(to: live)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: live.path)
        let dirFd = try openDirectory(directory)
        defer { close(dirFd) }
        let identity = try #require(deviceInode(of: live))
        #expect(
            OwnerOnlyFileWrite.verifyIdentity(
                fileName: "live.json", inDirectory: dirFd,
                expectedDevice: identity.device, expectedInode: identity.inode
            )
        )
        #expect(
            OwnerOnlyFileWrite.verifyIdentity(
                fileName: "live.json", inDirectory: dirFd,
                expectedDevice: identity.device, expectedInode: identity.inode &+ 1
            ) == false
        )
        #expect(
            OwnerOnlyFileWrite.verifyIdentity(
                fileName: "absent.json", inDirectory: dirFd,
                expectedDevice: identity.device, expectedInode: identity.inode
            ) == false
        )
        // A symlink where the file belongs is never followed.
        try FileManager.default.removeItem(at: live)
        let target = directory.appendingPathComponent("target.json")
        try Data("linked".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: live, withDestinationURL: target)
        #expect(
            OwnerOnlyFileWrite.verifyIdentity(
                fileName: "live.json", inDirectory: dirFd,
                expectedDevice: identity.device, expectedInode: identity.inode
            ) == false
        )
    }

    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-owner-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private func openDirectory(_ directory: URL) throws -> Int32 {
        let fd = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        return try #require(fd >= 0 ? fd : nil)
    }

    private func posixPermissions(of file: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func deviceInode(of file: URL) -> (device: UInt64, inode: UInt64)? {
        var status = stat()
        guard file.path.withCString({ stat($0, &status) }) == 0 else { return nil }
        return (UInt64(status.st_dev), UInt64(status.st_ino))
    }
}
