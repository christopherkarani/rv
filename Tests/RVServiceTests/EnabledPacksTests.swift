import Foundation
import Testing
import RVDomain
import RVService

@Suite struct EnabledPacksTests {
    @Test func freshHomeResolvesDayOne() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        #expect(EnabledPacks.resolve(home: home) == dayOnePackIDs)
    }

    @Test func emptyHomeResolvesDayOne() {
        #expect(EnabledPacks.resolve(home: "") == dayOnePackIDs)
    }

    @Test func enabledExtrasResolveBeyondDayOne() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        _ = try PacksFacade.enable(home: home, ids: ["database"])
        let resolved = EnabledPacks.resolve(home: home)
        #expect(resolved.contains(PackID(rawValue: "database.sqlite")))
        #expect(resolved.count == 10)
    }

    @Test func disabledDayOneStaysResolvedOff() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        _ = try PacksFacade.disable(home: home, ids: ["core.git"])
        #expect(EnabledPacks.resolve(home: home).contains(PackID(rawValue: "core.git")) == false)
    }
}

private func temporaryHome() throws -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-enabled-packs-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}
