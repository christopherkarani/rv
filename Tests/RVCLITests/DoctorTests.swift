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
        checks: [DoctorCheck(id: "packs", status: .ok, message: "ready")]
    )
}

@Test func doctor_hostlessTempHomeIsReadOnlyAndMentionsSetup() throws {
    try withDoctorHome { home, _, environment in
        let before = try FileManager.default.contentsOfDirectory(atPath: home.path)

        let outcome = DoctorRun.run(
            environment: environment,
            diagnostics: localReady,
            appearance: .pretty(colorOffPalette)
        )

        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.contains("service: not installed"))
        #expect(outcome.stdout.contains("host Grok: missing — run rv setup"))
        #expect(outcome.stdout.contains("host Pi: missing — run rv setup"))
        #expect(outcome.stdout.contains("host OpenCode: missing — run rv setup"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path) == before)
    }
}

@Test func doctor_wiredGrokReportsWired() throws {
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

        let outcome = DoctorRun.run(
            environment: environment,
            diagnostics: localReady,
            appearance: .pretty(colorOffPalette)
        )

        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.contains("host Grok: wired"))
        #expect(outcome.stdout.contains("host Grok: wired — run rv setup") == false)
    }
}

@Test func doctor_reachableServiceReportsLaunchAgentLoadedAndCompatibleVersion() throws {
    try withDoctorHome { _, _, initialEnvironment in
        var environment = initialEnvironment
        environment.launchAgentLoaded = true
        let outcome = DoctorRun.run(
            environment: environment,
            diagnostics: .xpc(
                snapshot: runningDoctorSnapshot(),
                localCorePacksReady: true
            ),
            appearance: .pretty(colorOffPalette)
        )

        #expect(outcome.stdout.contains("launch-agent: loaded"))
        #expect(outcome.stdout.contains("service-version: 1.0.0 (compatible)"))
        #expect(outcome.stdout.contains("service-label: dev.rv.evaluate"))
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

        #expect(outcome.stdout.contains("launch-agent: missing"))
        #expect(outcome.stdout.contains("launch-agent: loaded") == false)
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
        #expect(outcome.stdout.contains("host Grok: occupied — run rv setup"))
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
        #expect(outcome.stdout.contains("host Grok: broken — run rv setup"))
        #expect(outcome.stdout.contains("host Grok: wired") == false)
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
        #expect(outcome.stdout.contains("host Grok: absent-file — run rv setup"))
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
        #expect(outcome.stdout.contains("packs: missing core.filesystem"))
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
        #expect(pretty.stdout.contains("packs: broken"))
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
        #expect(outcome.stdout.contains("config: unreadable"))
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

@Test func doctor_isRegisteredOnRootCommand() {
    #expect(RV.configuration.subcommands.contains { $0.configuration.commandName == "doctor" })
}
