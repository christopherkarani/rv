import ArgumentParser
import Foundation
import Testing
import RVDomain
import RVPolicy
import RVService
@testable import RVCLI

/// G3: a pack change checks every name and `[packs]` before it asks the
/// owner, and names the fix.
@Suite("Packs preflight")
struct PacksPreflightTests {
    @Test func typo_failsWithDidYouMean_beforeTheOwnerIsAsked() async throws {
        let home = try isolatedHome()
        let capture = CLIOutputCapture()
        try await withCLIProcess(home: home, output: capture) {
            let enable = try Packs.Enable.parse(["databse.redis"])
            await #expect(throws: ExitCode(1)) {
                try await enable.run()
            }
        }
        #expect(capture.stderr == "rv: no pack, category or preset is named databse.redis. Did you mean database.redis? rv packs --all lists every pack.\n")
        #expect(capture.stderr.contains("owner authentication") == false)
        #expect(PacksConfigStore.isAbsent(home: home))
    }

    @Test func disableTypo_failsBeforeTheOwnerIsAsked() async throws {
        let home = try isolatedHome()
        let capture = CLIOutputCapture()
        try await withCLIProcess(home: home, output: capture) {
            let disable = try Packs.Disable.parse(["core.gti"])
            await #expect(throws: ExitCode(1)) {
                try await disable.run()
            }
        }
        #expect(capture.stderr.contains("Did you mean core.git?"))
        #expect(capture.stderr.contains("owner authentication") == false)
    }

    @Test func badConfig_failsWithLineAndFix_beforeTheOwnerIsAsked() async throws {
        let home = try isolatedHome()
        try writeConfig("""
        [packs]
        enable = ["database.redis"]
        disabled = ["containers.dockr"]
        """, home: home)
        let before = try Data(contentsOf: PacksConfigStore.configURL(home: home))
        let capture = CLIOutputCapture()
        try await withCLIProcess(home: home, output: capture) {
            let enable = try Packs.Enable.parse(["core.git"])
            await #expect(throws: ExitCode(1)) {
                try await enable.run()
            }
        }
        let path = PacksConfigStore.configURL(home: home).path
        #expect(capture.stderr == """
        rv: [packs] has lines rv does not read, so nothing was changed:
        ✕ \(path):2  unknown key enable in [packs]
        → did you mean enabled?
        ✕ \(path):3  no pack, category or preset is named containers.dockr
        → did you mean containers.docker? rv packs --all lists every pack

        """)
        #expect(try Data(contentsOf: PacksConfigStore.configURL(home: home)) == before)
    }

    /// The body behind the owner check refuses too, so no path saves over
    /// lines it would drop.
    @Test func applyBody_refusesABadConfigWithoutWriting() async throws {
        let home = try isolatedHome()
        try writeConfig("[packs]\nenabled = [database.redis]\n", home: home)
        let before = try Data(contentsOf: PacksConfigStore.configURL(home: home))
        try await withCLIProcess(home: home) {
            await #expect(throws: ExitCode(1)) {
                try applyPackMutation(ids: ["core.git"], enabling: true)
            }
        }
        #expect(try Data(contentsOf: PacksConfigStore.configURL(home: home)) == before)
        #expect(throws: PacksCommandError.self) {
            try PacksFacade.disable(home: home, ids: ["core.git"])
        }
    }

    @Test func list_warnsAboutSkippedLines() async throws {
        let home = try isolatedHome()
        try writeConfig("[packs]\nenabled = [\"database.rediss\"]\n", home: home)
        let capture = CLIOutputCapture()
        try await withCLIProcess(home: home, output: capture) {
            try await Packs.List.parse(["--plain", "--no-color"]).run()
        }
        #expect(capture.stderr.contains("warning: [packs] has lines rv does not read; rv skips them:"))
        #expect(capture.stderr.contains("did you mean database.redis?"))
    }

    @Test func cleanConfig_andCategories_passPreflight() throws {
        let home = try isolatedHome()
        try writeConfig("[packs]\nenabled = [\n  \"database\",\n  \"containers.docker\",\n]\ndisabled = []\n", home: home)
        try PacksFacade.preflight(home: home, ids: ["core.git", "kubernetes", "careful_company_running_windows"])
        #expect(try PacksFacade.configProblems(home: home).isEmpty)
    }
}

private func writeConfig(_ text: String, home: HomeDirectory) throws {
    let url = PacksConfigStore.configURL(home: home)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}
