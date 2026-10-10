import Foundation
import RVDomain
import Testing
@testable import RVIsolation

// Launch-family parity pins for T5 (C04 pilot). The server's launch/ensure/
// cancel/identity handlers move behind typed payloads; these tests pin the
// exact current fail-closed behavior so the refactor proves parity. The
// wire round-trip section is cross-platform; the direct-handler section
// needs the macOS-only host server.

private enum LaunchParityFixtures {
    static let id = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    static let runtime = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
}

@Suite("Launch payload wire parity")
struct LaunchParityWireTests {
    @Test func launchFamilyWireRoundTrips() throws {
        let requests: [WorkspaceControlRequest] = [
            WorkspaceControlRequest(
                operation: .launchRuntime,
                id: LaunchParityFixtures.id,
                executable: "/bin/sh",
                arguments: ["-c", "echo hi"],
                resourceProfileID: "shell",
                hook: "codex",
                io: "terminal",
                rows: 24,
                columns: 80
            ),
            WorkspaceControlRequest(
                operation: .launchAgentRuntime,
                id: LaunchParityFixtures.id,
                arguments: ["--once"],
                agentDefinitionID: "agent"
            ),
            WorkspaceControlRequest(
                operation: .launchCustomRuntime,
                id: LaunchParityFixtures.id,
                executable: "/bin/sleep",
                arguments: ["30"],
                customDefinitionDigest: String(repeating: "a", count: 64)
            ),
            WorkspaceControlRequest(
                operation: .ensureTerminalRuntime,
                id: LaunchParityFixtures.id,
                executable: "/bin/sh",
                resourceProfileID: "shell",
                hook: "codex",
                io: "terminal",
                rows: 24,
                columns: 80
            ),
            WorkspaceControlRequest(
                operation: .cancelRuntime,
                id: LaunchParityFixtures.id,
                runtime: LaunchParityFixtures.runtime
            ),
        ]
        #expect(requests.count == 5)
        for request in requests {
            let body = try #require(request.encode())
            guard case .request(let decoded) = WorkspaceControlRequest.decode(body) else {
                Issue.record("op \(request.rawOperation) did not decode")
                continue
            }
            #expect(decoded == request)
            #expect(decoded.encode() == body)
        }
    }
}

@Suite("Launch payload parse")
struct LaunchPayloadParseTests {
    private var context: WorkspaceControlLaunchRequest.Context {
        WorkspaceControlLaunchRequest.Context(
            resourcePolicy: RuntimeResourcePolicy(profiles: [
                RuntimeResourceProfile(id: "shell", projects: ["/proj"])
            ]),
            project: "/proj"
        )
    }

    @Test func launchParseAcceptsMinimalDiscard() {
        let parsed = LaunchRuntimePayload.parse(
            WorkspaceControlRequest(operation: .launchRuntime, executable: "/bin/sh"),
            resourcePolicy: .empty,
            project: "/proj"
        )
        guard case .success(let payload) = parsed else {
            Issue.record("minimal launch rejected: \(parsed)")
            return
        }
        #expect(payload.command == IsolatedCommand(executable: "/bin/sh", arguments: []))
        #expect(payload.io == .discard)
        #expect(payload.hook == nil)
        #expect(payload.resourceProfile == nil)
    }

    @Test func launchParseResolvesProfileAndHookAndTerminal() {
        let parsed = LaunchRuntimePayload.parse(
            WorkspaceControlRequest(
                operation: .launchRuntime,
                executable: "/bin/sh",
                arguments: ["-c", "echo hi"],
                resourceProfileID: "shell",
                hook: "codex",
                io: "terminal",
                rows: 24,
                columns: 80
            ),
            resourcePolicy: context.resourcePolicy,
            project: "/proj"
        )
        guard case .success(let payload) = parsed else {
            Issue.record("full launch rejected: \(parsed)")
            return
        }
        #expect(payload.command.arguments == ["-c", "echo hi"])
        #expect(payload.io == .pseudoTerminal(rows: 24, columns: 80))
        #expect(payload.hook == .codex)
        #expect(payload.resourceProfile?.id == "shell")
    }

