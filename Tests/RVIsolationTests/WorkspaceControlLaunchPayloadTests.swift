import Foundation
import RVDomain
import Synchronization
import Testing
@testable import RVIsolation

// Launch-family parity pins at the codec seam (T1). The server's launch/
// ensure/cancel/identity handlers consume typed per-op payloads; these
// tests pin the exact fail-closed behavior so the refactor proves parity.
// The wire round-trip section is cross-platform; the direct-handler
// section needs the macOS-only host server.

private enum LaunchParityFixtures {
    static let id = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    static let runtime = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
}

private typealias LaunchFields = WorkspaceControlRequestPayload.Launch

/// Test-side reading of a launch-family reply payload.
private func launchReply(
    _ frame: WorkspaceControlResponseFrame
) -> WorkspaceControlResponsePayload.Launch? {
    switch frame.payload {
    case .launchRuntime(let fields), .launchAgentRuntime(let fields),
        .launchCustomRuntime(let fields), .ensureTerminalRuntime(let fields):
        fields
    default:
        nil
    }
}

@Suite("Launch payload wire parity")
struct LaunchParityWireTests {
    @Test func launchFamilyWireRoundTrips() throws {
        let requests: [WorkspaceControlRequestFrame] = [
            WorkspaceControlRequestFrame(
                id: LaunchParityFixtures.id,
                payload: .launchRuntime(.init(
                    executable: "/bin/sh",
                    arguments: ["-c", "echo hi"],
                    resourceProfileID: "shell",
                    hook: "codex",
                    io: "terminal",
                    rows: 24,
                    columns: 80
                ))
            ),
            WorkspaceControlRequestFrame(
                id: LaunchParityFixtures.id,
                payload: .launchAgentRuntime(.init(
                    agentDefinitionID: "agent",
                    arguments: ["--once"]
                ))
            ),
            WorkspaceControlRequestFrame(
                id: LaunchParityFixtures.id,
                payload: .launchCustomRuntime(.init(
                    executable: "/bin/sleep",
                    arguments: ["30"],
                    customDefinitionDigest: String(repeating: "a", count: 64)
                ))
            ),
            WorkspaceControlRequestFrame(
                id: LaunchParityFixtures.id,
                payload: .ensureTerminalRuntime(.init(
                    executable: "/bin/sh",
                    resourceProfileID: "shell",
                    hook: "codex",
                    io: "terminal",
                    rows: 24,
                    columns: 80
                ))
            ),
            WorkspaceControlRequestFrame(
                id: LaunchParityFixtures.id,
                payload: .cancelRuntime(.init(runtime: LaunchParityFixtures.runtime))
            ),
        ]
        #expect(requests.count == 5)
        for request in requests {
            let body = try #require(WorkspaceControlCodec.encodeRequest(request))
            guard case .frame(let decoded) = WorkspaceControlCodec.decodeRequest(body) else {
                Issue.record("op \(request.rawOperation) did not decode")
                continue
            }
            #expect(decoded == request)
            #expect(WorkspaceControlCodec.encodeRequest(decoded) == body)
        }
    }
}

@Suite("Launch payload parse")
struct LaunchPayloadParseTests {
    private var resourcePolicy: RuntimeResourcePolicy {
        RuntimeResourcePolicy(profiles: [
            RuntimeResourceProfile(id: "shell", projects: ["/proj"])
        ])
    }

