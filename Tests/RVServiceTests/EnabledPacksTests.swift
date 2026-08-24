import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVService

struct EnabledPacksTests {
    @Test func freshHomeResolvesDayOne() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        #expect(EnabledPacks.resolve(home: home) == WalkSet(ids: dayOnePackIDs))
    }

    @Test func nilHomeResolvesDayOne() {
        #expect(EnabledPacks.resolve(home: nil) == WalkSet(ids: dayOnePackIDs))
    }

    @Test func enabledExtrasResolveBeyondDayOne() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        _ = try PacksFacade.enable(home: home, ids: ["database"])
        let resolved = EnabledPacks.resolve(home: home)
        #expect(resolved.ids.contains(PackID(rawValue: "database.sqlite")))
        #expect(resolved.ids.count == 10)
    }

    @Test func disabledDayOneStaysResolvedOff() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        _ = try PacksFacade.disable(home: home, ids: ["core.git"])
        #expect(EnabledPacks.resolve(home: home).ids.contains(PackID(rawValue: "core.git")) == false)
    }

    @Test func emptyEffectiveConfigStaysEmptyWalkSet() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        try PacksConfigStore.save(
            PacksConfig(
                enabled: [],
                disabled: ["core.git", "core.filesystem"]
            ),
            home: home
        )
        #expect(EnabledPacks.resolve(home: home) == WalkSet(ids: []))
    }
}

private func temporaryHome() throws -> HomeDirectory {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-enabled-packs-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return try #require(HomeDirectory(validating: url.path))
}
