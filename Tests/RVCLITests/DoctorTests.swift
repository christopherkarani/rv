import Foundation
import RVDomain
import RVIPC
import RVPresentation
import RVTheme
import Testing
@testable import RVCLI

private func withDoctorHome(
    _ body: (URL, OwnedPaths, DoctorEnvironment) throws -> Void
) throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-doctor-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    try body(
        home,
        OwnedPaths(home: home.path),
        DoctorEnvironment(
            home: home.path,
            pathEntries: [],
            fileManager: .default,
            launchAgentLoaded: false
        )
    )
}

private let localReady = ServiceDiagnosticResult.local(
    ServiceFallbackDiagnostic(cause: .down, corePacksReady: true)
)

private func runningDoctorSnapshot(packs: [PackID] = dayOnePackIDs) -> DoctorSnapshotReply {
    DoctorSnapshotReply(
        serviceSemver: "1.0.0",
        state: .running,
        idleExitSeconds: 300,
        packsEnabled: packs,
        checks: [DoctorCheck(id: .packs, status: .ok, message: "ready")]
    )
}

@Test func doctor_hostlessTempHomeIsReadOnlyAndMentionsSetup() throws {
    try withDoctorHome { home, _, environment in
        let before = try FileManager.default.contentsOfDirectory(atPath: home.path)

        let health = ServiceHealth.inspect(
            localReady,
            launchAgentInstalled: false,
            launchAgentLoaded: environment.launchAgentLoaded
        )
        #expect(
            health == .notInstalled(
                .init(corePacksReady: true, serviceSemver: nil, launchAgent: .missing)
            )
        )

        let outcome = DoctorRun.run(
            environment: environment,
            diagnostics: localReady,
            appearance: .pretty(colorOffPalette)
        )

        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.contains("not installed"))
        #expect(outcome.stdout.contains("Grok") && outcome.stdout.contains("missing"))
        #expect(outcome.stdout.contains("Pi") && outcome.stdout.contains("missing"))
        #expect(outcome.stdout.contains("OpenCode") && outcome.stdout.contains("missing"))
        #expect(outcome.stdout.contains("→  rv setup"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path) == before)
    }
}

@Test func doctor_wiredGrokReportsWired() throws {
    try withDoctorHome { home, paths, environment in
        let executable = home.appendingPathComponent("bin/rv")
        try makeExecutable(executable)
        try makeExecutable(home.appendingPathComponent("bin/rv-cli"))
        try FileManager.default.createDirectory(
            atPath: paths.grokDirectory,
            withIntermediateDirectories: true
        )
        let body = try SetupHostKind.grok.adapterResource().rendered(rvPath: executable.path)
        try FileManager.default.createDirectory(
            atPath: (paths.grokHook as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try body.write(toFile: paths.grokHook, atomically: true, encoding: .utf8)

        let outcome = DoctorRun.run(
            environment: environment,
            diagnostics: localReady,
            appearance: .pretty(colorOffPalette)
        )

        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.contains("Grok") && outcome.stdout.contains("wired"))
        #expect(outcome.stdout.contains("→  rv setup    Wire Grok") == false)
    }
}

@Test func doctor_reachableServiceReportsLaunchAgentLoadedAndCompatibleVersion() throws {
    try withDoctorHome { _, _, initialEnvironment in
        var environment = initialEnvironment
        environment.launchAgentLoaded = true
        let diagnostics = ServiceDiagnosticResult.xpc(
            snapshot: runningDoctorSnapshot(),
            localCorePacksReady: true
        )
        let health = ServiceHealth.inspect(
            diagnostics,
            launchAgentInstalled: false,
            launchAgentLoaded: environment.launchAgentLoaded
        )
        #expect(
            health == .reachable(
                .init(
                    snapshot: runningDoctorSnapshot(),
                    localCorePacksReady: true,
                    launchAgent: .loaded
                )
            )
        )

        let outcome = DoctorRun.run(
            environment: environment,
            diagnostics: diagnostics,
            appearance: .pretty(colorOffPalette)
        )

        #expect(outcome.stdout.contains("launch-agent loaded"))
        #expect(outcome.stdout.contains("1.0.0 · rv.ipc.v1"))
        #expect(outcome.stdout.contains("dev.rv.evaluate"))
    }
}

