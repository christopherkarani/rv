import Foundation
import Testing
import RVFileStore

struct OwnerOnlyFileTests {
    /// A regular file passed as the config directory fails the
    /// `O_DIRECTORY` open with ENOTDIR, producing `.inaccessible` rather
    /// than `.missing`. This is the deterministic trigger for the error
    /// case that motivated the 5-case loader taxonomy (Vault maps it to
    /// `.unreadable` while the sibling stores map it to `.unsafeLocation`).
    @Test func fileAsDirectoryIsInaccessible() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-owneronly-fileasdir-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(
            OwnerOnlyFile.loadBytes(fileName: "anything.json", from: file, maximumBytes: 1024)
                == .failure(.inaccessible)
        )
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-owneronly-missing-\(UUID().uuidString)")
        #expect(
            OwnerOnlyFile.loadBytes(fileName: "anything.json", from: missing, maximumBytes: 1024)
                == .failure(.missing)
        )
    }
}