    @Test func launchParseAcceptsMinimalDiscard() {
        let parsed = LaunchRuntimePayload.parse(
            LaunchFields(executable: "/bin/sh"),
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
            LaunchFields(
                executable: "/bin/sh",
                arguments: ["-c", "echo hi"],
                resourceProfileID: "shell",
                hook: "codex",
                io: "terminal",
                rows: 24,
                columns: 80
            ),
            resourcePolicy: resourcePolicy,
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
        let profile = resourcePolicy
        let cases: [(LaunchFields, WorkspaceControlCode, String)] = [
            (LaunchFields(), .invalidRequest, "missing executable"),
            (LaunchFields(executable: "bin/sh"), .invalidRequest, "relative executable"),
            (LaunchFields(executable: "/bin/\0sh"), .invalidRequest, "NUL executable"),
            (
                LaunchFields(executable: "/bin/sh", arguments: ["a\0b"]),
                .invalidRequest, "NUL argument"
            ),
            (
                LaunchFields(executable: "/bin/sh", resourceProfileID: "nope"),
                .resourceProfileUnavailable, "unknown profile"
            ),
            (
                LaunchFields(executable: "/bin/sh", hook: "not a tag!"),
                .invalidRequest, "malformed hook"
            ),
            (
                LaunchFields(executable: "/bin/sh", io: "terminal"),
                .invalidRequest, "terminal without dimensions"
            ),
            (
                LaunchFields(executable: "/bin/sh", io: "discard", rows: 24, columns: 80),
                .invalidRequest, "discard with dimensions"
            ),
            (
                LaunchFields(executable: "/bin/sh", io: "inherit"),
                .invalidRequest, "unknown io"
            ),
        ]
        for (fields, code, label) in cases {
            #expect(
                LaunchRuntimePayload.parse(fields, resourcePolicy: profile, project: "/proj")
                    == .failure(code),
                "\(label)"
            )
        }
    }

