import Foundation
import RVDomain
import RVPresentation
import RVService
import Testing
@testable import RVCLI

@Test func packsListPretty_usesPacksRendererLayout() {
    let model = packsViewModel(
        enabled: [.coreFilesystem, .coreGit],
        catalog: [
            (.coreFilesystem, "filesystem"),
            (.coreGit, "git"),
        ]
    )
    let text = PacksListFormat.pretty(model, appearance: .robot)
    #expect(text.contains("core.filesystem"))
    #expect(text.contains("core.git"))
    #expect(text.contains("on"))
    #expect(text.hasPrefix("on ") == false)
    #expect(text.contains("core.filesystem  on") || text.contains("core.filesystem on"))
}

@Test func groupedPacksSortsRowsAndRendersVerboseDetails() throws {
    let sqlite = try #require(PackID(validating: "database.sqlite"))
    let model = groupedPacksViewModel(
        rows: [
            GroupedPackRow(
                id: sqlite,
                name: "SQLite",
                category: "database",
                description: "Protects database commands",
                enabled: false,
                safePatternCount: 1,
                destructivePatternCount: 1,
                safePatterns: [NamedPattern(name: "select", pattern: "SELECT")],
                destructivePatterns: [
                    DestructiveRule(
                        name: "drop",
                        pattern: "DROP TABLE",
                        severity: .critical,
                        reason: "drops data"
                    )
                ]
            ),
            GroupedPackRow(
                id: .coreGit,
                name: "Core Git",
                category: "core",
                description: "Protects git commands",
                enabled: true,
                safePatternCount: 0,
                destructivePatternCount: 1
            ),
        ],
        enabledCount: 1,
        totalCount: 95
    )

    #expect(model.groups.map(\.category) == ["core", "database"])
    let text = PacksListFormat.prettyGrouped(
        model,
        appearance: .robot,
        verbose: true,
        expand: true
    )
    #expect(text.contains("Protects database commands"))
    #expect(text.contains("select: SELECT"))
    #expect(text.contains("drop [critical]: DROP TABLE"))
}

@Test func packListFilterKeepsCatalogCountsForFilteredRobotOutput() throws {
    let snapshot = try PacksFacade.list(home: isolatedHome())
    let filtered = PacksListFilter.apply(
        snapshot,
        category: "core",
        search: nil,
        enabledOnly: true
    )

    #expect(filtered.packs.count == 2)
    #expect(filtered.enabledCount == dayOnePackIDs.count)
    #expect(filtered.totalCount == 95)

    let rows = filtered.packs.map {
        PacksRobotRow(
            id: $0.id,
            name: $0.name,
            category: $0.category,
            description: $0.description,
            enabled: $0.enabled,
            safePatternCount: $0.safePatternCount,
            destructivePatternCount: $0.destructivePatternCount
        )
    }
    let json = RobotDocument.packsList(
        packsRobotPayload(
            rows: rows,
            enabledCount: filtered.enabledCount,
            totalCount: filtered.totalCount
        )
    ).render()
    #expect(json.contains("\"enabled_count\":\(dayOnePackIDs.count)"))
    #expect(json.contains("\"total_count\":95"))
}

@Test func packsCommandProcessUsesFacadeForFilteredRobotAndVerboseOutput() throws {
    let roots = [
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent(),
    ]
    let relatives = [
        ".build/debug/rv",
        ".build/arm64-apple-macosx/debug/rv",
        ".build/x86_64-unknown-linux-gnu/debug/rv",
        ".build/aarch64-unknown-linux-gnu/debug/rv",
    ]
    let binaryCandidates = roots.flatMap { root in
        relatives.map { root.appendingPathComponent($0) }
    }
    let binary = try #require(
        binaryCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    )

    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-packs-command-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let filtered = try runRV(
        binary: binary,
        arguments: ["packs", "--enabled", "--category", "core", "--json"],
        home: home
    )
    #expect(filtered.status == 0)
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(filtered.stdout.utf8)) as? [String: Any]
    )
    #expect(object["enabled_count"] as? Int == dayOnePackIDs.count)
    #expect(object["total_count"] as? Int == 95)
    #expect((object["packs"] as? [[String: Any]])?.count == 2)

    let verbose = try runRV(
        binary: binary,
        arguments: ["packs", "--search", "sqlite", "--verbose", "--expand", "--plain"],
        home: home
    )
    #expect(verbose.status == 0)
    #expect(verbose.stdout.contains("database.sqlite"))
    #expect(verbose.stdout.contains("Safe patterns") || verbose.stdout.contains("Destructive patterns"))

    let coreVerbose = try runRV(
        binary: binary,
        arguments: ["packs", "--search", "core.git", "--verbose", "--plain"],
        home: home
    )
    #expect(coreVerbose.status == 0)
    #expect(coreVerbose.stdout.contains("\\ rewrite history") == false)
}

private func runRV(
    binary: URL,
    arguments: [String],
    home: URL
) throws -> (status: Int32, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    process.environment = [
        "HOME": home.path,
        "PATH": "/usr/bin:/bin",
        "TERM": "dumb",
    ]
    process.standardInput = FileHandle.nullDevice
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    return (
        process.terminationStatus,
        String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
        String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    )
}