@Test func doctor_reachableServiceUsesLaunchAgentProbeState() throws {
    try withDoctorHome { _, _, environment in
        let outcome = DoctorRun.run(
            environment: environment,
            diagnostics: .xpc(
                snapshot: runningDoctorSnapshot(),
                localCorePacksReady: true
            ),
            appearance: .pretty(colorOffPalette)
        )

        #expect(outcome.stdout.contains("launch-agent missing"))
        #expect(outcome.stdout.contains("launch-agent loaded") == false)
    }
}

@Test func doctor_foreignGrokOwnedFileIsOccupiedAndPreserved() throws {
    try withDoctorHome { _, paths, environment in
        let foreign = "{\"hooks\":[]}\n"
        try FileManager.default.createDirectory(
            atPath: (paths.grokHook as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try foreign.write(toFile: paths.grokHook, atomically: true, encoding: .utf8)

        let outcome = DoctorRun.run(
            environment: environment,
            diagnostics: localReady,
            appearance: .pretty(colorOffPalette)
        )

        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.contains("Grok") && outcome.stdout.contains("occupied"))
        #expect(outcome.stdout.contains("rv setup --force"))
        #expect(outcome.stdout.contains("→  rv setup    Wire Grok") == false)
        #expect(try String(contentsOfFile: paths.grokHook, encoding: .utf8) == foreign)
    }
}

@Test func doctor_nonExecutableBakedPathIsBrokenNotWired() throws {
    try withDoctorHome { _, paths, environment in
        try FileManager.default.createDirectory(
            atPath: (paths.grokHook as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let body = try SetupHostKind.grok.adapterResource().rendered(rvPath: "/nonexistent/rv")
        try body.write(toFile: paths.grokHook, atomically: true, encoding: .utf8)

        let outcome = DoctorRun.run(
            environment: environment,
            diagnostics: localReady,
            appearance: .pretty(colorOffPalette)
        )

        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.contains("Grok") && outcome.stdout.contains("broken"))
        #expect(outcome.stdout.contains("→  rv setup"))
        #expect(outcome.stdout.contains("Grok") && outcome.stdout.contains("wired") == false)
    }
}

@Test func doctor_missingRvCliNextToBakedRvIsBrokenNotWired() throws {
    try withDoctorHome { home, paths, environment in
        let executable = home.appendingPathComponent("bin/rv")
        try makeExecutable(executable)
        try FileManager.default.createDirectory(
            atPath: paths.grokDirectory,
            withIntermediateDirectories: true
        )
        let body = try SetupHostKind.grok.adapterResource().rendered(rvPath: executable.path)
        try FileManager.default.createDirectory(
            atPath: (paths.grokHook as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try body.write(toFile: paths.grokHook, atomically: true, encoding: .utf8)

        let pretty = DoctorRun.run(
            environment: environment,
            diagnostics: localReady,
            appearance: .pretty(colorOffPalette)
        )
        let robot = DoctorRun.run(
            environment: environment,
            diagnostics: localReady,
            appearance: .robot
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(robot.stdout.utf8)) as? [String: Any]
        )
        let hosts = try #require(object["hosts"] as? [String: String])

        #expect(pretty.stdout.contains("Grok") && pretty.stdout.contains("broken"))
        #expect(pretty.stdout.contains("wired") == false)
        #expect(hosts["grok"] == "broken")
        #expect(hosts["grok"] != "wired")
        #expect(object["grade"] as? String == "hook")
    }
}

@Test func doctor_nonExecutableRvCliNextToBakedRvIsBrokenNotWired() throws {
    try withDoctorHome { home, paths, environment in
        let executable = home.appendingPathComponent("bin/rv")
        try makeExecutable(executable)
        let cli = home.appendingPathComponent("bin/rv-cli")
        try FileManager.default.createDirectory(
            at: cli.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "not-exec".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: cli.path
        )
        try FileManager.default.createDirectory(
            atPath: paths.grokDirectory,
            withIntermediateDirectories: true
        )
        let body = try SetupHostKind.grok.adapterResource().rendered(rvPath: executable.path)
        try FileManager.default.createDirectory(
            atPath: (paths.grokHook as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try body.write(toFile: paths.grokHook, atomically: true, encoding: .utf8)

        let outcome = DoctorRun.run(
            environment: environment,
            diagnostics: localReady,
            appearance: .pretty(colorOffPalette)
        )
        let robot = DoctorRun.run(
            environment: environment,
            diagnostics: localReady,
            appearance: .robot
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(robot.stdout.utf8)) as? [String: Any]
        )
        let hosts = try #require(object["hosts"] as? [String: String])

        #expect(outcome.stdout.contains("Grok") && outcome.stdout.contains("broken"))
        #expect(outcome.stdout.contains("wired") == false)
        #expect(hosts["grok"] == "broken")
        #expect(object["grade"] as? String == "hook")
    }
}

@Test func doctor_detectedGrokWithoutOwnedFileIsAbsentFile() throws {
    try withDoctorHome { _, paths, environment in
        try FileManager.default.createDirectory(
            atPath: paths.grokDirectory,
            withIntermediateDirectories: true
        )

        let outcome = DoctorRun.run(
            environment: environment,
            diagnostics: localReady,
            appearance: .pretty(colorOffPalette)
        )

        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.contains("Grok") && outcome.stdout.contains("absent-file"))
        #expect(outcome.stdout.contains("→  rv setup"))
        #expect(FileManager.default.fileExists(atPath: paths.grokHook) == false)
    }
}

@Test func doctor_missingDayOnePackExitsOne() throws {
    try withDoctorHome { _, _, environment in
        let outcome = DoctorRun.run(
            environment: environment,
            diagnostics: .xpc(
                snapshot: runningDoctorSnapshot(packs: [.coreGit]),
                localCorePacksReady: true
            ),
            appearance: .pretty(colorOffPalette)
        )

        #expect(outcome.exitCode == 1)
        #expect(outcome.stdout.contains("missing core.filesystem"))
    }
}

@Test func doctor_runningServiceWithUnavailableLocalFallbackExitsOne() throws {
    try withDoctorHome { _, _, environment in
        let outcome = DoctorRun.run(
            environment: environment,
            diagnostics: .xpc(
                snapshot: runningDoctorSnapshot(),
                localCorePacksReady: false
            ),
            appearance: .robot
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8)) as? [String: Any]
        )

        #expect(outcome.exitCode == 1)
        #expect(object["ok"] as? Bool == false)
        let service = try #require(object["service"] as? [String: Any])
        #expect(service["fallback_ready"] as? Bool == false)
    }
}

@Test func doctor_runningServiceWithoutExplicitPackCheckExitsOne() throws {
    try withDoctorHome { _, _, environment in
        let snapshot = DoctorSnapshotReply(
            serviceSemver: "1.0.0",
            state: .running,
            idleExitSeconds: 300,
            packsEnabled: dayOnePackIDs,
            checks: []
        )

        let outcome = DoctorRun.run(
            environment: environment,
            diagnostics: .xpc(snapshot: snapshot, localCorePacksReady: true),
            appearance: .robot
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8)) as? [String: Any]
        )
        let packs = try #require(object["packs"] as? [String: Any])

        #expect(outcome.exitCode == 1)
        #expect(packs["registry"] as? String == "broken")

        let pretty = DoctorRun.run(
            environment: environment,
            diagnostics: .xpc(snapshot: snapshot, localCorePacksReady: true),
            appearance: .pretty(colorOffPalette)
        )
        #expect(pretty.stdout.contains("broken"))
    }
}