    @Test func launchParseOrdersExecutableBeforeProfileBeforeHook() {
        let profile = resourcePolicy
        // Unknown profile plus malformed hook reports the profile: the
        // lookup precedes hook selection.
        #expect(LaunchRuntimePayload.parse(
            LaunchFields(executable: "/bin/sh", resourceProfileID: "nope", hook: "not a tag!"),
            resourcePolicy: profile,
            project: "/proj"
        ) == .failure(.resourceProfileUnavailable))
        // Relative executable plus unknown profile reports invalidRequest:
        // the executable check precedes the lookup.
        #expect(LaunchRuntimePayload.parse(
            LaunchFields(executable: "bin/sh", resourceProfileID: "nope"),
            resourcePolicy: profile,
            project: "/proj"
        ) == .failure(.invalidRequest))
        // NUL executable plus unknown profile reports the profile: the
        // lookup precedes command construction. A command-first reorder
        // would report invalidRequest instead.
        #expect(LaunchRuntimePayload.parse(
            LaunchFields(executable: "/bin/\0sh", resourceProfileID: "nope"),
            resourcePolicy: profile,
            project: "/proj"
        ) == .failure(.resourceProfileUnavailable))
    }

    @Test func launchParseGatesProfileOnProject() {
        #expect(LaunchRuntimePayload.parse(
            LaunchFields(executable: "/bin/sh", resourceProfileID: "shell"),
            resourcePolicy: resourcePolicy,
            project: "/other"
        ) == .failure(.resourceProfileUnavailable))
    }

    @Test func launchParseAcceptsWellFormedNonHostHookAsNil() {
        let parsed = LaunchRuntimePayload.parse(
            LaunchFields(executable: "/bin/sh", hook: "agent-A"),
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
        let valid = EnsureTerminalRuntimePayload.parse(LaunchFields(
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
        #expect(EnsureTerminalRuntimePayload.parse(
            LaunchFields(executable: "/bin/sh")
        ) == .failure(.invalidRequest))
        #expect(EnsureTerminalRuntimePayload.parse(
            LaunchFields(executable: "/bin/sh", io: "terminal")
        ) == .failure(.invalidRequest))
        #expect(EnsureTerminalRuntimePayload.parse(
            LaunchFields(hook: "not a tag!", io: "terminal", rows: 24, columns: 80)
        ) == .failure(.invalidRequest))
    }

    @Test func ensureParseDefersProfileLookup() {
        // An unknown profile parses: the existing-runtime shortcut is
        // profile-agnostic and creation re-adjudicates through launch().
        let parsed = EnsureTerminalRuntimePayload.parse(LaunchFields(
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
        #expect(CancelRuntimePayload.parse(.init()) == .failure(.invalidRequest))
        let parsed = CancelRuntimePayload.parse(.init(runtime: LaunchParityFixtures.runtime))
        guard case .success(let payload) = parsed else {
            Issue.record("cancel rejected: \(parsed)")
            return
        }
        #expect(payload.runtime == LaunchParityFixtures.runtime)
    }

    @Test func identityPayloadsCarryOpFieldsInfallibly() throws {
        // The codec yields identity-launch payloads without adjudicating
        // their fields: the deny door consumes none, so even a bare or
        // malformed frame decodes to a payload the door denies.
        let agentBody = Data(
            "{\"v\":1,\"op\":\"launchAgentRuntime\",\"arguments\":[\"--once\"],\"agentDefinitionID\":\"agent\"}".utf8
        )
        guard case .frame(let agentFrame) = WorkspaceControlCodec.decodeRequest(agentBody),
            case .launchAgentRuntime(let agent) = agentFrame.payload
        else {
            Issue.record("agent launch frame did not decode to its payload")
            return
        }
        #expect(agent.agentDefinitionID == "agent")
        #expect(agent.arguments == ["--once"])
        let bareBody = Data("{\"v\":1,\"op\":\"launchAgentRuntime\"}".utf8)
        guard case .frame(let bareFrame) = WorkspaceControlCodec.decodeRequest(bareBody),
            case .launchAgentRuntime(let bare) = bareFrame.payload
        else {
            Issue.record("bare agent launch frame did not decode")
            return
        }
        #expect(bare.agentDefinitionID == nil)
        let customBody = Data(
            "{\"v\":1,\"op\":\"launchCustomRuntime\",\"executable\":\"/bin/sleep\",\"customDefinitionDigest\":\"\(String(repeating: "a", count: 64))\"}".utf8
        )
        guard case .frame(let customFrame) = WorkspaceControlCodec.decodeRequest(customBody),
            case .launchCustomRuntime(let custom) = customFrame.payload
        else {
            Issue.record("custom launch frame did not decode to its payload")
            return
        }
        #expect(custom.executable == "/bin/sleep")
        #expect(custom.customDefinitionDigest == String(repeating: "a", count: 64))
        #expect(custom.arguments == nil)
    }

    @Test func codecRoutesLaunchFamilyAndOtherOps() throws {
        // Every launch-family op decodes to its payload case at the seam.
        let family: [(String, WorkspaceControlOp)] = [
            ("{\"v\":1,\"op\":\"launchRuntime\",\"executable\":\"/bin/sh\"}", .launchRuntime),
            ("{\"v\":1,\"op\":\"launchAgentRuntime\",\"agentDefinitionID\":\"agent\"}", .launchAgentRuntime),
            ("{\"v\":1,\"op\":\"launchCustomRuntime\",\"executable\":\"/bin/sleep\"}", .launchCustomRuntime),
            (
                "{\"v\":1,\"op\":\"ensureTerminalRuntime\",\"executable\":\"/bin/sh\",\"io\":\"terminal\",\"rows\":24,\"cols\":80}",
                .ensureTerminalRuntime
            ),
            (
                "{\"v\":1,\"op\":\"cancelRuntime\",\"runtime\":\"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC\"}",
                .cancelRuntime
            ),
        ]
        for (json, op) in family {
            guard case .frame(let frame) = WorkspaceControlCodec.decodeRequest(Data(json.utf8)) else {
                Issue.record("family op \(op.rawValue) did not decode")
                continue
            }
            #expect(frame.operation == op)
        }
        // A structurally invalid launch still yields its payload (the
        // handler refuses it), while non-family requests keep their own
        // payload cases and server→client ops arrive as unsupported.
        guard case .frame(let invalid) = WorkspaceControlCodec.decodeRequest(
            Data("{\"v\":1,\"op\":\"launchRuntime\"}".utf8)
        ), case .launchRuntime(let fields) = invalid.payload else {
            Issue.record("invalid launch must still yield its payload")
            return
        }
        #expect(LaunchRuntimePayload.parse(
            fields, resourcePolicy: .empty, project: "/proj"
        ) == .failure(.invalidRequest))
        guard case .frame(let driven) = WorkspaceControlCodec.decodeRequest(
            Data("{\"v\":1,\"op\":\"terminalOutput\"}".utf8)
        ) else {
            Issue.record("event op must decode")
            return
        }
        #expect(driven.payload == .unsupported(.terminalOutput))
    }

    @Test func codecYieldsUnknownPayloadForUnknownOperation() throws {
        let body = Data(
            "{\"v\":1,\"id\":\"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA\",\"op\":\"killProcess\"}".utf8
        )
        guard case .frame(let request) = WorkspaceControlCodec.decodeRequest(body) else {
            Issue.record("unknown-op frame did not decode")
            return
        }
        #expect(request.operation == nil)
        #expect(request.payload == .unknown(rawOperation: "killProcess"))
    }
}

