import Foundation
import Testing
import RVDomain
import RVPolicy
import RVService

@Suite struct PacksFacadeTests {
    @Test func packsJSON_freshHomeHasTwoEnabledOfNinetyNine() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let snapshot = try PacksFacade.list(home: home)
        #expect(snapshot.totalCount == 99)
        #expect(snapshot.enabledCount == 2)
        #expect(Set(snapshot.packs.filter(\.enabled).map(\.id.rawValue)) == [
            "core.filesystem", "core.git",
        ])
    }

    @Test func enableDatabaseThenDisableRedis() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        let enabled = try PacksFacade.enable(home: home, ids: ["database"])
        #expect(enabled.enabledCount == 10)

        let afterRedis = try PacksFacade.disable(home: home, ids: ["database.redis"])
        #expect(afterRedis.enabledCount == 9)
        let snapshot = try PacksFacade.list(home: home, enabledOnly: true)
        let ids = Set(snapshot.packs.map(\.id.rawValue))
        #expect(ids.contains("database.sqlite"))
        #expect(!ids.contains("database.redis"))
    }

    @Test func enablePresetAndUnknownFailsWithoutWrite() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        let preset = try PacksFacade.enable(home: home, ids: ["careful_company_running_windows"])
        #expect(preset.enabledCount == 38)

        let before = try PacksConfigStore.load(home: home)
        #expect(throws: PacksCommandError.unknownID("paranoid")) {
            _ = try PacksFacade.enable(home: home, ids: ["paranoid"])
        }
        let after = try PacksConfigStore.load(home: home)
        #expect(before == after)
    }

    @Test func disableAlreadyOffExtraIsNoOp() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let result = try PacksFacade.disable(home: home, ids: ["database.sqlite"])
        #expect(result.changed.isEmpty)
        #expect(result.enabledCount == 2)
    }

    @Test func secondEnableIsIdempotent() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        _ = try PacksFacade.enable(home: home, ids: ["database.sqlite"])
        let second = try PacksFacade.enable(home: home, ids: ["database.sqlite"])
        #expect(second.changed.isEmpty)
        #expect(second.enabledCount == 3)
    }

    @Test func enablePreservesNonPacksTomlSections() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let url = PacksConfigStore.configURL(home: home)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        [theme]
        mode = "dark"
        """.write(to: url, atomically: true, encoding: .utf8)

        _ = try PacksFacade.enable(home: home, ids: ["database.sqlite"])
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("[theme]"))
        #expect(text.contains("mode = \"dark\""))
        #expect(text.contains("[packs]"))
        #expect(text.contains("database.sqlite"))
    }

    @Test func effectiveIDs_emptyHomeIsDayOne() throws {
        #expect(try PacksFacade.effectiveIDs(home: "") == dayOnePackIDs)
    }

    @Test func effectiveIDs_missingConfigTomlIsDayOne() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        #expect(
            FileManager.default.fileExists(atPath: PacksConfigStore.configURL(home: home).path)
                == false
        )
        #expect(try PacksFacade.effectiveIDs(home: home) == dayOnePackIDs)
    }

    @Test func effectiveIDs_configTomlExtraPackIsIncluded() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try PacksConfigStore.save(
            PacksConfig(enabled: ["database.sqlite"], disabled: []),
            home: home
        )
        let ids = try PacksFacade.effectiveIDs(home: home)
        #expect(Set(dayOnePackIDs).isSubset(of: Set(ids)))
        #expect(ids.contains(PackID(rawValue: "database.sqlite")))
    }
}

private func temporaryHome() throws -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-packs-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}
