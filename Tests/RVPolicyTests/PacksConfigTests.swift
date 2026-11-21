import Foundation
import Testing
import RVDomain
import RVPolicy

@Test func packsConfig_parseRoundTripEmpty() {
    let config = PacksConfig.empty
    let text = PacksConfigStore.render(config)
    #expect(PacksConfigStore.parse(text) == config)
}

@Test func packsConfig_mergePreservesSiblingSections() {
    let existing = """
    [theme]
    mode = "dark"

    [packs]
    enabled = ["database.sqlite"]
    disabled = []

    [history]
    enabled = false
    """
    let merged = PacksConfigStore.mergePacksSection(
        existing: existing,
        config: PacksConfig(enabled: ["kubernetes"], disabled: ["database.redis"])
    )
    #expect(merged.contains("[theme]"))
    #expect(merged.contains("mode = \"dark\""))
    #expect(merged.contains("[history]"))
    #expect(merged.contains("enabled = false"))
    let packs = PacksConfigStore.parse(merged)
    #expect(packs.enabled == ["kubernetes"])
    #expect(packs.disabled == ["database.redis"])
    #expect(!merged.contains("database.sqlite"))
}

@Test func packsConfig_mergeIntoEmptyExisting() {
    let merged = PacksConfigStore.mergePacksSection(
        existing: "   \n",
        config: PacksConfig(enabled: ["containers.docker"], disabled: [])
    )
    #expect(merged.hasPrefix("[packs]"))
    #expect(PacksConfigStore.parse(merged).enabled == ["containers.docker"])
}

/// `config.toml` goes through the owner-config write: an owner-only file
/// in an owner-only directory, as `config.json` always was.
@Test func packsConfig_saveWritesAnOwnerOnlyFileInAnOwnerOnlyDirectory() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-packs-mode-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = try #require(HomeDirectory(validating: root.path))
    let file = PacksConfigStore.configURL(home: home)
    let directory = file.deletingLastPathComponent()
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])

    try PacksConfigStore.save(PacksConfig(enabled: ["cloud.aws"]), home: home)

    #expect(try packsPosixMode(file) == 0o600)
    #expect(try packsPosixMode(directory) == 0o700)
    #expect(try PacksConfigStore.load(home: home).enabled == ["cloud.aws"])
}

private func packsPosixMode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
}
