import Darwin
import Foundation
import Testing
@testable import RVPolicy

/// SecureFileIO is the single owner of owner-only persistence choreography:
/// prepare a 0700 directory, write atomically via tmp+rename, keep files 0600.
struct SecureFileIOTests {
    @Test func writeCreatesOwnerOnlyFileAndDirectory() throws {
        let root = try makeRoot("sio-create")
        let dir = root.appendingPathComponent("nested/config", isDirectory: true)
        let file = dir.appendingPathComponent("store.jsonl", isDirectory: false)

        try SecureFileIO.writeAtomicallyOwnerOnly("hello\n", to: file)

        #expect(try String(contentsOf: file, encoding: .utf8) == "hello\n")
        #expect(try posixMode(dir) == 0o700)
        #expect(try posixMode(file) == 0o600)
    }

    @Test func writeOverwritesExistingContent() throws {
        let root = try makeRoot("sio-overwrite")
        let dir = root.appendingPathComponent("config", isDirectory: true)
        let file = dir.appendingPathComponent("store.toml", isDirectory: false)

        try SecureFileIO.writeAtomicallyOwnerOnly("first\n", to: file)
        try SecureFileIO.writeAtomicallyOwnerOnly("second\n", to: file)

        #expect(try String(contentsOf: file, encoding: .utf8) == "second\n")
        #expect(try posixMode(file) == 0o600)
    }

    @Test func writeReassertsOwnerOnlyOnPreexistingLooseFile() throws {
        let root = try makeRoot("sio-loose")
        let dir = root.appendingPathComponent("config", isDirectory: true)
        let file = dir.appendingPathComponent("config.toml", isDirectory: false)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "loose\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        try SecureFileIO.writeAtomicallyOwnerOnly("hardened\n", to: file)

        #expect(try String(contentsOf: file, encoding: .utf8) == "hardened\n")
        #expect(try posixMode(file) == 0o600)
    }
}

/// PacksConfigStore.save must harden config.toml like every other artifact in
/// the same `~/.config/rv` tree (0700 directory, 0600 file) and serialize the
/// read-merge-write under the exclusive lock.
@Test func packsConfigSaveHardensPermissionsAndLock() throws {
    let home = try HomeDirectory(validating: makeRoot("packs-hard").path)!
    let configDir = RVPolicyPaths.configDirectory(home: home)

    try PacksConfigStore.save(PacksConfig(enabled: ["kubernetes"], disabled: []), home: home)

    let url = PacksConfigStore.configURL(home: home)
    #expect(try String(contentsOf: url, encoding: .utf8).contains("kubernetes"))
    #expect(try posixModeShared(configDir) == 0o700)
    #expect(try posixModeShared(url) == 0o600)
    #expect(FileManager.default.fileExists(
        atPath: RVPolicyPaths.packsConfigLockFile(inConfigDir: configDir).path))
    #expect(RVPolicyPaths.uninstallArtifacts(inConfigDir: configDir).contains(
        RVPolicyPaths.packsConfigLockFile(inConfigDir: configDir)))
}

private func makeRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-sio-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func posixMode(_ url: URL) throws -> Int {
    try posixModeShared(url)
}

private func posixModeShared(_ url: URL) throws -> Int {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let raw = attrs[.posixPermissions] as? NSNumber
    return (raw?.intValue ?? 0) & 0o777
}
