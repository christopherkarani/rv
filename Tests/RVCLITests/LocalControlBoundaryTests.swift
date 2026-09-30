import ArgumentParser
import Foundation
import Testing
import RVDomain
import RVHooks
import RVIPC
import RVPolicy
@testable import RVCLI

struct LocalControlBoundaryTests {
    @Test func missingServiceDeniesEveryHostWithoutEvaluatingInput() async throws {
        let client = try isolatedClient(transport: nil)
        for host in HookHost.allCases {
            let wire = await client.hookEvaluate(host: host, stdin: "{}")
            #expect(wire == LocalControlBoundary.deniedHook(host: host))
            #expect(!wire.stdout.isEmpty)
            if host == .codex {
                #expect(wire.exitCode == 2)
                #expect(!wire.stderr.isEmpty)
            }
        }
    }

    @Test func protocolFailureDeniesWithoutLocalHookAuthority() async throws {
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: ProtocolVersion.name, serviceSemver: "1.0.0", status: .ok),
            responseResult: .error(.protocolSkew(.protocolSkew))
        )
        let client = try isolatedClient(transport: transport)
        let wire = await client.hookEvaluate(host: .grok, stdin: "{}")
        #expect(wire == LocalControlBoundary.deniedHook(host: .grok))
        #expect(transport.invalidationCount == 1)
    }

    @Test func diagnosticFallbackCannotHonorOrConsumeExistingGrant() async throws {
        let directory = try isolatedAllowOnceDirectory()
        let client = try isolatedClient(transport: nil, allowOnceDirectory: directory)
        let store = AllowOnceStore(baseDirectory: directory)
        try await store.insertGranted(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: Date())
        let result = await client.evaluateResult(command: ShellCommand(rawValue: "git reset --hard"), cwd: wd("/tmp/ws"))
        guard case .deny = result.decision else {
            Issue.record("diagnostic fallback must not honor a grant")
            return
        }
        let rows = await store.list(now: Date())
        #expect(!rows.isEmpty)
    }

    @Test func agentCannotPlantHostAskGrant() async throws {
        let directory = try isolatedAllowOnceDirectory()
        let client = try isolatedClient(transport: nil, allowOnceDirectory: directory)
        let result = await client.spendHostAsk(command: ShellCommand(rawValue: "echo harmless"), cwd: wd("/tmp/ws"))
        guard case .deny = result.decision else {
            Issue.record("owner authorization is mandatory even for an otherwise allowed action")
            return
        }
        let rows = await AllowOnceStore(baseDirectory: directory).list(now: Date())
        #expect(rows.isEmpty)
    }

    @Test func ttyCannotAuthorizeDirectGrantWrites() async throws {
        let directory = try isolatedAllowOnceDirectory()
        let store = AllowOnceStore(baseDirectory: directory)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        await #expect(throws: ValidationError.self) {
            _ = try await AllowOnceCLI.mint(command: ShellCommand(rawValue: "echo harmless"), cwd: wd("/tmp/ws"), tty: tty, robot: false, store: store, now: Date())
        }
        await #expect(throws: ValidationError.self) {
            _ = try await AllowOnceCLI.redeem(code: "abcdef", tty: tty, robot: false, store: store, now: Date())
        }
        let rows = await store.list(now: Date())
        #expect(rows.isEmpty)
        #expect(throws: ValidationError.self) { try WorkspaceCommandRun.abandon("/tmp/ws") }
    }
    @Test func permanentAllowlistMutationsRequireOwnerAuthorization() async throws {
        var add = try AllowlistAdd.parse(["core.git:reset-hard", "--reason", "operator exception"])
        var exact = try AllowlistAddCommand.parse(["echo harmless", "--reason", "operator exception"])
        var remove = try AllowlistRemove.parse(["core.git:reset-hard"])
        await #expect(throws: ValidationError.self) { try await add.run() }
        await #expect(throws: ValidationError.self) { try await exact.run() }
        await #expect(throws: ValidationError.self) { try await remove.run() }
    }

    @Test func safetyMutationRequiresOwnerAuthorization() throws {
        let home = try isolatedHome()
        #expect(throws: ValidationError.self) { try SafetyRun.set(.normal, home: home) }
        #expect(throws: ValidationError.self) { try SafetyRun.set(.strict, home: home) }
    }

    @Test func setupAndUninstallRequireOwnerBeforeMutation() throws {
        var setup = try Setup.parse(["--force"])
        var uninstall = try Uninstall.parse([])
        #expect(throws: ValidationError.self) { try setup.run() }
        #expect(throws: ValidationError.self) { try uninstall.run() }
        try withTempHome { root, layout, launchctl in
            let environment = env(home: root, launchctl: launchctl)
            let before = try FileManager.default.contentsOfDirectory(atPath: root.path)
            let installed = SetupRun.setup(environment, force: true)
            let removed = SetupRun.uninstall(environment)
            #expect(installed.exitCode == 69)
            #expect(removed.exitCode == 69)
            #expect(installed.stderr.contains(LocalControlBoundary.reason))
            #expect(removed.stderr.contains(LocalControlBoundary.reason))
            #expect(launchctl.bootstraps.isEmpty)
            #expect(launchctl.bootouts.isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == before)
            #expect(!FileManager.default.fileExists(atPath: layout.launchAgent))
        }
    }

}