    @Test func launchParseRejectsBadShapes() {
        let profile = context.resourcePolicy
        let cases: [(WorkspaceControlRequest, WorkspaceControlCode, String)] = [
            (WorkspaceControlRequest(operation: .launchRuntime), .invalidRequest, "missing executable"),
            (
                WorkspaceControlRequest(operation: .launchRuntime, executable: "bin/sh"),
                .invalidRequest, "relative executable"
            ),
            (
                WorkspaceControlRequest(operation: .launchRuntime, executable: "/bin/\0sh"),
                .invalidRequest, "NUL executable"
            ),
            (
                WorkspaceControlRequest(
                    operation: .launchRuntime, executable: "/bin/sh", arguments: ["a\0b"]
                ),
                .invalidRequest, "NUL argument"
            ),
            (
                WorkspaceControlRequest(
                    operation: .launchRuntime, executable: "/bin/sh",
                    resourceProfileID: "nope"
                ),
                .resourceProfileUnavailable, "unknown profile"
            ),
            (
                WorkspaceControlRequest(
                    operation: .launchRuntime, executable: "/bin/sh", hook: "not a tag!"
                ),
                .invalidRequest, "malformed hook"
            ),
            (
                WorkspaceControlRequest(
                    operation: .launchRuntime, executable: "/bin/sh", io: "terminal"
                ),
                .invalidRequest, "terminal without dimensions"
            ),
            (
                WorkspaceControlRequest(
                    operation: .launchRuntime, executable: "/bin/sh",
                    io: "discard", rows: 24, columns: 80
                ),
                .invalidRequest, "discard with dimensions"
            ),
            (
                WorkspaceControlRequest(
                    operation: .launchRuntime, executable: "/bin/sh", io: "inherit"
                ),
                .invalidRequest, "unknown io"
            ),
        ]
        for (request, code, label) in cases {
            #expect(
                LaunchRuntimePayload.parse(request, resourcePolicy: profile, project: "/proj")
                    == .failure(code),
                "\(label)"
            )
        }
    }

    @Test func launchParseOrdersExecutableBeforeProfileBeforeHook() {
        let profile = context.resourcePolicy
        // Unknown profile plus malformed hook reports the profile: the
        // lookup precedes hook selection.
        #expect(LaunchRuntimePayload.parse(
            WorkspaceControlRequest(
                operation: .launchRuntime, executable: "/bin/sh",
                resourceProfileID: "nope", hook: "not a tag!"
            ),
            resourcePolicy: profile,
            project: "/proj"
        ) == .failure(.resourceProfileUnavailable))
        // Relative executable plus unknown profile reports invalidRequest:
        // the executable check precedes the lookup.
        #expect(LaunchRuntimePayload.parse(
            WorkspaceControlRequest(
                operation: .launchRuntime, executable: "bin/sh",
                resourceProfileID: "nope"
            ),
            resourcePolicy: profile,
            project: "/proj"
        ) == .failure(.invalidRequest))
        // NUL executable plus unknown profile reports the profile: the
        // lookup precedes command construction. A command-first reorder
        // would report invalidRequest instead.
        #expect(LaunchRuntimePayload.parse(
            WorkspaceControlRequest(
                operation: .launchRuntime, executable: "/bin/\0sh",
                resourceProfileID: "nope"
            ),
            resourcePolicy: profile,
            project: "/proj"
        ) == .failure(.resourceProfileUnavailable))
    }

    @Test func launchParseGatesProfileOnProject() {
        #expect(LaunchRuntimePayload.parse(
            WorkspaceControlRequest(
                operation: .launchRuntime, executable: "/bin/sh",
                resourceProfileID: "shell"
            ),
            resourcePolicy: context.resourcePolicy,
            project: "/other"
        ) == .failure(.resourceProfileUnavailable))
    }

    @Test func launchParseAcceptsWellFormedNonHostHookAsNil() {
        let parsed = LaunchRuntimePayload.parse(
            WorkspaceControlRequest(
                operation: .launchRuntime, executable: "/bin/sh", hook: "agent-A"
            ),
            resourcePolicy: .empty,
            project: "/proj"
        )
        guard case .success(let payload) = parsed else {
            Issue.record("tagged launch rejected: \(parsed)")
            return
        }
        #expect(payload.hook == nil)
    }

    @Test func ensureParseRequiresTerminal() {
        let valid = EnsureTerminalRuntimePayload.parse(WorkspaceControlRequest(
            operation: .ensureTerminalRuntime,
            executable: "/bin/sh",
            arguments: ["-l"],
            resourceProfileID: "shell",
            hook: "codex",
            io: "terminal",
            rows: 24,
            columns: 80
        ))
        guard case .success(let payload) = valid else {
            Issue.record("valid ensure rejected: \(valid)")
            return
        }
        #expect(payload.command.arguments == ["-l"])
        #expect(payload.io == .pseudoTerminal(rows: 24, columns: 80))
        #expect(payload.hook == .codex)
        #expect(payload.resourceProfileID == "shell")
        #expect(EnsureTerminalRuntimePayload.parse(WorkspaceControlRequest(
            operation: .ensureTerminalRuntime, executable: "/bin/sh"
        )) == .failure(.invalidRequest))
        #expect(EnsureTerminalRuntimePayload.parse(WorkspaceControlRequest(
            operation: .ensureTerminalRuntime, executable: "/bin/sh", io: "terminal"
        )) == .failure(.invalidRequest))
        #expect(EnsureTerminalRuntimePayload.parse(WorkspaceControlRequest(
            operation: .ensureTerminalRuntime, hook: "not a tag!",
            io: "terminal", rows: 24, columns: 80
        )) == .failure(.invalidRequest))
    }

    @Test func ensureParseDefersProfileLookup() {
        // An unknown profile parses: the existing-runtime shortcut is
        // profile-agnostic and creation re-adjudicates through launch().
        let parsed = EnsureTerminalRuntimePayload.parse(WorkspaceControlRequest(
            operation: .ensureTerminalRuntime,
            executable: "/bin/sh",
            resourceProfileID: "no-such-profile",
            io: "terminal",
            rows: 24,
            columns: 80
        ))
        guard case .success(let payload) = parsed else {
            Issue.record("ensure with unknown profile rejected: \(parsed)")
            return
        }
        #expect(payload.resourceProfileID == "no-such-profile")
    }

    @Test func cancelParseRequiresRuntime() {
        #expect(CancelRuntimePayload.parse(WorkspaceControlRequest(
            operation: .cancelRuntime
        )) == .failure(.invalidRequest))
        let parsed = CancelRuntimePayload.parse(WorkspaceControlRequest(
            operation: .cancelRuntime, runtime: LaunchParityFixtures.runtime
        ))
        guard case .success(let payload) = parsed else {
            Issue.record("cancel rejected: \(parsed)")
            return
        }
        #expect(payload.runtime == LaunchParityFixtures.runtime)
    }

    @Test func identityPayloadsCarryOpFieldsInfallibly() {
        let agent = LaunchAgentRuntimePayload(WorkspaceControlRequest(
            operation: .launchAgentRuntime,
            arguments: ["--once"],
            agentDefinitionID: "agent"
        ))
        #expect(agent.agentDefinitionID == "agent")
        #expect(agent.arguments == ["--once"])
        // Even a malformed request constructs: the deny door consumes no
        // fields and denies it exactly like a valid one.
        let agentBare = LaunchAgentRuntimePayload(WorkspaceControlRequest(
            operation: .launchAgentRuntime, executable: "relative"
        ))
        #expect(agentBare.agentDefinitionID == nil)
        let custom = LaunchCustomRuntimePayload(WorkspaceControlRequest(
            operation: .launchCustomRuntime,
            executable: "/bin/sleep",
            customDefinitionDigest: String(repeating: "a", count: 64)
        ))
        #expect(custom.executable == "/bin/sleep")
        #expect(custom.customDefinitionDigest == String(repeating: "a", count: 64))
        #expect(custom.arguments == [])
    }

    @Test func launchRequestParseRoutesFamilyAndSkipsOthers() {
        let context = context
        let family: [WorkspaceControlRequest] = [
            WorkspaceControlRequest(operation: .launchRuntime, executable: "/bin/sh"),
            WorkspaceControlRequest(
                operation: .launchAgentRuntime, agentDefinitionID: "agent"
            ),
            WorkspaceControlRequest(
                operation: .launchCustomRuntime, executable: "/bin/sleep"
            ),
            WorkspaceControlRequest(
                operation: .ensureTerminalRuntime, executable: "/bin/sh",
                io: "terminal", rows: 24, columns: 80
            ),
            WorkspaceControlRequest(
                operation: .cancelRuntime, runtime: LaunchParityFixtures.runtime
            ),
        ]
        for request in family {
            let parsed = WorkspaceControlLaunchRequest.parse(request, context: context)
            guard case .success = parsed else {
                Issue.record("family op \(request.rawOperation) did not parse: \(String(describing: parsed))")
                continue
            }
        }
        let invalid = WorkspaceControlLaunchRequest.parse(
            WorkspaceControlRequest(operation: .launchRuntime),
            context: context
        )
        #expect(invalid == .failure(.invalidRequest))
        // Every non-launch op keeps the bag path (nil parse). The parse
        // switch is compiler-exhaustive; this list pins the fallback for
        // each unmigrated op so a mistyped arm cannot slip through.
        for op: WorkspaceControlOp in [
            .hello, .capabilities, .ping, .describeWorkspace, .listRuntimes,
            .closeWorkspace, .detach, .workspaceClosed,
            .subscribeTerminal, .unsubscribeTerminal, .terminalInput,
            .acquireTerminalInput, .releaseTerminalInput, .resizeTerminal,
            .terminalReplayBegin, .terminalReplay, .terminalReplayEnd,
            .terminalOutput, .terminalInputOwner, .terminalWindow,
            .runtimeExited, .terminalOverflow,
        ] {
            #expect(
                WorkspaceControlLaunchRequest.parse(
                    WorkspaceControlRequest(operation: op, id: LaunchParityFixtures.id),
                    context: context
                ) == nil,
                "\(op.rawValue) keeps the bag path"
            )
        }
    }

    @Test func launchRequestParseSkipsUnknownOperation() throws {
        let body = Data(
            "{\"v\":1,\"id\":\"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA\",\"op\":\"killProcess\"}".utf8
        )
        guard case .request(let request) = WorkspaceControlRequest.decode(body) else {
            Issue.record("unknown-op frame did not decode")
            return
        }
        #expect(request.operation == nil)
        #expect(WorkspaceControlLaunchRequest.parse(request, context: context) == nil)
    }
}

