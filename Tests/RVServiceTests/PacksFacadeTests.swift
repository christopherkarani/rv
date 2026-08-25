import Foundation
import RVDomain
import Testing
import RVDomain
import RVPolicy
import RVService

@Suite struct PacksFacadeTests {
    @Test func packsJSON_freshHomeHasTwoEnabledOfNinetyFive() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let snapshot = try PacksFacade.list(home: home)
        #expect(snapshot.totalCount == 95)
        #expect(snapshot.enabledCount == 2)
        #expect(Set(snapshot.packs.filter(\.enabled).map(\.id.rawValue)) == [
            "core.filesystem", "core.git",
        ])
    }

    @Test func enableDatabaseThenDisableRedis() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }

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
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }

        let preset = try PacksFacade.enable(home: home, ids: ["careful_company_running_windows"])
        #expect(preset.enabledCount == 34)
        #expect(!Set(try PacksFacade.effectiveIDs(home: home).map(\.rawValue)).contains("windows.filesystem"))

        let before = try PacksConfigStore.load(home: home)

        #expect(throws: PacksCommandError.unknownID(.id(PackID(rawValue: "windows.filesystem")))) {
            _ = try PacksFacade.enable(home: home, ids: ["windows.filesystem"])
        }
        #expect(throws: PacksCommandError.unknownID(.id(PackID(rawValue: "paranoid")))) {
            _ = try PacksFacade.enable(home: home, ids: ["paranoid"])
        }
        let after = try PacksConfigStore.load(home: home)
        #expect(before == after)
    }

    @Test func disableAlreadyOffExtraIsNoOp() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let result = try PacksFacade.disable(home: home, ids: ["database.sqlite"])
        #expect(result.changed.isEmpty)
        #expect(result.enabledCount == 2)
    }

    @Test func secondEnableIsIdempotent() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        _ = try PacksFacade.enable(home: home, ids: ["database.sqlite"])
        let second = try PacksFacade.enable(home: home, ids: ["database.sqlite"])
        #expect(second.changed.isEmpty)
        #expect(second.enabledCount == 3)
    }

    @Test func enablePreservesNonPacksTomlSections() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
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

    @Test func effectiveIDs_missingConfigTomlIsDayOne() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        #expect(
            FileManager.default.fileExists(atPath: PacksConfigStore.configURL(home: home).path)
                == false
        )
        #expect(try PacksFacade.effectiveIDs(home: home) == dayOnePackIDs)
    }

    @Test func effectiveIDs_configTomlExtraPackIsIncluded() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        try PacksConfigStore.save(
            PacksConfig(enabled: ["database.sqlite"], disabled: []),
            home: home
        )
        let ids = try PacksFacade.effectiveIDs(home: home)
        #expect(Set(dayOnePackIDs).isSubset(of: Set(ids)))
        #expect(ids.contains(PackID(rawValue: "database.sqlite")))
    }

    @Test func tokenRoundTrip_persistsOperatorStringsVerbatim() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let url = PacksConfigStore.configURL(home: home)

        _ = try PacksFacade.enable(home: home, tokens: [
            .category("kubernetes"),
            .preset("careful_company_running_windows"),
            .id(PackID(rawValue: "strict_git")),
        ])
        _ = try PacksFacade.disable(home: home, tokens: [.id(PackID(rawValue: "core.git"))])

        let text = try String(contentsOf: url, encoding: .utf8)
        let config = PacksConfigStore.parse(text)
        #expect(config.enabled == [
            "careful_company_running_windows",
            "kubernetes",
            "strict_git",
        ])
        #expect(config.disabled == ["core.git"])

        let snapshot = try PacksFacade.list(home: home)
        let enabled = Set(snapshot.packs.filter(\.enabled).map(\.id.rawValue))
        #expect(enabled.contains("kubernetes.helm"))
        #expect(enabled.contains("careful_company_running_windows.chat"))
        #expect(enabled.contains("strict_git"))
        #expect(!enabled.contains("core.git"))
        #expect(!enabled.contains("windows.filesystem"))
        // core.filesystem + kubernetes×3 + ccw category∪preset×32 + strict_git − core.git
        #expect(snapshot.enabledCount == 37)
        #expect(snapshot.totalCount == 95)
    }

    @Test func stringVerbArgsAndTokenArgsAgree() throws {
        let homeA = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: homeA.rawValue) }
        let homeB = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: homeB.rawValue) }

        let fromStrings = try PacksFacade.enable(home: homeA, ids: ["kubernetes"])
        let fromTokens = try PacksFacade.enable(home: homeB, tokens: [.category("kubernetes")])
        #expect(fromStrings.changed.map(\.rawValue) == fromTokens.changed.map(\.rawValue))
        #expect(fromStrings.enabledCount == fromTokens.enabledCount)
    }
}

private func temporaryHome() throws -> HomeDirectory {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-packs-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return try #require(HomeDirectory(validating: url.path))
}
