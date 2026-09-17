import ArgumentParser
import Foundation
import Testing
import RVDomain
import RVHooks
import RVIPC
import RVPolicy
import RVPresentation
import RVTheme
@testable import RVCLI

struct ResidualLinuxEdgesTests {
    @Test func serviceDiagnostics_remainingFallbackArms() async throws {
        let snapshot = DoctorSnapshotReply(
            serviceSemver: "1.0.0",
            state: .running,
            idleExitSeconds: 300,
            packsEnabled: [.coreGit],
            checks: [DoctorCheck(id: .packs, status: .ok, message: "ok")]
        )
        let valid = HelloAckView(
            protocolName: ProtocolVersion.name,
            serviceSemver: "1.0.0",
            status: .ok
        )

        let mismatched = ScriptedTransport(
            ack: valid,
            responseResult: .doctorSnapshot(snapshot),
            responseProtocolName: "rv.ipc.v0"
        )
        let mismatchedResult = try await isolatedClient(transport: mismatched).diagnostics()
        #expect(
            mismatchedResult == .local(
                .init(
                    cause: .requestFailed(.invalidResponse),
                    corePacksReady: true,
                    serviceSemver: "1.0.0"
                )
            )
        )

        let protocolError = ScriptedTransport(
            ack: valid,
            responseResult: .error(.protocolSkew(.protocolSkew))
        )
        #expect(
            try await isolatedClient(transport: protocolError).diagnostics()
                == .local(
                    .init(
                        cause: .skew(.protocolMismatch),
                        corePacksReady: true,
                        serviceSemver: "1.0.0"
                    )
                )
        )

        let serviceError = ScriptedTransport(
            ack: valid,
            responseResult: .error(.unknownMethod)
        )
        #expect(
            try await isolatedClient(transport: serviceError).diagnostics()
                == .local(
                    .init(
                        cause: .requestFailed(.service(.unknownMethod)),
                        corePacksReady: true,
                        serviceSemver: "1.0.0"
                    )
                )
        )

        let garbage = ScriptedTransport(ack: valid, sendReply: Data("[]".utf8))
        let garbageResult = try await isolatedClient(transport: garbage).diagnostics()
        guard case .local(let diagnostic) = garbageResult else {
            Issue.record("expected local diagnostic")
            return
        }
        #expect(diagnostic.cause == .requestFailed(.invalidResponse))

        let unexpectedHello = UnexpectedErrorTransport(stage: .hello)
        let helloResult = try await isolatedClient(transport: unexpectedHello).diagnostics()
        #expect(
            helloResult == .local(
                .init(cause: .requestFailed(.transport(.unexpected)), corePacksReady: true)
            )
        )

        let unexpectedSend = UnexpectedErrorTransport(stage: .send)
        let sendResult = try await isolatedClient(transport: unexpectedSend).diagnostics()
        guard case .local(let sendDiagnostic) = sendResult else {
            Issue.record("expected local send diagnostic")
            return
        }
        #expect(sendDiagnostic.cause == .requestFailed(.transport(.unexpected)))

        let major = ScriptedTransport(
            ack: HelloAckView(
                protocolName: ProtocolVersion.name,
                serviceSemver: "1.0.0",
                status: .skew(.majorVersion)
            )
        )
        #expect(
            try await isolatedClient(transport: major).diagnostics()
                == .local(
                    .init(
                        cause: .skew(.majorVersionMismatch),
                        corePacksReady: true,
                        serviceSemver: "1.0.0"
                    )
                )
        )

        let home = try isolatedHome()
        let store = AllowOnceStore.makeLive(home: home)
        let withStore = ServiceClient(transport: nil, store: store, home: home)
        let routed = await withStore.evaluate(command: ShellCommand(rawValue: "echo ok"))
        #expect(routed.result.decision == .allow)
    }

    @Test func serviceHealthAndStatus_coverLaunchAgentAndMessages() {
        #expect(ServiceDiagnosticFailure.unexpectedResponse.statusMessage == "unexpected response")
        #expect(ServiceDiagnosticFailure.service(.unknownMethod).statusMessage == "service error")
        #expect(ServiceSkewReason.corePacksUnavailable.statusMessage == "core packs unavailable")

        let snapshot = DoctorSnapshotReply(
            serviceSemver: "1.0.0",
            state: .down,
            idleExitSeconds: 1,
            packsEnabled: [],
            lastError: "boom",
            checks: []
        )
        let facts = ServiceHealth.Reachable(
            snapshot: snapshot,
            localCorePacksReady: true,
            launchAgent: .installed
        )
        let down = ServiceHealth.down(.xpc(facts))
        #expect(down.launchAgent == .installed)
        #expect(ServiceHealth.Source.xpc(facts).launchAgent == .installed)

        let failed = ServiceHealth.requestFailed(
            failure: .invalidResponse,
            local: .init(corePacksReady: true, serviceSemver: "1.0.0", launchAgent: .loaded)
        )
        #expect(failed.launchAgent == .loaded)

        let report = ServiceStatusReport(
            state: "down",
            fallback: "down",
            lastError: "invalid response"
        )
        #expect(report.plainLines.contains("lastError invalid response"))
        #expect(ServiceStatusCommand.plainText(report).contains("lastError"))
    }

    @Test func hookRun_writesNonemptyStderr() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("RVHooksTests/Fixtures/codex/deny-git-reset-hard.json")
        let stdin = try String(contentsOf: fixture, encoding: .utf8)
        let home = try isolatedHome()
        try await withCLIProcess(home: home, stdinText: stdin) {
            await #expect(throws: ExitCode.self) {
                try await Hook.parse(["--host", "codex"]).run()
            }
        }
    }

    @Test func helpDispatch_rejectsHelpExtraAndHookGarbage() {
        #expect(HelpDispatch.topic(arguments: ["help", "help", "extra"]) == .root)
        #expect(HelpDispatch.topic(arguments: ["hook", "nope", "--help"]) == nil)
        #expect(HelpDispatch.topic(arguments: ["help", "help"]) == .help)
    }

    @Test func setupFormat_forwardsSlotAccessors() {
        let report = SetupReport(
            grok: .wired,
            pi: .occupied,
            openCode: .pending,
            claude: .pending,
            openClaw: .occupied,
            hermes: .wired,
            codex: .wired,
            cursor: .occupied,
            wrote: [.grok]
        )
        #expect(report.grok == .wired)
        #expect(report.pi == .occupied)
        #expect(report.openCode == .pending)
        #expect(report.claude == .pending)
        #expect(report.openClaw == .occupied)
        #expect(report.hermes == .wired)
        #expect(report.codex == .wired)
        #expect(report.cursor == .occupied)
        #expect(report.wrote == [.grok])
    }

    @Test func mergeHelpers_remainingShapes() throws {
        #expect(ClaudeSettingsMerge.adapterPath(in: "python3 /abs/rv-guard.py") == "/abs/rv-guard.py")
        #expect(ClaudeSettingsMerge.adapterPath(in: "python3 rel/rv-guard.py") == nil)
        #expect(ClaudeSettingsMerge.adapterPath(in: "echo rv-guard.py") == nil)
        #expect(ClaudeSettingsMerge.bakedRvPath(in: "/abs/rv hook --host claude") == "/abs/rv")
        #expect(ClaudeSettingsMerge.bakedRvPath(in: "python3 /x hook --host claude") == nil)
        #expect(ClaudeSettingsMerge.isFingerprintedHook([:]) == false)
        #expect(ClaudeSettingsMerge.isStaleLegacyHook([:]) == false)

        let bashOnly = Data(
            """
            {
              "hooks": {
                "PreToolUse": [
                  {
                    "matcher": "Bash",
                    "hooks": [
                      {
                        "type": "command",
                        "command": "RV_BINARY=/tmp/rv python3 /tmp/.claude/hooks/rv-guard.py",
                        "timeout": 90
                      }
                    ]
                  }
                ]
              }
            }
            """.utf8
        )
        #expect(ClaudeSettingsMerge.inspectionState(of: bashOnly) == .outdated)

        let foreignGuard = Data(
            """
            {
              "hooks": {
                "PreToolUse": [
                  {
                    "matcher": "Bash",
                    "hooks": [
                      {
                        "type": "command",
                        "command": "python3 /opt/other/rv-guard.py",
                        "timeout": 10
                      }
                    ]
                  }
                ]
              }
            }
            """.utf8
        )
        #expect(ClaudeSettingsMerge.inspectionState(of: foreignGuard) == .occupied)

        let skipEntry = Data(
            """
            {
              "hooks": {
                "PreToolUse": [
                  { "matcher": "Bash" },
                  {
                    "matcher": "Bash",
                    "hooks": [
                      {
                        "type": "command",
                        "command": "python3 /tmp/.claude/hooks/rv-guard.py",
                        "timeout": 90
                      }
                    ]
                  }
                ]
              }
            }
            """.utf8
        )
        #expect(try ClaudeSettingsMerge.uninstall(existingData: skipEntry) != nil)

        #expect(CodexHooksMerge.isFingerprintedHook([:]) == false)
        let codexSkip = Data(
            """
            {
              "hooks": {
                "PreToolUse": [
                  { "matcher": "Bash" },
                  {
                    "matcher": "Bash",
                    "hooks": [
                      {
                        "type": "command",
                        "command": "python3 /tmp/.codex/hooks/rv-guard.py",
                        "timeout": 5
                      }
                    ]
                  }
                ]
              }
            }
            """.utf8
        )
        #expect(try CodexHooksMerge.uninstall(existingData: codexSkip) != nil)

        let cursorNoVersion = Data(
            """
            {
              "hooks": {
                "beforeShellExecution": [
                  { "command": "python3 /tmp/.cursor/hooks/rv-guard.py" }
                ]
              }
            }
            """.utf8
        )
        #expect(try CursorHooksMerge.uninstall(existingData: cursorNoVersion) == nil)

        let pluginPath = "/tmp/rv-guard-tui-ask"
        let seededList = try OpenCodeConfigMerge.merge(
            existingData: Data(#"{"plugin":["\#(pluginPath)"]}"#.utf8),
            pluginPath: pluginPath
        )
        let already = try OpenCodeConfigMerge.merge(
            existingData: seededList.data,
            pluginPath: pluginPath
        )
        #expect(already.wrote == false)

        let seededString = try OpenCodeConfigMerge.merge(
            existingData: Data(#"{"plugin":"\#(pluginPath)"}"#.utf8),
            pluginPath: pluginPath
        )
        let asString = try OpenCodeConfigMerge.merge(
            existingData: seededString.data,
            pluginPath: pluginPath
        )
        #expect(asString.wrote == false)

        let seededPair = try OpenCodeConfigMerge.merge(
            existingData: Data(#"{"plugin":[["\#(pluginPath)",{"enabled":true}]]}"#.utf8),
            pluginPath: pluginPath
        )
        let pair = try OpenCodeConfigMerge.merge(
            existingData: seededPair.data,
            pluginPath: pluginPath
        )
        #expect(pair.wrote == false)

        let other = try OpenCodeConfigMerge.merge(
            existingData: Data(#"{"plugin":["other"]}"#.utf8),
            pluginPath: pluginPath
        )
        #expect(other.wrote)
        let strippedOther = try OpenCodeConfigMerge.strip(
            existingData: other.data,
            pluginPath: pluginPath
        )
        #expect(strippedOther != nil)

        let onlyOurs = try OpenCodeConfigMerge.merge(existingData: nil, pluginPath: pluginPath)
        #expect(try OpenCodeConfigMerge.strip(existingData: onlyOurs.data, pluginPath: pluginPath) == nil)
        #expect(try OpenCodeConfigMerge.strip(existingData: nil, pluginPath: pluginPath) == nil)

        #expect(GrokHookInspect.hasFileToolDoor(in: Data("{}".utf8)) == false)
        #expect(
            GrokHookInspect.hasFileToolDoor(
                in: Data(#"{"hooks":{"PreToolUse":[{"matcher":"Bash"}]}}"#.utf8)
            ) == false
        )
    }

    @Test func environmentAndFileOps_edges() throws {
        #expect(SetupEnvironment.resolveRvd(nextTo: nil, home: "/tmp/rv-no-rvd-\(UUID().uuidString)") == nil)
        #expect(
            SetupEnvironment.resolveRvd(
                nextTo: "/tmp/missing-rv-bin/rv",
                home: "/tmp/rv-no-rvd-\(UUID().uuidString)"
            ) == nil
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-fileops-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("owned.txt").path
        let backup = path + ".bak"
        try "first".write(toFile: path, atomically: true, encoding: .utf8)
        try "old-bak".write(toFile: backup, atomically: true, encoding: .utf8)
        let files = FileOps(fileManager: .default)
        try files.backupAndClearOwnedPath(path)
        #expect(files.fileExists(path) == false)
        #expect(try String(contentsOfFile: backup, encoding: .utf8) == "first")
    }

    @Test func companionPresence_rejectsUnreadablePlist() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-companion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info = root.appendingPathComponent("rv.app/Contents/Info.plist")
        try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not-a-plist".write(to: info, atomically: true, encoding: .utf8)
        #expect(FilesystemCompanionPresence(searchRoots: [root]).presence() == .absent)

        let array = try PropertyListSerialization.data(fromPropertyList: ["dev.rv.app"], format: .xml, options: 0)
        try array.write(to: info)
        #expect(FilesystemCompanionPresence(searchRoots: [root]).presence() == .absent)

        let missingID = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleName": "rv"],
            format: .xml,
            options: 0
        )
        try missingID.write(to: info)
        #expect(FilesystemCompanionPresence(searchRoots: [root]).presence() == .absent)
    }

    @Test func hostInstallation_occupiedWhenClaudeSettingsUnreadable() throws {
        try withTempHome { _, paths, _ in
            let owned = paths.hostAdapter(for: .claude)
            try FileManager.default.createDirectory(
                atPath: owned.detectionDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                atPath: owned.destination,
                withIntermediateDirectories: true
            )
            let snapshot = try HostAdapterInstallation.inspect(
                paths: paths,
                pathEntries: [],
                fileManager: .default
            )
            #expect(snapshot.state(for: .claude) == .occupied)
            #expect(snapshot.installation(for: .claude).fileTools() == .notApplicable)
            #expect(HostAdapterInstallation.missing(owned).fileTools() == .notApplicable)
        }
    }

    @Test func scanNudge_emptyHostsIsFalse() throws {
        let home = try isolatedHome()
        let scanHome = try #require(ScanHome(validating: home.rawValue))
        #expect(
            scanSetupNudgeRecommended(
                hosts: [],
                home: scanHome,
                pathEntries: [],
                fileManager: .default
            ) == false
        )
    }

    @Test func setup_forceOccupiedClaudeWrites() throws {
        try withTempHome { home, layout, launchctl in
            try FileManager.default.createDirectory(
                atPath: layout.claudeDirectory,
                withIntermediateDirectories: true
            )
            try """
            {
              "hooks": {
                "PreToolUse": [
                  {
                    "matcher": "Bash",
                    "hooks": [
                      { "type": "command", "command": "python3 /opt/other/rv-guard.py", "timeout": 10 }
                    ]
                  }
                ]
              }
            }
            """.write(toFile: layout.claudeSettings, atomically: true, encoding: .utf8)
            let outcome = SetupRun.setup(env(home: home, launchctl: launchctl), force: true)
            #expect(outcome.exitCode == 0)
            #expect(outcome.stdout.contains("Skipped occupied claude hook.") == false)
            #expect(FileManager.default.fileExists(atPath: ClaudeSettingsMerge.adapterPath(settingsPath: layout.claudeSettings)))
        }
    }

    @Test func uninstall_systemdDisableAndKeepAliveRestore() throws {
        try withTempHome { home, layout, launchctl in
            let recording = RecordingSystemctl()
            let setupEnv = env(
                home: home,
                launchctl: launchctl,
                systemctl: recording,
                touchSystemd: true,
                supervisor: .systemdUser
            )
            #expect(SetupRun.setup(setupEnv).exitCode == 0)
            let failing = env(
                home: home,
                launchctl: launchctl,
                systemctl: FailingSystemctl(),
                touchSystemd: true,
                supervisor: .systemdUser
            )
            let outcome = SetupRun.uninstall(failing)
            #expect(outcome.exitCode == EX_UNAVAILABLE)
            #expect(outcome.stderr.contains("unable to disable systemd unit"))
        }

        try withTempHome { home, layout, launchctl in
            let systemd = env(
                home: home,
                launchctl: launchctl,
                touchSystemd: false,
                supervisor: .systemdUser
            )
            try SetupRun.restoreKeepAliveAfterCompanionUninstall(systemd)

            let launchd = env(home: home, launchctl: launchctl, touchLaunchd: false)
            try SetupRun.restoreKeepAliveAfterCompanionUninstall(launchd)
            #expect(FileManager.default.fileExists(atPath: layout.launchAgent) == false)

            #expect(SetupRun.setup(launchd).exitCode == 0)
            try SetupRun.restoreKeepAliveAfterCompanionUninstall(launchd)
            try expectLaunchAgentKeepAlive(layout.launchAgent, false)
        }
    }

    @Test func uninstall_ownedPathStillExistsWhenParentIsImmutable() throws {
        try withTempHome { home, layout, launchctl in
            let bin = URL(fileURLWithPath: layout.localRv).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try "rv".write(toFile: layout.localRv, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bin.path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
            }
            let outcome = SetupRun.uninstall(
                env(home: home, launchctl: launchctl, touchLaunchd: false)
            )
            #expect(outcome.stderr.contains("owned path still exists"))
            #expect(outcome.exitCode == EX_SOFTWARE)
        }
    }

    @Test func uninstall_cursorAndCodexHookEdges() throws {
        try withTempHome { home, layout, launchctl in
            try FileManager.default.createDirectory(
                atPath: layout.cursorDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                atPath: layout.codexDirectory,
                withIntermediateDirectories: true
            )
            let setupEnv = env(home: home, launchctl: launchctl, touchLaunchd: false)
            #expect(SetupRun.setup(setupEnv).exitCode == 0)

            try FileManager.default.removeItem(atPath: layout.cursorHooksJSON)
            try FileManager.default.createSymbolicLink(
                atPath: layout.cursorHooksJSON,
                withDestinationPath: "/tmp/rv-missing-cursor-hooks"
            )
            try FileManager.default.removeItem(atPath: layout.codexHooksJSON)
            try FileManager.default.createSymbolicLink(
                atPath: layout.codexHooksJSON,
                withDestinationPath: "/tmp/rv-missing-codex-hooks"
            )
            let outcome = SetupRun.uninstall(setupEnv)
            #expect(outcome.exitCode == 0)
        }
    }

    @Test func uninstall_claudeAdapterSymlinkAndWriteFail() throws {
        try withTempHome { home, layout, launchctl in
            try FileManager.default.createDirectory(
                atPath: layout.claudeDirectory,
                withIntermediateDirectories: true
            )
            let setupEnv = env(home: home, launchctl: launchctl, touchLaunchd: false)
            #expect(SetupRun.setup(setupEnv).exitCode == 0)
            let adapter = ClaudeSettingsMerge.adapterPath(settingsPath: layout.claudeSettings)
            try FileManager.default.removeItem(atPath: adapter)
            try FileManager.default.createSymbolicLink(
                atPath: adapter,
                withDestinationPath: "/tmp/rv-missing-claude-adapter"
            )
            let outcome = SetupRun.uninstall(setupEnv)
            #expect(outcome.exitCode == 0)
        }

        try withTempHome { home, layout, launchctl in
            try FileManager.default.createDirectory(
                atPath: layout.claudeDirectory,
                withIntermediateDirectories: true
            )
            let setupEnv = env(home: home, launchctl: launchctl, touchLaunchd: false)
            #expect(SetupRun.setup(setupEnv).exitCode == 0)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o555],
                ofItemAtPath: layout.claudeDirectory
            )
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: layout.claudeDirectory
                )
            }
            let outcome = SetupRun.uninstall(setupEnv)
            #expect(outcome.stderr.contains("unable to write claude hook") || outcome.exitCode == 0)
        }
    }

    @Test func hostWrites_symlinkAndIdempotentAndOpenCodeStrip() throws {
        try withTempHome { home, layout, launchctl in
            try FileManager.default.createDirectory(
                atPath: layout.codexDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                atPath: layout.cursorDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                atPath: layout.openCodeDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                atPath: layout.claudeDirectory,
                withIntermediateDirectories: true
            )
            let files = FileOps(fileManager: .default)
            let setupEnv = env(home: home, launchctl: launchctl, touchLaunchd: false)

            try FileManager.default.createDirectory(
                atPath: (layout.codexHooksJSON as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                atPath: layout.codexHooksJSON,
                withDestinationPath: "/tmp/rv-codex-symlink"
            )
            #expect(throws: SetupError.hostHookWriteFailed(.codex)) {
                _ = try SetupRun.writeHost(
                    .codex,
                    existingData: nil,
                    env: setupEnv,
                    layout: layout,
                    files: files
                )
            }
            try FileManager.default.removeItem(atPath: layout.codexHooksJSON)

            #expect(
                try SetupRun.writeHost(
                    .codex,
                    existingData: nil,
                    env: setupEnv,
                    layout: layout,
                    files: files
                )
            )
            #expect(
                try SetupRun.writeHost(
                    .codex,
                    existingData: files.readData(layout.codexHook),
                    env: setupEnv,
                    layout: layout,
                    files: files
                ) == false
            )

            try FileManager.default.createDirectory(
                atPath: (layout.cursorHooksJSON as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                atPath: layout.cursorHooksJSON,
                withDestinationPath: "/tmp/rv-cursor-symlink"
            )
            #expect(throws: SetupError.hostHookWriteFailed(.cursor)) {
                _ = try SetupRun.writeHost(
                    .cursor,
                    existingData: nil,
                    env: setupEnv,
                    layout: layout,
                    files: files
                )
            }
            try FileManager.default.removeItem(atPath: layout.cursorHooksJSON)
            #expect(
                try SetupRun.writeHost(
                    .cursor,
                    existingData: nil,
                    env: setupEnv,
                    layout: layout,
                    files: files
                )
            )
            #expect(
                try SetupRun.writeHost(
                    .cursor,
                    existingData: files.readData(layout.cursorHook),
                    env: setupEnv,
                    layout: layout,
                    files: files
                ) == false
            )

            try FileManager.default.createSymbolicLink(
                atPath: layout.claudeSettings,
                withDestinationPath: "/tmp/rv-claude-settings"
            )
            #expect(
                try SetupRun.writeClaudeSettings(
                    path: layout.claudeSettings,
                    rvPath: setupEnv.rvPath,
                    existingData: nil,
                    force: true,
                    files: files
                ) == false
            )
            try FileManager.default.removeItem(atPath: layout.claudeSettings)

            let adapter = ClaudeSettingsMerge.adapterPath(settingsPath: layout.claudeSettings)
            try FileManager.default.createDirectory(
                atPath: (adapter as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                atPath: adapter,
                withDestinationPath: "/tmp/rv-claude-adapter"
            )
            #expect(throws: SetupError.hostHookWriteFailed(.claude)) {
                _ = try SetupRun.writeClaudeSettings(
                    path: layout.claudeSettings,
                    rvPath: setupEnv.rvPath,
                    existingData: nil,
                    force: true,
                    files: files
                )
            }
            try FileManager.default.removeItem(atPath: adapter)

            try SetupRun.stripOpenCodeAskPlugin(layout: layout, files: files)
            try "[]".write(toFile: layout.openCodeConfig, atomically: true, encoding: .utf8)
            try SetupRun.stripOpenCodeAskPlugin(layout: layout, files: files)

            let merged = try OpenCodeConfigMerge.merge(
                existingData: nil,
                pluginPath: layout.openCodeTuiAskPackage
            )
            try merged.data.write(to: URL(fileURLWithPath: layout.openCodeConfig))
            try SetupRun.stripOpenCodeAskPlugin(layout: layout, files: files)
            #expect(files.fileExists(layout.openCodeConfig) == false)

            let leftover = try OpenCodeConfigMerge.merge(
                existingData: Data(#"{"plugin":["keep-me"]}"#.utf8),
                pluginPath: layout.openCodeTuiAskPackage
            )
            try leftover.data.write(to: URL(fileURLWithPath: layout.openCodeConfig))
            try SetupRun.stripOpenCodeAskPlugin(layout: layout, files: files)
            #expect(files.fileExists(layout.openCodeConfig))

            try FileManager.default.removeItem(atPath: layout.openCodeConfig)
            try FileManager.default.createDirectory(
                atPath: layout.openCodeConfig,
                withIntermediateDirectories: true
            )
            let blocked = try OpenCodeConfigMerge.merge(
                existingData: Data(#"{"plugin":["keep-me","\#(layout.openCodeTuiAskPackage)"]}"#.utf8),
                pluginPath: layout.openCodeTuiAskPackage
            )
            // Directory at the config path makes writeData fail after a successful strip.
            try? FileManager.default.removeItem(atPath: layout.openCodeConfig)
            try blocked.data.write(to: URL(fileURLWithPath: layout.openCodeConfig))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o555],
                ofItemAtPath: layout.openCodeDirectory
            )
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: layout.openCodeDirectory
                )
            }
            #expect(throws: SetupError.hostHookWriteFailed(.opencode)) {
                try SetupRun.stripOpenCodeAskPlugin(layout: layout, files: files)
            }
        }
    }

    @Test func systemdUnitWriteFailed_whenParentIsAFile() throws {
        try withTempHome { home, layout, launchctl in
            let parent = URL(fileURLWithPath: layout.systemdUserUnit).deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parent.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: parent)
            let files = FileOps(fileManager: .default)
            #expect(throws: SetupError.systemdUnitWriteFailed) {
                try SetupRun.writeSystemdUserUnit(
                    env: env(home: home, launchctl: launchctl, supervisor: .systemdUser),
                    layout: layout,
                    files: files
                )
            }
        }
    }

    @Test func policyDraft_saveForbiddenHardStop() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home) {
            await #expect(throws: ExitCode(1)) {
                try await PolicyDraftCommand.parse([
                    "--english", "always allow force-push to main",
                    "--save",
                ]).run()
            }
        }
    }

    @Test func leftoverLinuxEdges_healthMergeAndWrites() throws {
        let snapshot = DoctorSnapshotReply(
            serviceSemver: "1.0.0",
            state: .running,
            idleExitSeconds: 1,
            packsEnabled: [.coreGit],
            checks: [DoctorCheck(id: .packs, status: .ok, message: "ok")]
        )
        let reachable = ServiceHealth.inspect(
            .xpc(snapshot: snapshot, localCorePacksReady: true),
            launchAgentInstalled: true,
            launchAgentLoaded: true
        )
        #expect(reachable.launchAgent == .loaded)

        let home = try isolatedHome()
        _ = SetupEnvironment(
            home: home,
            pathEntries: [],
            rvPath: "/tmp/rv",
            rvdPath: "/tmp/rvd",
            fileManager: .default,
            launchctl: RecordingLaunchctl(),
            systemctl: SilentSystemctl(),
            touchLaunchd: false,
            touchSystemd: false,
            supervisor: .systemdUser,
            installAnalytics: SilentInstallAnalytics()
        )

        let unknownPlugin = try OpenCodeConfigMerge.merge(
            existingData: Data(#"{"plugin":[1]}"#.utf8),
            pluginPath: "/tmp/rv-ask"
        )
        #expect(unknownPlugin.wrote)

        try withTempHome { homeURL, layout, launchctl in
            try FileManager.default.createDirectory(
                atPath: layout.openCodeDirectory,
                withIntermediateDirectories: true
            )
            try "[]".write(toFile: layout.openCodeConfig, atomically: true, encoding: .utf8)
            let outcome = SetupRun.setup(
                env(home: homeURL, launchctl: launchctl, touchLaunchd: false)
            )
            #expect(outcome.exitCode == 0)

            try FileManager.default.createDirectory(
                atPath: layout.codexDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                atPath: layout.cursorDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                atPath: layout.claudeDirectory,
                withIntermediateDirectories: true
            )
            try "[]".write(toFile: layout.codexHooksJSON, atomically: true, encoding: .utf8)
            try "[]".write(toFile: layout.cursorHooksJSON, atomically: true, encoding: .utf8)
            let files = FileOps(fileManager: .default)
            let setupEnv = env(home: homeURL, launchctl: launchctl, touchLaunchd: false)
            #expect(throws: SetupError.hostHookWriteFailed(.codex)) {
                _ = try SetupRun.writeHost(
                    .codex,
                    existingData: nil,
                    env: setupEnv,
                    layout: layout,
                    files: files
                )
            }
            #expect(throws: SetupError.hostHookWriteFailed(.cursor)) {
                _ = try SetupRun.writeHost(
                    .cursor,
                    existingData: nil,
                    env: setupEnv,
                    layout: layout,
                    files: files
                )
            }

            #expect(throws: SetupError.hostHookWriteFailed(.claude)) {
                _ = try SetupRun.writeClaudeSettings(
                    path: layout.claudeSettings,
                    rvPath: setupEnv.rvPath,
                    existingData: Data("[]".utf8),
                    force: true,
                    files: files
                )
            }

            #expect(
                try SetupRun.writeClaudeSettings(
                    path: layout.claudeSettings,
                    rvPath: setupEnv.rvPath,
                    existingData: nil,
                    force: true,
                    files: files
                )
            )
            #expect(
                try SetupRun.writeClaudeSettings(
                    path: layout.claudeSettings,
                    rvPath: setupEnv.rvPath,
                    existingData: files.readData(layout.claudeSettings),
                    force: true,
                    files: files
                ) == false
            )

            try FileManager.default.removeItem(atPath: layout.claudeSettings)
            try FileManager.default.createDirectory(
                atPath: layout.claudeSettings,
                withIntermediateDirectories: true
            )
            #expect(throws: SetupError.hostHookWriteFailed(.claude)) {
                _ = try SetupRun.writeClaudeSettings(
                    path: layout.claudeSettings,
                    rvPath: setupEnv.rvPath,
                    existingData: nil,
                    force: true,
                    files: files
                )
            }
        }
    }

    @Test func uninstall_cursorAndCodexFingerprintOnlyRemovesFile() throws {
        try withTempHome { home, layout, launchctl in
            try FileManager.default.createDirectory(
                atPath: layout.cursorDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                atPath: layout.codexDirectory,
                withIntermediateDirectories: true
            )
            let setupEnv = env(home: home, launchctl: launchctl, touchLaunchd: false)
            #expect(SetupRun.setup(setupEnv).exitCode == 0)
            try """
            {"hooks":{"beforeShellExecution":[{"command":"python3 \(layout.cursorHook)"}]}}
            """.write(toFile: layout.cursorHooksJSON, atomically: true, encoding: .utf8)
            try """
            {"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"python3 \(layout.codexHook)","timeout":5}]}]}}
            """.write(toFile: layout.codexHooksJSON, atomically: true, encoding: .utf8)
            let outcome = SetupRun.uninstall(setupEnv)
            #expect(outcome.exitCode == 0)
        }
    }

    @Test func doctorRun_prettyAndRobotOnIsolatedHome() throws {
        let home = try isolatedHome()
        let environment = DoctorEnvironment(
            home: home,
            pathEntries: [],
            fileManager: .default,
            launchAgentLoaded: false
        )
        let pretty = DoctorRun.run(
            environment: environment,
            diagnostics: .local(.init(cause: .down, corePacksReady: true)),
            appearance: .pretty(colorOffPalette)
        )
        #expect(pretty.stderr.isEmpty)
        let robot = DoctorRun.run(
            environment: environment,
            diagnostics: .local(.init(cause: .down, corePacksReady: true)),
            appearance: .robot
        )
        #expect(robot.stdout.isEmpty == false)
    }
}

private enum UnexpectedTransportStage {
    case hello
    case send
}

private struct UnexpectedErrorTransport: ServiceTransport {
    var stage: UnexpectedTransportStage

    func hello(clientSemver _: String) async throws -> HelloAckView {
        if stage == .hello {
            throw NSError(domain: "rv.cli.coverage", code: 1)
        }
        return HelloAckView(
            protocolName: ProtocolVersion.name,
            serviceSemver: "1.0.0",
            status: .ok
        )
    }

    func send(_: Data) async throws -> Data {
        throw NSError(domain: "rv.cli.coverage", code: 2)
    }

    func invalidate() {}
}