#if os(macOS)
private func launchRequest(_ fields: LaunchFields) -> WorkspaceControlRequestFrame {
    WorkspaceControlRequestFrame(payload: .launchRuntime(fields))
}

private func ensureRequest(_ fields: LaunchFields) -> WorkspaceControlRequestFrame {
    WorkspaceControlRequestFrame(payload: .ensureTerminalRuntime(fields))
}

private func cancelRequest(_ runtime: UUID?) -> WorkspaceControlRequestFrame {
    WorkspaceControlRequestFrame(payload: .cancelRuntime(.init(runtime: runtime)))
}

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
        let refused = host.server.launch(launchRequest(.init(executable: "bin/sh")))
        #expect(refused.ok != true)
        #expect(refused.code == .invalidRequest)
        #expect(host.supervisor.runtimeFacts().count == before)
    }

    @Test func launchRejectsUnknownProfileWithoutSpawn() throws {
        let host = try LaunchParityHost()
        defer { host.close() }
        let before = host.supervisor.runtimeFacts().count
        let refused = host.server.launch(launchRequest(.init(
            executable: "/bin/sleep",
            arguments: ["30"],
            resourceProfileID: "no-such-profile"
        )))
        #expect(refused.ok != true)
        #expect(refused.code == .resourceProfileUnavailable)
        #expect(host.supervisor.runtimeFacts().count == before)
    }

    @Test func launchRejectsTerminalIOWithoutDimensions() throws {
        let host = try LaunchParityHost()
        defer { host.close() }
        let before = host.supervisor.runtimeFacts().count
        let refused = host.server.launch(launchRequest(.init(
            executable: "/bin/sleep",
            arguments: ["30"],
            io: "terminal"
        )))
        #expect(refused.ok != true)
        #expect(refused.code == .invalidRequest)
        #expect(host.supervisor.runtimeFacts().count == before)
    }

    @Test func launchChecksProfileBeforeHook() throws {
        // Order pin: the profile lookup precedes hook selection, so a
        // message with both faults reports resourceProfileUnavailable.
        let host = try LaunchParityHost()
        defer { host.close() }
        let refused = host.server.launch(launchRequest(.init(
            executable: "/bin/sleep",
            arguments: ["30"],
            resourceProfileID: "no-such-profile",
            hook: "not a tag!"
        )))
        #expect(refused.ok != true)
        #expect(refused.code == .resourceProfileUnavailable)
        // Profile lookup also precedes command construction: NUL plus an
        // unknown profile still reports resourceProfileUnavailable.
        let refusedCommand = host.server.launch(launchRequest(.init(
            executable: "/bin/\0sleep",
            arguments: ["30"],
            resourceProfileID: "no-such-profile"
        )))
        #expect(refusedCommand.ok != true)
        #expect(refusedCommand.code == .resourceProfileUnavailable)
    }

    @Test func identityDoorDeniesInvalidFieldsIdentically() throws {
        // The deny door consumes no fields: malformed requests are
        // denied exactly like valid ones, never invalidRequest.
        let host = try LaunchParityHost()
        defer { host.close() }
        let requests = [
            WorkspaceControlRequestFrame(id: UUID(), payload: .launchAgentRuntime(.init())),
            WorkspaceControlRequestFrame(
                id: UUID(),
                payload: .launchAgentRuntime(.init(arguments: ["x"], io: "terminal"))
            ),
            WorkspaceControlRequestFrame(id: UUID(), payload: .launchCustomRuntime(.init())),
            WorkspaceControlRequestFrame(
                id: UUID(),
                payload: .launchCustomRuntime(.init(
                    executable: "relative",
                    customDefinitionDigest: "zzz"
                ))
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
        let created = host.server.ensureTerminalRuntime(ensureRequest(.init(
            executable: "/bin/sleep",
            arguments: ["60"],
            io: "terminal",
            rows: 24,
            columns: 80
        )))
        #expect(created.operation == .ensureTerminalRuntime)
        #expect(created.ok == true)
        let createdFields = try #require(launchReply(created))
        #expect(createdFields.created == true)
        #expect(createdFields.terminal == true)
        #expect(createdFields.rows == 24)
        #expect(createdFields.columns == 80)
        let runtime = try #require(createdFields.runtime)
        // Canonical shell: reuse ignores the requested executable.
        let reused = host.server.ensureTerminalRuntime(ensureRequest(.init(
            executable: "/bin/sh",
            io: "terminal",
            rows: 30,
            columns: 100
        )))
        #expect(reused.ok == true)
        #expect(launchReply(reused)?.created == false)
        #expect(launchReply(reused)?.runtime == runtime)
    }

    @Test func ensureRejectsNonTerminalIO() throws {
        let host = try LaunchParityHost()
        defer { host.close() }
        let before = host.supervisor.runtimeFacts().count
        let refused = host.server.ensureTerminalRuntime(ensureRequest(.init(
            executable: "/bin/sleep",
            arguments: ["60"]
        )))
        #expect(refused.ok != true)
        #expect(refused.code == .invalidRequest)
        #expect(host.supervisor.runtimeFacts().count == before)
    }

    @Test func ensureShortcutIgnoresProfileButCreationAdjudicates() throws {
        let host = try LaunchParityHost()
        defer { host.close() }
        // No existing terminal: creation adjudicates the unknown profile.
        let refused = host.server.ensureTerminalRuntime(ensureRequest(.init(
            executable: "/bin/sleep",
            arguments: ["60"],
            resourceProfileID: "no-such-profile",
            io: "terminal",
            rows: 24,
            columns: 80
        )))
        #expect(refused.ok != true)
        #expect(refused.code == .resourceProfileUnavailable)
        let created = host.server.ensureTerminalRuntime(ensureRequest(.init(
            executable: "/bin/sleep",
            arguments: ["60"],
            io: "terminal",
            rows: 24,
            columns: 80
        )))
        #expect(created.ok == true)
        #expect(launchReply(created)?.created == true)
        // Existing terminal: the shortcut reuses despite the bad profile.
        let reused = host.server.ensureTerminalRuntime(ensureRequest(.init(
            executable: "/bin/sleep",
            arguments: ["60"],
            resourceProfileID: "no-such-profile",
            io: "terminal",
            rows: 24,
            columns: 80
        )))
        #expect(reused.ok == true)
        #expect(launchReply(reused)?.created == false)
        #expect(launchReply(reused)?.runtime == launchReply(created)?.runtime)
    }

    @Test func cancelLaunchedRuntime() throws {
        let host = try LaunchParityHost()
        defer { host.close() }
        let launched = host.server.launch(launchRequest(.init(
            executable: "/bin/sleep",
            arguments: ["60"]
        )))
        #expect(launched.ok == true)
        let runtime = try #require(launchReply(launched)?.runtime)
        let cancelled = host.server.cancel(cancelRequest(runtime))
        #expect(cancelled.operation == .cancelRuntime)
        #expect(cancelled.ok == true)
        #expect(cancelled.payload.runtime == runtime)
    }

    @Test func cancelRejectsMissingAndUnknownRuntime() throws {
        let host = try LaunchParityHost()
        defer { host.close() }
        let missing = host.server.cancel(cancelRequest(nil))
        #expect(missing.ok != true)
        #expect(missing.code == .invalidRequest)
        let unknown = host.server.cancel(cancelRequest(UUID()))
        #expect(unknown.ok != true)
        #expect(unknown.code == .runtimeNotFound)
    }

    @Test func closedWorkspaceRefusesLaunchAndEnsure() throws {
        let host = try LaunchParityHost()
        defer { host.close() }
        _ = host.supervisor.close()
        let launchRefused = host.server.launch(launchRequest(.init(
            executable: "/bin/sleep",
            arguments: ["60"]
        )))
        #expect(launchRefused.ok != true)
        #expect(launchRefused.code == .workspaceClosed)
        let ensureRefused = host.server.ensureTerminalRuntime(ensureRequest(.init(
            executable: "/bin/sleep",
            arguments: ["60"],
            io: "terminal",
            rows: 24,
            columns: 80
        )))
        #expect(ensureRefused.ok != true)
        #expect(ensureRefused.code == .workspaceClosed)
        // The phase gate precedes validation: malformed requests on a
        // closed workspace report workspaceClosed, never invalidRequest.
        let launchInvalid = host.server.launch(launchRequest(.init(executable: "bin/sh")))
        #expect(launchInvalid.ok != true)
        #expect(launchInvalid.code == .workspaceClosed)
        let ensureInvalid = host.server.ensureTerminalRuntime(ensureRequest(.init(
            executable: "bin/sh"
        )))
        #expect(ensureInvalid.ok != true)
        #expect(ensureInvalid.code == .workspaceClosed)
    }

    @Test func dispatchClosedWorkspaceReportsPhaseBeforeValidation() throws {
        // `operation` reaches `launchFamily` after authorization. This is
        // that arm: an already-closed workspace reports the phase code
        // before the payload is validated. The direct helper is a
        // different entry and does not pin this.
        let host = try LaunchParityHost()
        defer { host.close() }
        _ = host.supervisor.close()
        let launchInvalid = host.server.testingDispatchLaunchFamily(
            launchRequest(.init(executable: "bin/sh"))
        )
        #expect(launchInvalid.ok != true)
        #expect(launchInvalid.code == .workspaceClosed)
        let ensureInvalid = host.server.testingDispatchLaunchFamily(
            ensureRequest(.init(executable: "bin/sh"))
        )
        #expect(ensureInvalid.ok != true)
        #expect(ensureInvalid.code == .workspaceClosed)
    }

    @Test func dispatchEnsureReuseRechecksPhaseUnderLock() throws {
        // The pre-parse gate has already passed. Close then moves the
        // phase to `.closing` while this request is blocked on
        // `terminalEnsureLock` and the terminal is still running. Reuse
        // must report workspaceClosing. The direct helper never enters
        // this window: it gates only after it owns the lock.
        let host = try LaunchParityHost()
        defer { host.close() }
        let created = host.server.ensureTerminalRuntime(ensureRequest(.init(
            executable: "/bin/sleep",
            arguments: ["60"],
            io: "terminal",
            rows: 24,
            columns: 80
        )))
        #expect(created.ok == true)
        #expect(launchReply(created)?.created == true)
        let runtime = try #require(launchReply(created)?.runtime)
        let request = ensureRequest(.init(
            executable: "/bin/sh",
            io: "terminal",
            rows: 24,
            columns: 80
        ))
        let server = host.server
        let box = LaunchReplyBox()
        var queuedThenClosed = false
        server.testingWithEnsureLockHeld {
            let thread = Thread {
                box.value = server.testingDispatchLaunchFamily(request)
            }
            thread.name = "rv-test-ensure-dispatch"
            thread.start()
            // Close only after the pre-parse gate has passed. A timeout
            // must not flip the phase, or a late pre-parse refusal would
            // look like the in-lock recheck.
            guard server.testingWaitForEnsureLockArrival() else { return }
            #expect(host.supervisor.testingBeginClose())
            #expect(host.supervisor.snapshot.phase == .closing)
            queuedThenClosed = true
        }
        #expect(queuedThenClosed)
        let deadline = Date().addingTimeInterval(5)
        while box.value == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        let refused = try #require(box.value)
        #expect(refused.ok != true)
        #expect(refused.code == .workspaceClosing)
        #expect(refused.payload.runtime == nil)
        #expect(host.supervisor.snapshot.phase == .closing)
        #expect(host.supervisor.runtimeFacts().contains {
            $0.id == runtime && $0.running && $0.terminal
        })
    }
}

