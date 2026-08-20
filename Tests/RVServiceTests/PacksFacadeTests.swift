import Foundation
import Testing
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
}

private func temporaryHome() throws -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-packs-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}