#if os(macOS)
private struct LaunchParityHost {
    var tree: ContainmentTree
    var supervisor: WorkspaceSessionSupervisor
    var server: WorkspaceHostServer

    init(resourcePolicy: RuntimeResourcePolicy = .empty) throws {
        tree = try ContainmentTree()
        let config = tree.rootURL.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let directory = try #require(WorkingDirectory(validating: tree.workspaceURL.path))
        supervisor = try WorkspaceSessionSupervisor.open(
            directory,
            lifecycleLog: .file(config.appendingPathComponent("workspace-sessions.jsonl"))
        ).get()
        server = try WorkspaceHostServer.start(
            supervisor: supervisor,
            configurationDirectory: config,
            sessionStore: .file(config.appendingPathComponent("runtime-sessions.jsonl")),
            resourcePolicy: resourcePolicy,
            admission: .failClosed
        ).get()
    }

    func close() {
        server.stop()
        _ = supervisor.close()
        tree.tearDown()
    }
}

@Suite("Launch handler parity")
struct LaunchParityHandlerTests {
    @Test func launchRejectsRelativeExecutableWithoutSpawn() throws {
        let host = try LaunchParityHost()
        defer { host.close() }
        let before = host.supervisor.runtimeFacts().count
        let refused = host.server.launch(WorkspaceControlRequest(
            operation: .launchRuntime,
            executable: "bin/sh"
        ))
        #expect(refused.ok != true)
        #expect(refused.code == .invalidRequest)
        #expect(host.supervisor.runtimeFacts().count == before)
    }