@Test func doctor_missingServiceDoesNotInventServiceVersion() throws {
    try withDoctorHome { _, _, environment in
        let outcome = DoctorRun.run(
            environment: environment,
            diagnostics: localReady,
            appearance: .robot
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8)) as? [String: Any]
        )
        let service = try #require(object["service"] as? [String: Any])

        #expect(service["service_semver"] == nil)
    }
}

@Test func doctor_configPathThatIsNotDirectoryExitsOne() throws {
    try withDoctorHome { _, paths, environment in
        try FileManager.default.createDirectory(
            atPath: (paths.configDirectory as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try "not a directory".write(
            toFile: paths.configDirectory,
            atomically: true,
            encoding: .utf8
        )

        let outcome = DoctorRun.run(
            environment: environment,
            diagnostics: localReady,
            appearance: .pretty(colorOffPalette)
        )

        #expect(outcome.exitCode == 1)
        #expect(outcome.stdout.contains("unreadable"))
    }
}

@Test func doctor_robotIsOneJSONObjectWithoutCommandOrTerminalChrome() throws {
    try withDoctorHome { _, _, environment in
        let outcome = DoctorRun.run(
            environment: environment,
            diagnostics: .xpc(
                snapshot: runningDoctorSnapshot(),
                localCorePacksReady: true
            ),
            appearance: .robot
        )
        let data = Data(outcome.stdout.utf8)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(outcome.stdout.split(separator: "\n").count == 1)
        #expect(object["schema"] as? String == "rv.doctor.v1")
        #expect(object["grade"] as? String == "hook")
        #expect(object["ok"] as? Bool == true)
        #expect(object["command"] == nil)
        #expect(object["argv"] == nil)
        #expect(outcome.stdout.contains("\u{001B}") == false)
        #expect(outcome.stdout.contains("═") == false)
    }
}

@Test func doctor_skewFormatsTheSharedWarning() throws {
    try withDoctorHome { _, _, environment in
        let diagnostics = ServiceDiagnosticResult.local(
            ServiceFallbackDiagnostic(
                cause: .skew(.protocolMismatch),
                corePacksReady: true,
                serviceSemver: "1.0.0"
            )
        )
        let health = ServiceHealth.inspect(
            diagnostics,
            launchAgentInstalled: false,
            launchAgentLoaded: false
        )
        #expect(
            health == .skew(
                reason: .protocolMismatch,
                source: .local(
                    .init(
                        corePacksReady: true,
                        serviceSemver: "1.0.0",
                        launchAgent: .missing
                    )
                )
            )
        )

        let outcome = DoctorRun.run(
            environment: environment,
            diagnostics: diagnostics,
            appearance: .pretty(colorOffPalette)
        )

        #expect(outcome.stdout.contains("skew"))
        #expect(outcome.stdout.contains("protocol mismatch"))
        #expect(outcome.stdout.contains("running       ") == false)
    }
}

@Test func doctor_requestFailureFormatsAsDownWithSharedWarning() throws {
    try withDoctorHome { _, _, environment in
        let diagnostics = ServiceDiagnosticResult.local(
            ServiceFallbackDiagnostic(
                cause: .requestFailed(.invalidResponse),
                corePacksReady: true,
                serviceSemver: "1.0.0"
            )
        )
        let health = ServiceHealth.inspect(
            diagnostics,
            launchAgentInstalled: false,
            launchAgentLoaded: false
        )
        #expect(
            health == .requestFailed(
                failure: .invalidResponse,
                local: .init(
                    corePacksReady: true,
                    serviceSemver: "1.0.0",
                    launchAgent: .missing
                )
            )
        )

        let outcome = DoctorRun.run(
            environment: environment,
            diagnostics: diagnostics,
            appearance: .pretty(colorOffPalette)
        )

        #expect(outcome.stdout.contains("down"))
        #expect(outcome.stdout.contains("not installed") == false)
        #expect(outcome.stdout.contains("invalid response"))
    }
}

