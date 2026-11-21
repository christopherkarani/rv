import Foundation
import Testing
@testable import RVFileStore

struct OwnerOnlyFileTests {
    @Test func replace_writesAnOwnerOnlyFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state.json")
        #expect(OwnerOnlyFile.replace(Data("new".utf8), at: file) == .replaced)
        #expect(try Data(contentsOf: file) == Data("new".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o600)
    }

    /// A directory sync that fails after the rename still leaves the new
    /// file in place, and `replace` says so.
    @Test func replace_aFailedDirectorySyncAfterTheRenameIsStillReplaced() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state.json")
        try Data("old".utf8).write(to: file)
        let result = OwnerOnlyFile.replace(Data("new".utf8), at: file, syncDirectory: { _ in false })
        #expect(result == .replacedDirectoryNotSynced)
        #expect(try Data(contentsOf: file) == Data("new".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["state.json"])
    }

    @Test func replace_aTargetThatCannotBeRenamedOverIsNotReplaced() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A non-empty directory at the target: rename(2) refuses it, even
        // for root.
        let target = directory.appendingPathComponent("state.json", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("kept".utf8).write(to: target.appendingPathComponent("inner"))
        #expect(OwnerOnlyFile.replace(Data("new".utf8), at: target) == .notReplaced)
        #expect(OwnerOnlyFile.write(Data("new".utf8), to: target) == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["state.json"])
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-owner-only-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
