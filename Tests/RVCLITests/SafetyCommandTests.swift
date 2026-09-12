import Foundation
import Testing
import RVDomain
import RVPolicy
import RVTheme
@testable import RVCLI

struct SafetyCommandTests {
    @Test func registeredAndHelpOmitsPackIDs() {
        let names = RV.configuration.subcommands.map { $0.configuration.commandName }
        #expect(names.contains("safety"))
        let help = Safety.helpMessage()
        #expect(help.contains("normal"))
        #expect(help.contains("strict"))
        #expect(help.contains("core.git") == false)
        #expect(help.contains("core.filesystem") == false)
        #expect(HelpDispatch.text(.safety, palette: colorOffPalette).contains("core.") == false)
    }

    @Test func show_freshHome_isNormal() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        #expect(SafetyRun.show(home: home, workspace: nil) == "normal")
    }

    @Test func set_writesMachineConfig() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        try SafetyRun.set(.strict, home: home)
        #expect(SafetyRun.show(home: home, workspace: nil) == "strict")
        try SafetyRun.set(.normal, home: home)
        #expect(SafetyRun.show(home: home, workspace: nil) == "normal")
    }

    private func tempHome() throws -> HomeDirectory {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-safety-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try #require(HomeDirectory(validating: url.path))
    }
}