    @Test func launchRejectsUnknownProfileWithoutSpawn() throws {
        let host = try LaunchParityHost()
        defer { host.close() }
        let before = host.supervisor.runtimeFacts().count
        let refused = host.server.launch(WorkspaceControlRequest(
            operation: .launchRuntime,
            executable: "/bin/sleep",
            arguments: ["30"],
            resourceProfileID: "no-such-profile"
        ))
        #expect(refused.ok != true)
        #expect(refused.code == .resourceProfileUnavailable)
        #expect(host.supervisor.runtimeFacts().count == before)
    }

    @Test func launchRejectsTerminalIOWithoutDimensions() throws {
        let host = try LaunchParityHost()
        defer { host.close() }
        let before = host.supervisor.runtimeFacts().count
        let refused = host.server.launch(WorkspaceControlRequest(
            operation: .launchRuntime,
            executable: "/bin/sleep",
            arguments: ["30"],
            io: "terminal"
        ))
        #expect(refused.ok != true)
        #expect(refused.code == .invalidRequest)
        #expect(host.supervisor.runtimeFacts().count == before)
    }

    @Test func launchChecksProfileBeforeHook() throws {
        // Order pin: the profile lookup precedes hook selection, so a
        // message with both faults reports resourceProfileUnavailable.
        let host = try LaunchParityHost()
        defer { host.close() }
        let refused = host.server.launch(WorkspaceControlRequest(
            operation: .launchRuntime,
            executable: "/bin/sleep",
            arguments: ["30"],
            resourceProfileID: "no-such-profile",
            hook: "not a tag!"
        ))
        #expect(refused.ok != true)
        #expect(refused.code == .resourceProfileUnavailable)
        // Profile lookup also precedes command construction: NUL plus an
        // unknown profile still reports resourceProfileUnavailable.
        let refusedCommand = host.server.launch(WorkspaceControlRequest(
            operation: .launchRuntime,
            executable: "/bin/\0sleep",
            arguments: ["30"],
            resourceProfileID: "no-such-profile"
        ))
        #expect(refusedCommand.ok != true)
        #expect(refusedCommand.code == .resourceProfileUnavailable)
    }