private final class LaunchReplyBox: Sendable {
    private let box = Mutex<WorkspaceControlResponseFrame?>(nil)

    var value: WorkspaceControlResponseFrame? {
        get { box.withLock { $0 } }
        set { box.withLock { $0 = newValue } }
    }
}
#endif

@Suite("Micro-VM launch wire")
struct MicroVMLaunchWireTests {
    private let options = MicroVMLaunchOptions(image: "alpine:3.20", cpus: 2, memoryMiB: 1024)!

    @Test func launchRequestCarriesMicroVMOptionsRoundTrip() throws {
        let request = WorkspaceControlRequestFrame(
            id: LaunchParityFixtures.id,
            payload: .launchRuntime(.init(executable: "/bin/sh", microvm: options))
        )
        let body = try #require(WorkspaceControlCodec.encodeRequest(request))
        let text = try #require(String(data: body, encoding: .utf8))
        #expect(text.contains(#""microvm":{"cpus":2,"image":"alpine:3.20","memoryMiB":1024}"#))
        guard case .frame(let decoded) = WorkspaceControlCodec.decodeRequest(body) else {
            Issue.record("micro-VM launch did not decode")
            return
        }
        guard case .launchRuntime(let fields) = decoded.payload else {
            Issue.record("micro-VM launch decoded to \(decoded.payload)")
            return
        }
        #expect(fields.microvm == options)
        #expect(WorkspaceControlCodec.encodeRequest(decoded) == body)
    }

