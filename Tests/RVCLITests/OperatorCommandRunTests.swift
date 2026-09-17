import ArgumentParser
import Foundation
import Testing
import RVDomain
import RVHistory
import RVPolicy
import RVTheme
@testable import RVCLI

struct OperatorCommandRunTests {
    @Test func testAndExplain_emptyAndAllowAndDeny() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home) {
            var missing = try Test.parse([])
            await #expect(throws: (any Error).self) {
                try await missing.run()
            }
            await #expect(throws: ExitCode(0)) {
                try await Test.parse(["echo", "ok"]).run()
            }
            await #expect(throws: ExitCode(1)) {
                try await Test.parse(["git", "reset", "--hard"]).run()
            }
            await #expect(throws: ExitCode(0)) {
                try await Test.parse(["--explain", "--plain", "echo", "ok"]).run()
            }
            await #expect(throws: ExitCode(0)) {
                try await Explain.parse(["--json", "git", "reset", "--hard"]).run()
            }
            await #expect(throws: ExitCode(0)) {
                try await Explain.parse(["echo", "ok"]).run()
            }
        }
    }

    @Test func safety_missingHomeBadLevelShowAndSet() throws {
        try withCLIProcess(environment: [:]) {
            #expect(throws: ExitCode(1)) {
                try Safety.parse([]).run()
            }
        }
        let home = try isolatedHome()
        try withCLIProcess(home: home) {
            try Safety.parse([]).run()
            #expect(throws: ExitCode(1)) {
                try Safety.parse(["loud"]).run()
            }
            try Safety.parse(["strict"]).run()
            try Safety.parse(["normal"]).run()
        }
        try replacePathWithFile(RVPolicyPaths.configDirectory(home: home))
        try withCLIProcess(home: home) {
            #expect(throws: ExitCode(1)) {
                try Safety.parse(["strict"]).run()
            }
        }
    }

    @Test func blocks_missingHomeAndList() throws {
        try withCLIProcess(environment: [:]) {
            #expect(throws: ExitCode(1)) {
                try Blocks.parse([]).run()
            }
        }
        let home = try isolatedHome()
        try withCLIProcess(home: home) {
            try Blocks.parse([]).run()
            try Blocks.parse(["--json"]).run()
        }
        let now = Date()
        DenialLedger(configDirectory: RVPolicyPaths.configDirectory(home: home)).append(
            DenialLedgerRecord(
                timestamp: now,
                host: .hook(.claude),
                tool: .file(.read),
                ruleID: RuleID(pack: .coreSecrets, pattern: "env"),
                category: .secret(.environment),
                path: "/tmp/rv-oracle/.env"
            ),
            now: now
        )
        try withCLIProcess(home: home) {
            try Blocks.parse([]).run()
            try Blocks.parse(["--robot"]).run()
        }
    }

    @Test func policyShow_missingHomePrettyRobotAndInvalid() async throws {
        try await withCLIProcess(environment: [:]) {
            await #expect(throws: ExitCode(1)) {
                try await Policy.Show.parse([]).run()
            }
        }
        let home = try isolatedHome()
        try await withCLIProcess(home: home) {
            try await Policy.Show.parse([]).run()
            try await Policy.Show.parse(["--robot"]).run()
        }
        let store = TypedRuleStore(baseDirectory: RVPolicyPaths.configDirectory(home: home))
        try FileManager.default.createDirectory(
            at: store.machineFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "not-json".write(to: store.machineFileURL, atomically: true, encoding: .utf8)
        try await withCLIProcess(home: home) {
            await #expect(throws: ExitCode(1)) {
                try await Policy.Show.parse([]).run()
            }
        }
    }

    @Test func policyValidateExportApply_edges() throws {
        try withCLIProcess(environment: [:]) {
            #expect(throws: ExitCode(1)) {
                try Policy.Validate.parse([]).run()
            }
            #expect(throws: ExitCode(1)) {
                try Policy.Export.parse([]).run()
            }
            #expect(throws: ExitCode(1)) {
                try Policy.Apply.parse(["/tmp/missing-policy.toml"]).run()
            }
        }
        let home = try isolatedHome()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-policy-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let out = workspace.appendingPathComponent("machine.toml")
        try withCLIProcess(home: home, workspacePath: workspace.path) {
            try Policy.Validate.parse([]).run()
            let missingFile = workspace.appendingPathComponent("absent.toml")
            try Policy.Validate.parse([missingFile.path]).run()
            try Policy.Export.parse([]).run()
            try Policy.Export.parse(["--output", out.path]).run()
            #expect(FileManager.default.fileExists(atPath: out.path))
            try Policy.Apply.parse([out.path]).run()
            try Policy.Apply.parse([out.path, "--save"]).run()
            try Policy.Apply.parse([out.path, "--repo"]).run()
            try Policy.Apply.parse([out.path, "--save", "--repo"]).run()
            try Policy.Export.parse(["--repo"]).run()
        }
        try "not-toml".write(to: workspace.appendingPathComponent("bad.toml"), atomically: true, encoding: .utf8)
        try withCLIProcess(home: home, workspacePath: workspace.path) {
            #expect(throws: ExitCode(2)) {
                try Policy.Validate.parse([workspace.appendingPathComponent("bad.toml").path]).run()
            }
            #expect(throws: ExitCode(1)) {
                try Policy.Apply.parse([workspace.appendingPathComponent("bad.toml").path]).run()
            }
        }
        let machine = TypedRuleStore(baseDirectory: RVPolicyPaths.configDirectory(home: home)).machineFileURL
        try "not-json".write(to: machine, atomically: true, encoding: .utf8)
        try withCLIProcess(home: home, workspacePath: workspace.path) {
            #expect(throws: ExitCode(2)) {
                try Policy.Validate.parse([]).run()
            }
            #expect(throws: ExitCode(1)) {
                try Policy.Export.parse([]).run()
            }
            #expect(throws: ExitCode(1)) {
                try Policy.Apply.parse([out.path]).run()
            }
        }
        try FileManager.default.removeItem(at: machine)
        try withCLIProcess(home: home, workspacePath: workspace.path) {
            try Policy.Export.parse([]).run()
        }
        try replacePathWithDirectory(machine)
        try withCLIProcess(home: home, workspacePath: workspace.path) {
            #expect(throws: ExitCode(1)) {
                try Policy.Apply.parse([out.path, "--save"]).run()
            }
        }
        let repoFile = TypedRuleStore.repoFileURL(workspace: workspace)
        try replacePathWithDirectory(repoFile)
        try withCLIProcess(home: home, workspacePath: workspace.path) {
            #expect(throws: ExitCode(1)) {
                try Policy.Apply.parse([out.path, "--save", "--repo"]).run()
            }
        }
    }

    @Test func policyExport_writeFailure() throws {
        let home = try isolatedHome()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-policy-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }
        try withCLIProcess(home: home) {
            #expect(throws: ExitCode(1)) {
                try Policy.Export.parse(["--output", output.path]).run()
            }
        }
    }

    @Test func policyDraft_runEdges() async throws {
        try await withCLIProcess(environment: [:]) {
            await #expect(throws: ExitCode(1)) {
                try await PolicyDraftCommand.parse(["--english", "never allow force-push to main"]).run()
            }
        }
        let home = try isolatedHome()
        try await withCLIProcess(home: home) {
            await #expect(throws: ExitCode(1)) {
                try await PolicyDraftCommand.parse(["--english", "", "--save"]).run()
            }
            try await PolicyDraftCommand.parse([
                "--english", "never allow force-push to main",
            ]).run()
            try await PolicyDraftCommand.parse([
                "--english", "never allow force-push to main",
                "--json",
            ]).run()
            try await PolicyDraftCommand.parse([
                "--english", "never allow force-push to main",
                "--save",
            ]).run()
            try await PolicyDraftCommand.parse([
                "--english", "never allow force-push to main",
                "--save",
                "--repo",
            ]).run()
            await #expect(throws: ExitCode(1)) {
                try await PolicyDraftCommand.parse(["--english", "be careful in prod"]).run()
            }
        }
        try replacePathWithFile(RVPolicyPaths.configDirectory(home: home))
        try await withCLIProcess(home: home) {
            await #expect(throws: ExitCode(1)) {
                try await PolicyDraftCommand.parse([
                    "--english", "never allow force-push to main",
                    "--save",
                ]).run()
            }
        }
    }

    @Test func scanSessions_missingHomeAndErrors() async throws {
        try await withCLIProcess(environment: [:]) {
            await #expect(throws: ExitCode(1)) {
                try await ScanSessions.parse([]).run()
            }
        }
        let home = try isolatedHome()
        try await withCLIProcess(home: home) {
            await #expect(throws: ExitCode(0)) {
                try await ScanSessions.parse(["--json"]).run()
            }
            await #expect(throws: (any Error).self) {
                try await ScanSessions.parse(["--include-glob", "*.jsonl"]).run()
            }
            await #expect(throws: (any Error).self) {
                try await ScanSessions.parse(["--packs", "NOT"]).run()
            }
            let missing = "/tmp/rv-scan-missing-\(UUID().uuidString)"
            await #expect(throws: ExitCode(1)) {
                try await ScanSessions.parse([missing]).run()
            }
            await #expect(throws: ExitCode(1)) {
                try await ScanSessions.parse(["--packs", "zzz.missing"]).run()
            }
        }
        let notADirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-scan-file-\(UUID().uuidString)")
        try "not a session tree".write(to: notADirectory, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: notADirectory) }
        try await withCLIProcess(home: home) {
            await #expect(throws: ExitCode(1)) {
                try await ScanSessions.parse([notADirectory.path]).run()
            }
        }
        try installClaudeScanFixture(into: URL(fileURLWithPath: home.rawValue, isDirectory: true))
        try await withCLIProcess(home: home, environment: ["PATH": "/usr/bin:/bin"]) {
            await #expect(throws: ExitCode(0)) {
                try await ScanSessions.parse([
                    "--json", "--show-command", "--all-events", "--all", "--host", "claude",
                ]).run()
            }
            await #expect(throws: ExitCode(0)) {
                try await ScanSessions.parse(["--days", "400", "--json"]).run()
            }
            await #expect(throws: ExitCode(2)) {
                try await ScanSessions.parse(["--fail-on-findings", "--all", "--plain"]).run()
            }
        }
        try await withCLIProcess(
            home: home,
            environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm"],
            stdinIsTTY: true,
            stdoutIsTTY: true
        ) {
            await #expect(throws: ExitCode(0)) {
                try await ScanSessions.parse(["--all"]).run()
            }
        }
        let tree = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-scan-glob-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tree) }
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../RVScanTests/Fixtures/claude/projects/-tmp-rv-scan-fixture/ac001-reset-hard.jsonl")
        try FileManager.default.copyItem(at: fixture, to: tree.appendingPathComponent("notes.txt"))
        try await withCLIProcess(home: home) {
            await #expect(throws: ExitCode.self) {
                try await ScanSessions.parse([
                    "--include-glob", "*.txt", "--all", "--json", tree.path,
                ]).run()
            }
        }
    }

    @Test func doctorAndServiceStatus_run() async throws {
        try await withCLIProcess(environment: [:]) {
            await #expect(throws: ExitCode(1)) {
                try await Doctor.parse([]).run()
            }
        }
        let home = try isolatedHome()
        try await withCLIProcess(home: home) {
            do {
                try await Doctor.parse(["--plain"]).run()
            } catch is ExitCode {}
            do {
                try await Doctor.parse(["--json"]).run()
            } catch is ExitCode {}
            try await Status.parse([]).run()
            try await Status.parse(["--robot"]).run()
        }
        try await withCLIProcess(
            home: home,
            environment: ["TERM": "xterm"],
            stdinIsTTY: true,
            stdoutIsTTY: true
        ) {
            do {
                try await Doctor.parse([]).run()
            } catch is ExitCode {}
        }
    }

    @Test func setupAndUninstall_runIsolated() throws {
        try withCLIProcess(environment: [:]) {
            #expect(throws: ExitCode(1)) {
                try Setup.parse(["--robot"]).run()
            }
            #expect(throws: ExitCode(1)) {
                try Uninstall.parse(["--robot"]).run()
            }
        }
        let home = try isolatedHome()
        try withCLIProcess(home: home, environment: ["PATH": "/usr/bin:/bin"]) {
            #expect(throws: ExitCode.self) {
                try Setup.parse(["--robot"]).run()
            }
            #expect(throws: ExitCode.self) {
                try Uninstall.parse(["--robot"]).run()
            }
            #expect(throws: ExitCode.self) {
                try Setup.parse(["--force", "--plain"]).run()
            }
        }
        try withCLIProcess(
            home: home,
            environment: ["PATH": "/usr/bin:/bin", "RV_FROM_INSTALL": "1"],
            stdinIsTTY: true,
            stdoutIsTTY: true
        ) {
            #expect(throws: ExitCode.self) {
                try Setup.parse(["--plain", "--no-color"]).run()
            }
        }
    }

    @Test func setupEnvironment_liveUsesIsolatedHome() throws {
        let home = try isolatedHome()
        let env = try #require(
            SetupEnvironment.live(environment: ["HOME": home.rawValue, "PATH": "/usr/bin"])
        )
        #expect(env.home == home)
        #expect(env.touchSystemd == false)
        #expect(env.supervisor == .systemdUser)
        #expect(DoctorEnvironment.live(environment: [:]) == nil)
        let doctor = try #require(DoctorEnvironment.live(environment: ["HOME": home.rawValue]))
        #expect(doctor.home == home)
        try withCLIProcess(environment: [:]) {
            #expect(SetupFlow.live().run(SetupIntent(kind: .install)).exitCode == 1)
            #expect(SetupFlow.live().run(SetupIntent(kind: .uninstall)).exitCode == 1)
        }
    }

    @Test func helpDispatch_tryEmit() throws {
        try withCLIProcess(environment: ["CI": "1"], stdoutIsTTY: false) {
            #expect(HelpDispatch.tryEmit(arguments: ["--help"]))
            #expect(HelpDispatch.tryEmit(arguments: ["help"]))
            #expect(HelpDispatch.tryEmit(arguments: ["help", "help"]))
            #expect(HelpDispatch.tryEmit(arguments: ["help", "packs"]))
            #expect(HelpDispatch.tryEmit(arguments: ["test", "--help"]))
            #expect(HelpDispatch.tryEmit(arguments: ["explain", "--help"]))
            #expect(HelpDispatch.tryEmit(arguments: ["service", "--help"]))
            #expect(HelpDispatch.tryEmit(arguments: ["service", "status", "--help"]))
            #expect(HelpDispatch.tryEmit(arguments: ["hook", "--help"]))
            #expect(HelpDispatch.tryEmit(arguments: ["setup", "--force", "--help"]))
            #expect(HelpDispatch.tryEmit(arguments: ["uninstall", "--help"]))
            #expect(HelpDispatch.tryEmit(arguments: ["allow-once", "--help"]))
            #expect(HelpDispatch.tryEmit(arguments: ["scan", "--help"]))
            #expect(HelpDispatch.tryEmit(arguments: ["policy", "--help"]))
            #expect(HelpDispatch.tryEmit(arguments: ["allowlist", "--help"]))
            #expect(HelpDispatch.tryEmit(arguments: ["safety", "strict", "--help"]))
            #expect(HelpDispatch.tryEmit(arguments: ["blocks", "--json", "--help"]))
            #expect(HelpDispatch.tryEmit(arguments: ["test", "echo"]) == false)
        }
        try withCLIProcess(
            environment: ["TERM": "xterm"],
            stdinIsTTY: true,
            stdoutIsTTY: true
        ) {
            #expect(HelpDispatch.tryEmit(arguments: ["doctor", "--help"]))
        }
        #expect(HelpDispatch.tryEmit(arguments: ["--help"], stdoutIsTTY: false))
    }

    @Test func cliAppearance_liveResolver() throws {
        try withCLIProcess(environment: ["CI": "1"]) {
            #expect(CLIAppearance.resolve(json: false, robot: false, plain: false, noColor: false) == .robot)
        }
        try withCLIProcess(environment: [:], stdoutIsTTY: false) {
            _ = CLIAppearance.resolve(json: true, robot: false, plain: false, noColor: false)
            _ = CLIAppearance.resolve(json: false, robot: false, plain: true, noColor: true)
        }
    }

    @Test func cliProcess_mergesHomeIntoEnvironment() throws {
        let home = try isolatedHome()
        try withCLIProcess(home: home, environment: ["PATH": "/bin"]) {
            #expect(CLIProcess.home() == home)
            #expect(CLIProcess.environment()["HOME"] == home.rawValue)
            #expect(CLIProcess.environment()["PATH"] == "/bin")
            #expect(CLIProcess.workspacePath() == FileManager.default.currentDirectoryPath)
        }
        let merged = CLIProcess.Context(
            home: home,
            environment: ["RV_FROM_INSTALL": "1"],
            includeProcessEnvironment: true
        )
        #expect(merged.environment["HOME"] == home.rawValue)
        #expect(merged.environment["RV_FROM_INSTALL"] == "1")
        try withCLIProcess(environment: ["HOME": home.rawValue]) {
            #expect(CLIProcess.home() == home)
        }
        _ = CLIProcess.stdinIsTTY()
        _ = CLIProcess.stdoutIsTTY()
        _ = CLIProcess.stdoutFileDescriptor()
        _ = CLIProcess.workspacePath()
    }

    @Test func testExplain_missingHomeUsesEphemeralStore() async throws {
        try await withCLIProcess(environment: [:]) {
            await #expect(throws: ExitCode(0)) {
                try await Test.parse(["echo", "ok"]).run()
            }
        }
    }

    @Test func commandRun_nilCwdAndStoreOverload() async throws {
        let home = try isolatedHome()
        let store = AllowOnceStore.makeLive(home: home)
        let probe = ThemeProbeFactory.make(
            jsonFlag: false,
            robotFlag: true,
            plainFlag: false,
            noColorFlag: false,
            stdinIsTTY: false,
            stdoutIsTTY: false,
            environment: ["CI": "1"]
        )
        let evaluated = await CommandRun.evaluateCommand(
            "echo ok",
            cwd: Optional<WorkingDirectory>.none,
            store: store,
            home: home
        )
        #expect(evaluated.decision == .allow)
        let result = await CommandRun.run(
            kind: .test,
            command: "echo ok",
            probe: probe,
            requested: .robot,
            cwd: Optional<WorkingDirectory>.none,
            store: store,
            home: home
        )
        #expect(result.exitCode == 0)
        _ = RV()
        _ = ProcessSystemctl()
        _ = ProcessLaunchctl()
    }

    @Test func hookRun_injectedStdinDoesNotReadLiveHOME() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home) {
            var hook = try Hook.parse(["--host", "grok"])
            let outcome = await hook.run(
                stdin: #"{"hookEventName":"pre_tool_use","toolName":"run_terminal_command","toolInput":{"command":"echo ok"}}"#,
                client: ServiceClient(home: home)
            )
            #expect(outcome.exitCode == 0 || outcome.exitCode == 2)
        }
        let stdin = #"{"hookEventName":"pre_tool_use","toolName":"run_terminal_command","toolInput":{"command":"echo ok"}}"#
        try await withCLIProcess(home: home, stdinText: stdin) {
            var hook = try Hook.parse(["--host", "grok"])
            await #expect(throws: ExitCode.self) {
                try await hook.run()
            }
            for host in ["pi", "claude", "cursor", "opencode", "openclaw", "hermes", "codex"] {
                var named = try Hook.parse(["--host", host])
                await #expect(throws: ExitCode.self) {
                    try await named.run()
                }
            }
        }
        try await withCLIProcess(home: home) {
            try await Status.parse(["--json"]).run()
            try await Status.parse(["--robot"]).run()
        }
    }
}

private func installClaudeScanFixture(into homeURL: URL) throws {
    let base = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../RVScanTests/Fixtures", isDirectory: true)
        .standardizedFileURL
    let source = base.appendingPathComponent("claude/projects/-tmp-rv-scan-fixture/ac001-reset-hard.jsonl")
    let projects = homeURL.appendingPathComponent(
        ".claude/projects/-tmp-rv-scan-fixture",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        at: source,
        to: projects.appendingPathComponent("ac001-reset-hard.jsonl")
    )
}