    @Test func identityDoorDeniesInvalidFieldsIdentically() throws {
        // The deny door consumes no fields: malformed requests are
        // denied exactly like valid ones, never invalidRequest.
        let host = try LaunchParityHost()
        defer { host.close() }
        let requests = [
            WorkspaceControlRequest(operation: .launchAgentRuntime, id: UUID()),
            WorkspaceControlRequest(
                operation: .launchAgentRuntime,
                id: UUID(),
                executable: "relative",
                arguments: ["x"],
                hook: "not a tag!"
            ),
            WorkspaceControlRequest(operation: .launchCustomRuntime, id: UUID()),
            WorkspaceControlRequest(
                operation: .launchCustomRuntime,
                id: UUID(),
                executable: "relative",
                customDefinitionDigest: "zzz"
            ),
        ]
        for request in requests {
            let response = host.server.launchIdentity(request)
            #expect(response.ok == false)
            #expect(response.code == .requiresOperatorPermit)
            #expect(response.operation == request.operation)
        }
        #expect(host.supervisor.runtimeFacts().isEmpty)
    }

    @Test func ensureCreatesThenReusesTerminal() throws {
        let host = try LaunchParityHost()
        defer { host.close() }
        let created = host.server.ensureTerminalRuntime(WorkspaceControlRequest(
            operation: .ensureTerminalRuntime,
            executable: "/bin/sleep",
            arguments: ["60"],
            io: "terminal",
            rows: 24,
            columns: 80
        ))
        #expect(created.operation == .ensureTerminalRuntime)
        #expect(created.ok == true)
        #expect(created.created == true)
        #expect(created.terminal == true)
        #expect(created.rows == 24)
        #expect(created.columns == 80)
        let runtime = try #require(created.runtime)
        // Canonical shell: reuse ignores the requested executable.
        let reused = host.server.ensureTerminalRuntime(WorkspaceControlRequest(
            operation: .ensureTerminalRuntime,
            executable: "/bin/sh",
            io: "terminal",
            rows: 30,
            columns: 100
        ))
        #expect(reused.ok == true)
        #expect(reused.created == false)
        #expect(reused.runtime == runtime)
    }

    @Test func ensureRejectsNonTerminalIO() throws {
        let host = try LaunchParityHost()
        defer { host.close() }
        let before = host.supervisor.runtimeFacts().count
        let refused = host.server.ensureTerminalRuntime(WorkspaceControlRequest(
            operation: .ensureTerminalRuntime,
            executable: "/bin/sleep",
            arguments: ["60"]
        ))
        #expect(refused.ok != true)
        #expect(refused.code == .invalidRequest)
        #expect(host.supervisor.runtimeFacts().count == before)
    }