@Test func doctor_downWithInstalledAgentIsDownNotNotInstalled() throws {
    try withDoctorHome { home, paths, environment in
        try FileManager.default.createDirectory(
            atPath: (paths.launchAgent as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try "plist".write(toFile: paths.launchAgent, atomically: true, encoding: .utf8)
        let before = try FileManager.default.contentsOfDirectory(atPath: home.path)

        let health = ServiceHealth.inspect(
            localReady,
            launchAgentInstalled: true,
            launchAgentLoaded: false
        )
        #expect(
            health == .down(
                .local(.init(corePacksReady: true, serviceSemver: nil, launchAgent: .installed))
            )
        )

        let outcome = DoctorRun.run(
            environment: environment,
            diagnostics: localReady,
            appearance: .pretty(colorOffPalette)
        )

        #expect(outcome.stdout.contains("down"))
        #expect(outcome.stdout.contains("not installed") == false)
        #expect(outcome.stdout.contains("launch-agent installed"))
        #expect(try String(contentsOfFile: paths.launchAgent, encoding: .utf8) == "plist")
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path) == before)
    }
}

@Test func doctor_unavailableLocalCoreReportsNoEnabledPacks() throws {
    try withDoctorHome { _, _, environment in
        let diagnostics = ServiceDiagnosticResult.local(
            ServiceFallbackDiagnostic(cause: .down, corePacksReady: false)
        )
        let health = ServiceHealth.inspect(
            diagnostics,
            launchAgentInstalled: false,
            launchAgentLoaded: false
        )
        #expect(health.enabledPacks.isEmpty)
        #expect(health.packCheckReady == false)
        #expect(health.fallbackReady == false)

        let outcome = DoctorRun.run(
            environment: environment,
            diagnostics: diagnostics,
            appearance: .robot
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8)) as? [String: Any]
        )
        let packs = try #require(object["packs"] as? [String: Any])

        #expect(outcome.exitCode == 1)
        #expect(packs["enabled"] as? [String] == [])
        #expect(packs["registry"] as? String == "broken")
    }
}

