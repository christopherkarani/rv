import ArgumentParser
import Foundation
import Testing
import RVDomain
import RVIPC
import RVPolicy
import RVTheme
@testable import RVCLI

struct ResidualLinuxCoverageTests {
    @Test func commandRun_remainingOverloads() async throws {
        let home = try isolatedHome()
        let store = AllowOnceStore.makeLive(home: home)
        let directory = try isolatedAllowOnceDirectory()
        let probe = ThemeProbeFactory.make(
            jsonFlag: false,
            robotFlag: false,
            plainFlag: true,
            noColorFlag: true,
            stdinIsTTY: true,
            stdoutIsTTY: true,
            environment: ["TERM": "xterm"]
        )
        let viaStringStore = await CommandRun.evaluateCommand(
            "echo ok",
            cwd: "/tmp/ws",
            store: store,
            home: home
        )
        #expect(viaStringStore.decision == .allow)
        let viaWDDirectory = await CommandRun.evaluateCommand(
            "echo ok",
            cwd: wd("/tmp/ws"),
            allowOnceDirectory: directory,
            home: home
        )
        #expect(viaWDDirectory.decision == .allow)
        let runViaWDDirectory = try await CommandRun.run(
            kind: .test,
            command: "echo ok",
            probe: probe,
            requested: .automatic,
            cwd: wd("/tmp/ws"),
            allowOnceDirectory: directory,
            home: home
        )
        #expect(runViaWDDirectory.exitCode == 0)
    }

