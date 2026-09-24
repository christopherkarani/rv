import ArgumentParser
import Foundation
import Testing
import RVDomain
import RVPolicy
import RVPresentation
import RVService
import RVTheme
@testable import RVCLI

struct PacksCommandRunTests {
    @Test func list_missingHome() async throws {
        try await withCLIProcess(environment: [:]) {
            let command = try Packs.parse([])
            await #expect(throws: ExitCode(1)) {
                try await command.run()
            }
        }
    }

    @Test func list_defaultPrettyAndRobot() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home) {
            let pretty = try Packs.parse(["--plain", "--no-color"])
            try await pretty.run()
            let robot = try Packs.parse(["--json"])
            try await robot.run()
            let verbose = try Packs.parse([
                "--verbose", "--expand", "--max-patterns", "0", "--search", "git",
            ])
            try await verbose.run()
            let enabled = try Packs.parse(["--enabled", "--category", "core"])
            try await enabled.run()
            let all = try Packs.parse(["--all", "--enabled"])
            try await all.run()
        }
    }

    @Test func list_emptyFilterHints() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home) {
            let none = try Packs.parse(["--search", "zzz-no-such-pack"])
            try await none.run()
            let category = try Packs.parse(["--category", "no-such-category"])
            try await category.run()
        }
        try PacksConfigStore.save(
            PacksConfig(enabled: [], disabled: ["core.git", "core.filesystem", "system.disk"]),
            home: home
        )
        try await withCLIProcess(home: home) {
            let enabled = try Packs.parse(["--enabled"])
            try await enabled.run()
        }
    }

    @Test func filter_trimsEmptyCategoryAndSearch() {
        let snapshot = PacksListSnapshot(packs: [], enabledCount: 0, totalCount: 0)
        let same = PacksListFilter.apply(
            snapshot,
            category: "   ",
            search: "   ",
            enabledOnly: false
        )
        #expect(same.totalCount == 0)
    }

    @Test func enable_missingHomeEmptyAndUnknown() async throws {
        try await withCLIProcess(environment: [:]) {
            let home = try Packs.Enable.parse(["core.git"])
            await #expect(throws: ExitCode(1)) {
                try await home.run()
            }
        }
        let isolated = try isolatedHome()
        try await withCLIProcess(home: isolated) {
            var empty = Packs.Enable()
            empty.ids = []
            await #expect(throws: (any Error).self) {
                try await empty.run()
            }
            let unknown = try Packs.Enable.parse(["not-a-pack"])
            await #expect(throws: ExitCode(1)) {
                try await unknown.run()
            }
            let ok = try Packs.Enable.parse(["core.git"])
            try await ok.run()
            let category = try Packs.Enable.parse(["core"])
            try await category.run()
        }
    }

    @Test func disable_succeedsAndUnwritableConfig() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home) {
            let disable = try Packs.Disable.parse(["core.git"])
            try await disable.run()
        }
        try replacePathWithDirectory(PacksConfigStore.configURL(home: home))
        try await withCLIProcess(home: home) {
            let again = try Packs.Disable.parse(["core.filesystem"])
            await #expect(throws: ExitCode(1)) {
                try await again.run()
            }
        }
        let isolated = try isolatedHome()
        try await withCLIProcess(home: isolated) {
            let unknown = try Packs.Disable.parse(["not-a-pack"])
            await #expect(throws: ExitCode(1)) {
                try await unknown.run()
            }
        }
    }

    @Test func info_missingHomeUnknownAndPrettyRobot() async throws {
        try await withCLIProcess(environment: [:]) {
            let home = try Packs.Info.parse(["core.git"])
            await #expect(throws: ExitCode(1)) {
                try await home.run()
            }
        }
        let isolated = try isolatedHome()
        try await withCLIProcess(home: isolated) {
            let invalid = try Packs.Info.parse(["NOT VALID"])
            await #expect(throws: ExitCode(1)) {
                try await invalid.run()
            }
            let missing = try Packs.Info.parse(["zzz.missing"])
            await #expect(throws: ExitCode(1)) {
                try await missing.run()
            }
            let pretty = try Packs.Info.parse(["core.git"])
            try await pretty.run()
            let robot = try Packs.Info.parse(["--robot", "core.git"])
            try await robot.run()
        }
    }

    @Test func prettyFormat_prettyAppearance() {
        let model = packsViewModel(
            enabled: [.coreGit],
            catalog: [(.coreGit, "git")]
        )
        let text = PacksListFormat.pretty(model, appearance: .pretty(colorOffPalette))
        #expect(text.contains("core.git"))
        let grouped = groupedPacksViewModel(
            rows: [
                GroupedPackRow(
                    id: .coreGit,
                    name: "Core Git",
                    category: "core",
                    description: "git",
                    isEnabled: true,
                    safePatternCount: 0,
                    destructivePatternCount: 1
                ),
            ],
            enabledCount: 1,
            totalCount: 1
        )
        let groupedText = PacksListFormat.prettyGrouped(
            grouped,
            appearance: .pretty(colorOffPalette),
            verbose: false
        )
        #expect(groupedText.contains("core.git"))
        let robotPretty = PacksListFormat.pretty(model, appearance: .robot)
        #expect(robotPretty.contains("core.git"))
        let robotGrouped = PacksListFormat.prettyGrouped(
            grouped,
            appearance: .robot,
            verbose: true,
            expand: true,
            maxPatterns: 1
        )
        #expect(robotGrouped.contains("core.git"))
    }
}