    @Test func invalidMicroVMFieldsFailClosed() {
        let bodies = [
            #"{"v":1,"op":"launchRuntime","executable":"/bin/sh","microvm":{"image":"alpine","cpus":0}}"#,
            #"{"v":1,"op":"launchRuntime","executable":"/bin/sh","microvm":{"image":"alpine","net":true}}"#,
            #"{"v":1,"op":"launchRuntime","executable":"/bin/sh","microvm":{"image":""}}"#,
            #"{"v":1,"op":"launchRuntime","executable":"/bin/sh","microvm":"alpine"}"#,
        ]
        for body in bodies {
            if case .frame = WorkspaceControlCodec.decodeRequest(Data(body.utf8)) {
                Issue.record("accepted \(body)")
            }
        }
    }

    @Test func launchParseCarriesMicroVMOptions() {
        let parsed = LaunchRuntimePayload.parse(
            .init(executable: "/bin/sh", microvm: options),
            resourcePolicy: .empty,
            project: "/proj"
        )
        guard case .success(let payload) = parsed else {
            Issue.record("micro-VM launch rejected: \(parsed)")
            return
        }
        #expect(payload.microVM == options)
    }

    @Test func ensureTerminalRuntimeRefusesMicroVM() {
        let parsed = EnsureTerminalRuntimePayload.parse(
            .init(
                executable: "/bin/sh",
                microvm: options,
                io: "terminal",
                rows: 24,
                columns: 80
            )
        )
        guard case .failure(.invalidRequest) = parsed else {
            Issue.record("ensure must refuse a micro-VM request: \(parsed)")
            return
        }
    }
}