    @Test func policyDraft_predicateTextAndRobotRefuse() async throws {
        #expect(predicateText(.gitPush(force: .any, branch: nil)) == "gitPush force=- branch=-")
        #expect(predicateText(.gitDiscardWorktree(pathspec: nil)) == "gitDiscardWorktree pathspec=-")
        #expect(predicateText(.gitReset(mode: nil)) == "gitReset mode=-")
        #expect(predicateText(.gitClean(force: nil, directories: nil)) == "gitClean force=- directories=-")
        #expect(
            predicateText(.filesystemDelete(recursive: nil, force: nil))
                == "filesystemDelete recursive=- force=-"
        )
        #expect(predicateText(.filesystemMove) == "filesystemMove")
        let home = try isolatedHome()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-draft-pred-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let refused = try await PolicyDraftRun.execute(
            english: "git status",
            save: false,
            robot: true,
            home: home,
            workspace: workspace,
            compiler: FakeEnglishCompiler()
        )
        #expect(refused.outcome == .refuse(.unsupportedPredicate))
        #expect(refused.text.contains("unsupportedPredicate") || refused.text.contains("refuse"))
    }

    @Test func policyDocumentRun_unreadablePath() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-policy-dir-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: PolicyDocumentError.invalidFile) {
            _ = try PolicyDocumentRun.load(directory)
        }
    }

    @Test func scanRun_includeGlobRequiresPathAndUnlistable() throws {
        let home = try isolatedHome()
        let scanHome = try #require(ScanHome(validating: home.rawValue))
        #expect(throws: ScanRun.Error.includeGlobRequiresPath) {
            _ = try ScanRun.execute(
                .fixture(home: scanHome, includeGlobs: ["*.jsonl"])
            )
        }
        #expect(
            scanSetupNudgeRecommended(
                hosts: [.claude],
                home: scanHome,
                pathEntries: [],
                fileManager: .default
            )
        )
    }

    @Test func helpDispatch_formatOnlyServiceAndBrokenHookHost() {
        #expect(HelpDispatch.topic(arguments: ["service", "--json", "--help"]) == .service)
        #expect(HelpDispatch.topic(arguments: ["hook", "--host", "--help"]) == nil)
        try? withCLIProcess(environment: ["CI": "1"], stdoutIsTTY: false) {
            #expect(HelpDispatch.tryEmit(arguments: ["service", "--robot", "--help"]))
        }
    }

    @Test func companionPresence_linuxFilesystemProbe() throws {
        #expect(CompanionPresence.installed.keepAlive)
        #expect(CompanionPresence.absent.keepAlive == false)
        #expect(FixedCompanionPresence(value: .absent).presence() == .absent)
        let home = try isolatedHome()
        let homeURL = URL(fileURLWithPath: home.rawValue, isDirectory: true)
        let applications = homeURL.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let fromHome = FilesystemCompanionPresence(home: home.rawValue)
        #expect(fromHome.presence() == .absent)
        #expect(FilesystemCompanionPresence.isCompanionBundleId("dev.rv.app"))
        #expect(FilesystemCompanionPresence.isCompanionBundleId("dev.rv.") == false)
        #expect(FilesystemCompanionPresence.isCompanionBundleId("dev.rv.evaluate") == false)
        #expect(FilesystemCompanionPresence.isCompanionBundleId("dev.rv.evaluate.foo") == false)
        #expect(FilesystemCompanionPresence.isCompanionBundleId("com.example.rv") == false)

        try plantCompanionApp(inApplicationsRoot: applications, bundleId: "dev.rv.app")
        let installed = FilesystemCompanionPresence(searchRoots: [applications])
        #expect(installed.presence() == .installed)

        try FileManager.default.removeItem(at: applications.appendingPathComponent("rv.app"))
        try plantCompanionApp(inApplicationsRoot: applications, bundleId: "dev.rv.evaluate")
        #expect(FilesystemCompanionPresence(searchRoots: [applications]).presence() == .absent)

        try FileManager.default.removeItem(at: applications.appendingPathComponent("rv.app"))
        try "not a bundle".write(
            to: applications.appendingPathComponent("rv.app"),
            atomically: true,
            encoding: .utf8
        )
        #expect(FilesystemCompanionPresence(searchRoots: [applications]).presence() == .absent)
    }

    @Test func helloAckView_andDefaultTransportSendTimeout() async throws {
        let ack = HelloAck(status: .ok)
        let view = HelloAckView(ack)
        #expect(view.protocolName == ack.protocolName)
        #expect(view.serviceSemver == ack.serviceSemver)
        #expect(view.status == .ok)
        let transport = EchoServiceTransport()
        let echoed = try await transport.send(Data("ping".utf8), timeoutMs: 5)
        #expect(String(data: echoed, encoding: .utf8) == "ping")
        _ = ServiceClient(transport: nil, home: nil)
    }

    @Test func hookMergeHelpers_andUnreadable() throws {
        #expect(CursorHooksMerge.adapterPath(in: "echo rv-guard.py") == nil)
        #expect(CursorHooksMerge.adapterPath(in: "python3 /tmp/rv-guard.py") == "/tmp/rv-guard.py")
        #expect(CursorHooksMerge.adapterPath(in: "python3 relative/rv-guard.py") == nil)
        #expect(
            CursorHooksMerge.matchesCurrentHook(
                [
                    "command": CursorHooksMerge.hookCommand(adapterPath: "/tmp/rv-guard.py"),
                    "timeout": 5,
                    "failClosed": true,
                ],
                adapterPath: "/tmp/rv-guard.py"
            )
        )
        #expect(
            CursorHooksMerge.matchesCurrentHook(["command": "other"], adapterPath: "/tmp/rv-guard.py")
                == false
        )
        #expect(CursorHooksMerge.isFingerprintedHook([:]) == false)
        #expect(throws: CursorHooksMergeError.unreadable) {
            _ = try CursorHooksMerge.merge(existingData: Data("[]".utf8), adapterPath: "/tmp/rv-guard.py")
        }

        #expect(CodexHooksMerge.adapterPath(in: "python3 /tmp/rv-guard.py") == "/tmp/rv-guard.py")
        #expect(
            CodexHooksMerge.matchesCurrentHook(
                [
                    "type": CodexHooksMerge.hookType,
                    "command": CodexHooksMerge.hookCommand(adapterPath: "/tmp/rv-guard.py"),
                    "timeout": CodexHooksMerge.timeout,
                    "statusMessage": CodexHooksMerge.statusMessage,
                ],
                adapterPath: "/tmp/rv-guard.py"
            )
        )
        #expect(
            CodexHooksMerge.matchesCurrentHook(
                [
                    "type": CodexHooksMerge.hookType,
                    "command": CodexHooksMerge.hookCommand(adapterPath: "/tmp/rv-guard.py"),
                    "timeout": CodexHooksMerge.timeout,
                ],
                adapterPath: "/tmp/rv-guard.py"
            ) == false
        )
        #expect(CodexHooksMerge.matchesCurrentHook([:], adapterPath: "/tmp/x") == false)
        #expect(throws: CodexHooksMergeError.unreadable) {
            _ = try CodexHooksMerge.merge(existingData: Data("[]".utf8), adapterPath: "/tmp/rv-guard.py")
        }

        #expect(throws: OpenCodeConfigMergeError.invalidJSON) {
            _ = try OpenCodeConfigMerge.merge(existingData: Data("[]".utf8), pluginPath: "/tmp/plugin")
        }
        #expect(throws: ClaudeSettingsMergeError.unreadable) {
            _ = try ClaudeSettingsMerge.merge(
                existingData: Data("[]".utf8),
                rvPath: "/tmp/rv",
                adapterPath: "/tmp/adapter.py",
                force: true
            )
        }
    }

    @Test func setupEnvironment_prefersLocalRvdAndHookRunWritesStderr() async throws {
        let home = try isolatedHome()
        let rvd = URL(fileURLWithPath: home.rawValue)
            .appendingPathComponent(".local/bin/rvd", isDirectory: false)
        try writeExecutableScript(at: rvd, source: "#!/bin/sh\nexit 0\n")
        #expect(SetupEnvironment.resolveRvd(nextTo: nil, home: home.rawValue) == rvd.path)
        #expect(SetupEnvironment.resolveRvd(nextTo: "/tmp/missing-rv", home: home.rawValue) == rvd.path)
        let siblingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sibling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: siblingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: siblingDir) }
        let siblingRvd = siblingDir.appendingPathComponent("rvd")
        try writeExecutableScript(at: siblingRvd, source: "#!/bin/sh\nexit 0\n")
        #expect(
            SetupEnvironment.resolveRvd(
                nextTo: siblingDir.appendingPathComponent("rv").path,
                home: home.rawValue
            ) == siblingRvd.path
        )
        try await withCLIProcess(home: home, stdinText: "not-json") {
            await #expect(throws: ExitCode.self) {
                try await Hook.parse(["--host", "grok"]).run()
            }
        }
    }

    @Test func allowOnceCLI_emptyCommandAndHomeHelpers() async throws {
        let home = try isolatedHome()
        #expect(AllowOnceCLI.home(from: [:]) == nil)
        #expect(AllowlistCLI.home(from: ["HOME": home.rawValue]) == home)
        let store = AllowOnceCLI.store(home: home)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        await #expect(throws: AllowOnceError.emptyCommand) {
            _ = try await AllowOnceCLI.mint(
                command: ShellCommand(rawValue: "   "),
                cwd: wd("/tmp/a"),
                tty: tty,
                robot: false,
                store: store,
                now: Date()
            )
        }
    }
}

private struct EchoServiceTransport: ServiceTransport {
    func hello(clientSemver _: String) async throws -> HelloAckView {
        HelloAckView(protocolName: ProtocolVersion.name, serviceSemver: ProtocolVersion.serviceSemver, status: .ok)
    }

    func send(_ body: Data) async throws -> Data { body }

    func invalidate() {}
}
