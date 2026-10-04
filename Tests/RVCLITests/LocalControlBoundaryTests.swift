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
        // A granted projection row exists on disk (no memory grant: no
        // daemon, no ceremony). The diagnostic fallback must deny anyway.
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let code = try await store.mint(
            matchingView: "git reset --hard",
            cwd: wd("/tmp/ws"),
            ruleID: nil,
            tty: tty,
            now: Date()
        )
        _ = try await store.redeem(code: code.rawValue, tty: tty, now: Date())
        let result = await client.evaluateResult(command: ShellCommand(rawValue: "git reset --hard"), cwd: wd("/tmp/ws"))
        guard case .deny = result.decision else {
            Issue.record("diagnostic fallback must not honor a grant")
            return
        }
        let rows = await store.list(now: Date())
        #expect(!rows.isEmpty)
    }

    @Test func agentCannotPlantHostAskGrant() async throws {
        // Step 8B: no client API plants grants. A legacy spend envelope
        // evaluates as an ordinary shell request through the hook door.
        let directory = try isolatedAllowOnceDirectory()
        let client = try isolatedClient(transport: nil, allowOnceDirectory: directory)
        let stdin = """
        {"toolName":"bash","cwd":"/tmp/ws","input":{"command":"git reset --hard"},"hostAsk":"spend"}
        """
        let wire = await hookWire(host: .pi, stdin: stdin, world: hookWorld { command, cwd in
            await client.evaluateResult(command: command, cwd: cwd)
        })
        #expect(wire.stdout.isEmpty == false)
        let rows = await AllowOnceStore(baseDirectory: directory).list(now: Date())
        #expect(rows.isEmpty)
    }

    @Test func ttyCannotAuthorizeDirectGrantWrites() async throws {
        // A TTY alone is not authority: without device-owner
        // authentication the tripwire refuses and nothing is written. The
        // CLI can only redeem codes, never plant grants (plants are
        // daemon-internal, via attestation or the resolve ceremony).
        let directory = try isolatedAllowOnceDirectory()
        let store = AllowOnceStore(baseDirectory: directory)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        await #expect(throws: AllowOnceAuthError.required) {
            try await withCLIProcess {
                _ = try await AllowOnceCLI.mint(command: ShellCommand(rawValue: "echo harmless"), cwd: wd("/tmp/ws"), tty: tty, robot: false, store: store, now: Date())
            }
        }
        await #expect(throws: AllowOnceAuthError.required) {
            try await withCLIProcess {
                _ = try await AllowOnceCLI.redeem(code: "abcdef", tty: tty, robot: false, store: store, now: Date())
            }
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

    @Test func setupRunsUnauthenticated_uninstallRequiresDeviceOwnerAuth() async throws {
        // Step 8B P9: `rv setup` only writes rv-owned hooks, the
        // LaunchAgent, and config — it adds oversight and cannot
        // manufacture ALLOW — so one-click install runs without
        // device-owner authentication. `rv uninstall` sheds oversight, so
        // the command requires one LA tripwire before the ceremony; without
        // it nothing is removed.
        let home = try isolatedHome()
        let layout = OwnedPaths(home: home)
        let environment = ["HOME": home.rawValue, "PATH": "/usr/bin:/bin"]
        try await withCLIProcess(environment: environment) {
            #expect(throws: ExitCode(0)) {
                try Setup.parse(["--robot"]).run()
            }
            #expect(FileManager.default.fileExists(atPath: layout.configDirectory))
        }
        try await withCLIProcess(environment: environment) {
            await #expect(throws: ExitCode(EX_NOPERM)) {
                try await Uninstall.parse(["--robot"]).run()
            }
            #expect(FileManager.default.fileExists(atPath: layout.configDirectory))
        }
        try await withCLIProcess(environment: environment, ownerAuthOutcome: .authenticated) {
            await #expect(throws: ExitCode.self) {
                try await Uninstall.parse(["--robot"]).run()
            }
        }
        try withTempHome { root, tempLayout, launchctl in
            let setupEnvironment = env(home: root, launchctl: launchctl)
            let installed = SetupRun.setup(setupEnvironment, force: true)
            #expect(installed.exitCode == 0)
            #expect(FileManager.default.fileExists(atPath: tempLayout.launchAgent))
            let removed = SetupRun.uninstall(setupEnvironment)
            #expect(removed.exitCode == 0)
            #expect(!FileManager.default.fileExists(atPath: tempLayout.launchAgent))
        }
    }

}
