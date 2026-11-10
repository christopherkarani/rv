import ArgumentParser
import Foundation
import Testing
import RVDomain
import RVHooks
import RVIPC
import RVPolicy
import RVService
@testable import RVCLI

struct LocalControlBoundaryTests {
    @Test func missingServiceDeniesEveryHostWithoutEvaluatingInput() async throws {
        let client = try isolatedClient(transport: nil)
        for host in HookHost.allCases {
            let wire = await client.hookEvaluate(host: host, stdin: "{}", whenDown: .deny)
            #expect(wire == HookDaemonFallback.wire(host: host, failure: .unreachable, mode: .deny))
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
        let wire = await client.hookEvaluate(host: .grok, stdin: "{}", whenDown: .deny)
        #expect(wire == HookDaemonFallback.wire(host: .grok, failure: .protocol, mode: .deny))
        #expect(transport.invalidationCount == 1)
    }

#if canImport(XPC)
    @Test func daemonAuthenticationFailureDeniesAsUntrustedEvenWhenAsking() async throws {
        let client = try isolatedClient(transport: DaemonAuthFailingTransport())
        let wire = await client.hookEvaluate(host: .claude, stdin: "{}", whenDown: .ask)
        #expect(wire == HookDaemonFallback.wire(host: .claude, failure: .untrusted, mode: .deny))
        #expect(wire.stdout.contains("identity check failed"))
    }
#endif

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
        // Unknown codes report unknownCode without prompting LA: no
        // Touch ID for garbage (finding 8). The tripwire still guards
        // minted codes (see redeemWithoutDaemonFailsClosedAndKeepsPending).
        await #expect(throws: AllowOnceError.unknownCode) {
            try await withCLIProcess {
                _ = try await AllowOnceCLI.redeem(code: "abcdef", tty: tty, robot: false, store: store, now: Date())
            }
        }
        let rows = await store.list(now: Date())
        #expect(rows.isEmpty)
        // Without owner authentication the abandon gate refuses before any
        // workspace is touched.
        await #expect(throws: ValidationError.self) {
            try await withCLIProcess { try await WorkspaceCommandRun.abandon("/tmp/ws") }
        }
    }
    @Test func abandonBodyBehindGateRefusesUnknownProject() throws {
        // The gate throws first (pinned above); the restored body behind
        // it refuses a project with no blocked workspace instead of
        // silently succeeding. A random path can never be blocked, so this
        // only exercises the refused/failed error path — never a mutation.
        #expect(throws: ValidationError.self) {
            try WorkspaceCommandRun.abandonBlockedWorkspace(
                "/tmp/ws-definitely-not-a-workspace-\(UUID().uuidString)")
        }
    }

    @Test func permanentAllowlistMutationsRequireOwnerAuthorization() async throws {
        var add = try AllowlistAdd.parse(["core.git:reset-hard", "--reason", "operator exception"])
        var exact = try AllowlistAddCommand.parse(["echo harmless", "--reason", "operator exception"])
        var remove = try AllowlistRemove.parse(["core.git:reset-hard"])
        // No owner authentication given: every mutation refuses.
        try await withCLIProcess(home: try isolatedHome()) {
            await #expect(throws: ValidationError.self) { try await add.run() }
            await #expect(throws: ValidationError.self) { try await exact.run() }
            await #expect(throws: ValidationError.self) { try await remove.run() }
        }
    }

    @Test func safetyMutationRequiresOwnerAuthorization() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home) {
            await #expect(throws: ValidationError.self) { try await SafetyRun.set(.normal, home: home) }
            await #expect(throws: ValidationError.self) { try await SafetyRun.set(.strict, home: home) }
        }
        #expect(SafetyRun.show(home: home, workspace: nil) == "normal")
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
            await #expect(throws: ExitCode(0)) {
                try await Setup.parse(["--robot"]).run()
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

    @Test func hookServiceLivenessTrueWhenSnapshotAnswers() async throws {
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: ProtocolVersion.name, serviceSemver: "1.0.0", status: .ok),
            responseResult: .doctorSnapshot(DoctorSnapshotReply(
                serviceSemver: "1.0.0",
                state: .running,
                idleExitSeconds: 300,
                packsEnabled: [],
                checks: []
            ))
        )
        let client = try isolatedClient(transport: transport)
        #expect(await client.verifyHookService(attempts: 1, retryDelayNanoseconds: 0) == true)
        #expect(transport.sendCount == 1)
    }

    @Test func hookServiceLivenessFalseWithoutTransport() async throws {
        let client = try isolatedClient(transport: nil)
        #expect(await client.verifyHookService(attempts: 1, retryDelayNanoseconds: 0) == false)
    }

    @Test func hookServiceLivenessRetriesThenGivesUp() async throws {
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: ProtocolVersion.name, serviceSemver: "1.0.0", status: .ok),
            sendError: .timeout
        )
        let client = try isolatedClient(transport: transport)
        #expect(await client.verifyHookService(attempts: 3, retryDelayNanoseconds: 0) == false)
        #expect(transport.sendCount == 3)
    }

    @Test func setupOutcomeRunsTheFlowWithTheCallersContext() async throws {
        // The flow runs on its own thread (its readiness wait blocks); the
        // test seam must cross with it so setup never sees the live HOME.
        // An isolated HOME does not own the real service, so no probe runs.
        let (outcome, home) = try await wiredSetupOutcome()
        #expect(outcome.exitCode == 0)
        let settings = try String(
            contentsOfFile: home.rawValue + "/.config/muse/settings.json", encoding: .utf8)
        #expect(settings != #"{"schema_version":1}"#, "setup wired the isolated HOME's muse")
    }

    /// Runs setup against a home with one wired host.
    /// Asserted on the outcome, not a captured fd: fd capture deadlocks
    /// under parallel test execution.
    private func wiredSetupOutcome() async throws -> (SetupOutcome, HomeDirectory) {
        let home = try isolatedHome()
        let museDir = URL(fileURLWithPath: home.rawValue).appendingPathComponent(".config/muse")
        try FileManager.default.createDirectory(at: museDir, withIntermediateDirectories: true)
        try #"{"schema_version":1}"#.write(
            to: museDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8
        )
        // A slot only reads `.wired` when the baked rv path and its rv-cli
        // sibling are executable. Stubbed, never executed.
        let binDir = URL(fileURLWithPath: home.rawValue).appendingPathComponent(".local/bin")
        try writeExecutableScript(at: binDir.appendingPathComponent("rv"), source: "#!/bin/sh\nexit 0\n")
        try writeExecutableScript(at: binDir.appendingPathComponent("rv-cli"), source: "#!/bin/sh\nexit 0\n")
        let environment = ["HOME": home.rawValue, "PATH": "/usr/bin:/bin"]
        let outcome = try await withCLIProcess(environment: environment) {
            await Setup().setupOutcome(
                intent: SetupIntent(
                    kind: .install,
                    force: false,
                    appearance: .robot,
                    animate: false,
                    ceremonyKind: .setup
                ),
                clock: LiveSetupCeremonyClock(),
                write: { _ in }
            )
        }
        return (outcome, home)
    }

}

#if canImport(XPC)
/// Hook consult connects, then the daemon fails verification.
private struct DaemonAuthFailingTransport: ServiceTransport {
    func hello(clientSemver: String) async throws -> HelloAckView {
        HelloAckView(protocolName: ProtocolVersion.name, serviceSemver: "1.0.0", status: .ok)
    }

    func send(_ body: Data) async throws -> Data {
        Data()
    }

    func sendHookConsult(_ body: Data, timeoutMs: Int) async throws -> Data {
        throw XPCEvaluateClientError.authenticationFailed
    }

    func invalidate() {}
}
#endif