@Test func doctor_xpcDownSnapshotFormatsAsDownNotNotInstalled() throws {
    try withDoctorHome { _, _, environment in
        let snapshot = DoctorSnapshotReply(
            serviceSemver: "1.0.0",
            state: .down,
            idleExitSeconds: 300,
            packsEnabled: dayOnePackIDs,
            checks: [DoctorCheck(id: .packs, status: .ok, message: "ready")]
        )
        let diagnostics = ServiceDiagnosticResult.xpc(
            snapshot: snapshot,
            localCorePacksReady: true
        )
        let health = ServiceHealth.inspect(
            diagnostics,
            launchAgentInstalled: false,
            launchAgentLoaded: false
        )
        #expect(
            health == .down(
                .xpc(
                    .init(
                        snapshot: snapshot,
                        localCorePacksReady: true,
                        launchAgent: .missing
                    )
                )
            )
        )

        let outcome = DoctorRun.run(
            environment: environment,
            diagnostics: diagnostics,
            appearance: .pretty(colorOffPalette)
        )

        #expect(outcome.stdout.contains("down"))
        #expect(outcome.stdout.contains("not installed") == false)
        #expect(outcome.stdout.contains("running       ") == false)
    }
}

@Test func doctor_xpcSkewSnapshotFormatsAsSkew() throws {
    try withDoctorHome { _, _, environment in
        let snapshot = DoctorSnapshotReply(
            serviceSemver: "1.0.0",
            state: .skew,
            idleExitSeconds: 300,
            packsEnabled: dayOnePackIDs,
            lastError: "peer supplied detail",
            checks: [DoctorCheck(id: .packs, status: .ok, message: "ready")]
        )
        let diagnostics = ServiceDiagnosticResult.xpc(
            snapshot: snapshot,
            localCorePacksReady: true
        )
        let health = ServiceHealth.inspect(
            diagnostics,
            launchAgentInstalled: false,
            launchAgentLoaded: false
        )
        #expect(
            health == .skew(
                reason: nil,
                source: .xpc(
                    .init(
                        snapshot: snapshot,
                        localCorePacksReady: true,
                        launchAgent: .missing
                    )
                )
            )
        )

        let outcome = DoctorRun.run(
            environment: environment,
            diagnostics: diagnostics,
            appearance: .pretty(colorOffPalette)
        )

        #expect(outcome.stdout.contains("skew"))
        #expect(outcome.stdout.contains("running       ") == false)
        #expect(outcome.stdout.contains("service reported an error"))
        #expect(outcome.stdout.contains("peer supplied detail") == false)
    }
}

@Test func doctor_isRegisteredOnRootCommand() {
    #expect(RV.configuration.subcommands.contains { $0.configuration.commandName == "doctor" })
}