    @Test func ensureShortcutIgnoresProfileButCreationAdjudicates() throws {
        let host = try LaunchParityHost()
        defer { host.close() }
        // No existing terminal: creation adjudicates the unknown profile.
        let refused = host.server.ensureTerminalRuntime(WorkspaceControlRequest(
            operation: .ensureTerminalRuntime,
            executable: "/bin/sleep",
            arguments: ["60"],
            resourceProfileID: "no-such-profile",
            io: "terminal",
            rows: 24,
            columns: 80
        ))
        #expect(refused.ok != true)
        #expect(refused.code == .resourceProfileUnavailable)
        let created = host.server.ensureTerminalRuntime(WorkspaceControlRequest(
            operation: .ensureTerminalRuntime,
            executable: "/bin/sleep",
            arguments: ["60"],
            io: "terminal",
            rows: 24,
            columns: 80
        ))
        #expect(created.ok == true)
        #expect(created.created == true)
        // Existing terminal: the shortcut reuses despite the bad profile.
        let reused = host.server.ensureTerminalRuntime(WorkspaceControlRequest(
            operation: .ensureTerminalRuntime,
            executable: "/bin/sleep",
            arguments: ["60"],
            resourceProfileID: "no-such-profile",
            io: "terminal",
            rows: 24,
            columns: 80
        ))
        #expect(reused.ok == true)
        #expect(reused.created == false)
        #expect(reused.runtime == created.runtime)
    }

    @Test func cancelLaunchedRuntime() throws {
        let host = try LaunchParityHost()
        defer { host.close() }
        let launched = host.server.launch(WorkspaceControlRequest(
            operation: .launchRuntime,
            executable: "/bin/sleep",
            arguments: ["60"]
        ))
        #expect(launched.ok == true)
        let runtime = try #require(launched.runtime)
        let cancelled = host.server.cancel(WorkspaceControlRequest(
            operation: .cancelRuntime,
            runtime: runtime
        ))
        #expect(cancelled.operation == .cancelRuntime)
        #expect(cancelled.ok == true)
        #expect(cancelled.runtime == runtime)
    }

    @Test func cancelRejectsMissingAndUnknownRuntime() throws {
        let host = try LaunchParityHost()
        defer { host.close() }
        let missing = host.server.cancel(WorkspaceControlRequest(
            operation: .cancelRuntime
        ))
        #expect(missing.ok != true)
        #expect(missing.code == .invalidRequest)
        let unknown = host.server.cancel(WorkspaceControlRequest(
            operation: .cancelRuntime,
            runtime: UUID()
        ))
        #expect(unknown.ok != true)
        #expect(unknown.code == .runtimeNotFound)
    }

    @Test func closedWorkspaceRefusesLaunchAndEnsure() throws {
        let host = try LaunchParityHost()
        defer { host.close() }
        _ = host.supervisor.close()
        let launchRefused = host.server.launch(WorkspaceControlRequest(
            operation: .launchRuntime,
            executable: "/bin/sleep",
            arguments: ["60"]
        ))
        #expect(launchRefused.ok != true)
        #expect(launchRefused.code == .workspaceClosed)
        let ensureRefused = host.server.ensureTerminalRuntime(WorkspaceControlRequest(
            operation: .ensureTerminalRuntime,
            executable: "/bin/sleep",
            arguments: ["60"],
            io: "terminal",
            rows: 24,
            columns: 80
        ))
        #expect(ensureRefused.ok != true)
        #expect(ensureRefused.code == .workspaceClosed)
        // The phase gate precedes validation: malformed requests on a
        // closed workspace report workspaceClosed, never invalidRequest.
        let launchInvalid = host.server.launch(WorkspaceControlRequest(
            operation: .launchRuntime,
            executable: "bin/sh"
        ))
        #expect(launchInvalid.ok != true)
        #expect(launchInvalid.code == .workspaceClosed)
        let ensureInvalid = host.server.ensureTerminalRuntime(WorkspaceControlRequest(
            operation: .ensureTerminalRuntime,
            executable: "bin/sh"
        ))
        #expect(ensureInvalid.ok != true)
        #expect(ensureInvalid.code == .workspaceClosed)
    }
}
#endif
