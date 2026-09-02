import Foundation
import Testing
import RVDomain
import RVHooks
import RVIPC
@testable import RVCLI

struct OneShotEvaluateClientTests {
    @Test func productionHookRun_sendsHookEvaluateNotEvaluate() async throws {
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", status: .ok),
            responseResult: .hookEvaluate(HookEvaluateReply(stdout: "", exitCode: 0))
        )
        let client = try isolatedClient(transport: transport)
        var hook = Hook()
        hook.host = .grok
        let stdin = try grokHookFixture("allow-git-status.json")
        _ = await hook.run(stdin: stdin, client: client)

        let sent = try #require(transport.sends.first)
        let request = try IPCJSON.decode(IPCRequest.self, from: sent)
        guard case .hookEvaluate(let params) = request.method else {
            Issue.record("production hook path must send hookEvaluate, not evaluate")
            return
        }
        #expect(params.host == .grok)
        #expect(params.stdin == stdin)
        #expect(params.clientSemver == ProtocolVersion.serviceSemver)
        #expect(transport.sendCount == 1)
        #expect(transport.helloCount == 0)
        #expect(transport.lastSendTimeoutMs == 700)
    }

    @Test func hookEvaluateNilTransport_resetHardDeniesAndStashDropAllows() async throws {
        let client = try isolatedClient(transport: nil)
        var hook = Hook()
        hook.host = .grok
        let denyOutcome = await hook.run(stdin: try grokHookFixture("deny-git-reset-hard.json"), client: client)
        let denyJSON = try #require(
            JSONSerialization.jsonObject(with: Data(denyOutcome.stdout.utf8)) as? [String: Any]
        )
        #expect(denyJSON["decision"] as? String == "deny")
        #expect(denyOutcome.exitCode == 0)

        let allowOutcome = await hook.run(
            stdin: try grokHookFixture("allow-medium-stash-drop.json"),
            client: client
        )
        #expect(allowOutcome.stdout.isEmpty)
        #expect(allowOutcome.exitCode == 0)
        #expect(allowOutcome.stdout.contains("deny") == false)
    }

    @Test func hookEvaluateReplyAskJSON_isForwardedNotSilentAllow() async throws {
        let askStdout = "{\"decision\":\"ask\",\"continuation\":\"hostNative\"}\n"
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", status: .ok),
            responseResult: .hookEvaluate(HookEvaluateReply(stdout: askStdout, exitCode: 1))
        )
        let client = try isolatedClient(transport: transport)
        var hook = Hook()
        hook.host = .pi
        let stdin = """
        {"toolName":"bash","cwd":"/tmp/ws","input":{"command":"git reset --hard"}}
        """
        let outcome = await hook.run(stdin: stdin, client: client)
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8)) as? [String: Any]
        )
        #expect(json["decision"] as? String == "ask")
        #expect(outcome.stdout.contains("\"decision\":\"allow\"") == false)
        #expect(outcome.exitCode == 1)

        let sent = try #require(transport.sends.first)
        let request = try IPCJSON.decode(IPCRequest.self, from: sent)
        guard case .hookEvaluate = request.method else {
            Issue.record("Ask reply must arrive via hookEvaluate, not evaluate")
            return
        }
        #expect(transport.helloCount == 0)
    }

    @Test func hookEvaluateReplyStderr_isForwardedOnWire() async throws {
        let reason = "RV · Blocked. Destroys uncommitted changes."
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", status: .ok),
            responseResult: .hookEvaluate(
                HookEvaluateReply(
                    stdout: "{\"decision\":\"block\",\"reason\":\"\(reason)\"}\n",
                    exitCode: 2,
                    stderr: reason
                )
            )
        )
        let client = try isolatedClient(transport: transport)
        var hook = Hook()
        hook.host = .codex
        let outcome = await hook.run(
            stdin: try grokHookFixture("deny-git-reset-hard.json"),
            client: client
        )
        #expect(outcome.stderr == reason)
        #expect(outcome.exitCode == 2)
        #expect(outcome.stdout.contains("\"decision\":\"block\""))
    }

    @Test func hookEvaluateMismatchedResponseID_fallsBackInProcessAndDeniesResetHard() async throws {
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", status: .ok),
            responseResult: .hookEvaluate(HookEvaluateReply(stdout: "", exitCode: 0)),
            responseID: UUID()
        )
        let client = try isolatedClient(transport: transport)
        var hook = Hook()
        hook.host = .grok
        let outcome = await hook.run(stdin: try grokHookFixture("deny-git-reset-hard.json"), client: client)
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8)) as? [String: Any]
        )
        #expect(json["decision"] as? String == "deny")
        #expect(transport.invalidationCount == 1)
        #expect(transport.helloCount == 0)
    }

    @Test func hookEvaluateMismatchedResponseProtocol_fallsBackInProcessAndDeniesResetHard() async throws {
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", status: .ok),
            responseResult: .hookEvaluate(HookEvaluateReply(stdout: "", exitCode: 0)),
            responseProtocolName: "rv.ipc.v0"
        )
        let client = try isolatedClient(transport: transport)
        var hook = Hook()
        hook.host = .grok
        let outcome = await hook.run(stdin: try grokHookFixture("deny-git-reset-hard.json"), client: client)
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8)) as? [String: Any]
        )
        #expect(json["decision"] as? String == "deny")
        #expect(transport.invalidationCount == 1)
        #expect(transport.helloCount == 0)
    }

    @Test func hookEvaluateEvaluateReply_isNotFirstPath_fallsBackAndDenies() async throws {
        let spoofedAllow = EvaluationResult(outcome: .plain, matchingView: "git reset --hard")
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", status: .ok),
            responseResult: .evaluate(EvaluateReply(result: spoofedAllow))
        )
        let client = try isolatedClient(transport: transport)
        var hook = Hook()
        hook.host = .grok
        let outcome = await hook.run(stdin: try grokHookFixture("deny-git-reset-hard.json"), client: client)
        let sent = try #require(transport.sends.first)
        let request = try IPCJSON.decode(IPCRequest.self, from: sent)
        guard case .hookEvaluate = request.method else {
            Issue.record("must not use evaluate as the Swift hook first-call path")
            return
        }
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8)) as? [String: Any]
        )
        #expect(json["decision"] as? String == "deny")
        #expect(transport.invalidationCount == 1)
    }

    @Test func hookEvaluateUnprovableSemver_fallsBackInProcessAndDeniesResetHard() async throws {
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", status: .ok),
            responseResult: .hookEvaluate(
                HookEvaluateReply(stdout: "", exitCode: 0, serviceSemver: nil)
            )
        )
        let client = try isolatedClient(transport: transport)
        var hook = Hook()
        hook.host = .grok
        let outcome = await hook.run(stdin: try grokHookFixture("deny-git-reset-hard.json"), client: client)
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8)) as? [String: Any]
        )
        #expect(json["decision"] as? String == "deny")
        #expect(transport.invalidationCount == 1)
        #expect(transport.helloCount == 0)
    }

    @Test func hookEvaluateSendFailure_resetHardDeniesAndStashDropAllows() async throws {
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", status: .ok),
            sendError: .interrupted
        )
        let client = try isolatedClient(transport: transport)
        var hook = Hook()
        hook.host = .grok
        let denyOutcome = await hook.run(
            stdin: try grokHookFixture("deny-git-reset-hard.json"),
            client: client
        )
        let denyJSON = try #require(
            JSONSerialization.jsonObject(with: Data(denyOutcome.stdout.utf8)) as? [String: Any]
        )
        #expect(denyJSON["decision"] as? String == "deny")
        #expect(transport.sendCount == 1)
        #expect(transport.helloCount == 0)

        let allowOutcome = await hook.run(
            stdin: try grokHookFixture("allow-medium-stash-drop.json"),
            client: client
        )
        #expect(allowOutcome.stdout.isEmpty)
        #expect(allowOutcome.exitCode == 0)
        #expect(allowOutcome.stdout.contains("deny") == false)
        #expect(transport.sendCount == 2)
        #expect(transport.helloCount == 0)
    }

    @Test func hookEvaluateUnexpectedVia_fallsBackInProcessAndDeniesResetHard() async throws {
        let body = try spoofedHookEvaluateResponse(via: "inProcess", stdout: "", exitCode: 0)
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", status: .ok),
            sendReply: body
        )
        let client = try isolatedClient(transport: transport)
        var hook = Hook()
        hook.host = .grok
        let outcome = await hook.run(stdin: try grokHookFixture("deny-git-reset-hard.json"), client: client)
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8)) as? [String: Any]
        )
        #expect(json["decision"] as? String == "deny")
        #expect(transport.sendCount == 1)
        #expect(transport.helloCount == 0)
    }

    @Test func hookEvaluateNilTransport_codexDenyForwardsStderr() async throws {
        let client = try isolatedClient(transport: nil)
        var hook = Hook()
        hook.host = .codex
        let outcome = await hook.run(
            stdin: try hookFixture("codex", "deny-git-reset-hard.json"),
            client: client
        )
        let why = try hookFixture("codex", "deny-git-reset-hard.err")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = try #require(allowOnceUnlockCode(in: stderr))
        let whyRest = why.hasPrefix("RV · Blocked. ")
            ? String(why.dropFirst("RV · Blocked. ".count))
            : why
        let expected = "RV · Blocked. \(hookUnlockNext(code: code)) \(whyRest)"
        #expect(outcome.exitCode == 2)
        #expect(outcome.stdout.contains("\"decision\":\"block\""))
        #expect(stderr == expected)
        #expect(outcome.stdout.contains(expected))
        #expect(why.isEmpty == false)
    }

    @Test func hookEvaluateIsOneSendWhenClientSemverIsSet_budgetIsConnect200PlusRequest500Equals700Ms() async throws {
        let denied = EvaluationResult(
            outcome: .deny(
                Deny(
                    ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                    reason: "git reset --hard destroys uncommitted changes"
                ),
                matched: nil
            ),
            matchingView: "git reset --hard"
        )
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", status: .ok),
            responseResult: .evaluate(EvaluateReply(result: denied))
        )
        let client = try isolatedClient(transport: transport)
        let reply = await client.evaluate(command: ShellCommand(rawValue: "git reset --hard"))
        #expect(reply.path == .xpc)
        try #require(denyPayload(from: reply.result.decision) != nil)
        #expect(transport.sendCount == 1)
        #expect(transport.helloCount == 0)
        #expect(transport.lastSendTimeoutMs == 700)

        let sent = try #require(transport.sends.first)
        let request = try IPCJSON.decode(IPCRequest.self, from: sent)
        guard case .evaluate(let params) = request.method else {
            Issue.record("one-shot body must be evaluate")
            return
        }
        #expect(params.clientSemver == ProtocolVersion.serviceSemver)

#if canImport(XPC)
        let defaults = XPCServiceTransport()
        #expect(defaults.connectTimeoutMs == 200)
        #expect(defaults.requestTimeoutMs == 500)
        #expect(defaults.oneShotEvaluateTimeoutMs == 700)
#endif
    }

    @Test func skewedImplicitHelloFallsBackInProcessAndStillDeniesResetHard() async throws {
        let transport = ScriptedTransport(
            ack: HelloAckView(
                protocolName: "rv.ipc.v1",
                serviceSemver: "1.0.0",
                status: .ok
            ),
            responseResult: .error(.protocolSkew(.protocolSkew))
        )
        let client = try isolatedClient(transport: transport)
        let reply = await client.evaluate(command: ShellCommand(rawValue: "git reset --hard"))
        let deny = try #require(denyPayload(from: reply.result.decision))
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
        #expect(reply.path == .inProcess)
        #expect(transport.sendCount == 1)
        #expect(transport.helloCount == 0)
        #expect(transport.invalidationCount == 1)
    }

    @Test func downListenerFallsBackInProcessAndStillDeniesResetHard() async throws {
        let client = try isolatedClient(transport: nil)
        let reply = await client.evaluate(command: ShellCommand(rawValue: "git reset --hard"))
        let deny = try #require(denyPayload(from: reply.result.decision))
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
        #expect(reply.path == .inProcess)
    }

    @Test func oneShotXPCStashDrop_isEmptyAllowOnHookCodec() async throws {
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", status: .ok),
            responseResult: .hookEvaluate(HookEvaluateReply(stdout: "", exitCode: 0))
        )
        let client = try isolatedClient(transport: transport)
        var hook = Hook()
        hook.host = .grok
        let outcome = await hook.run(
            stdin: try grokHookFixture("allow-medium-stash-drop.json"),
            client: client
        )
        #expect(outcome.stdout.isEmpty)
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.contains("deny") == false)
        let sent = try #require(transport.sends.first)
        let request = try IPCJSON.decode(IPCRequest.self, from: sent)
        guard case .hookEvaluate = request.method else {
            Issue.record("production stash-drop path must send hookEvaluate, not evaluate")
            return
        }
        #expect(transport.sendCount == 1)
        #expect(transport.helloCount == 0)
    }

    @Test func statusAndDiagnosticsStillHelloFirst() async throws {
        let snapshot = DoctorSnapshotReply(
            state: .running,
            idleExitSeconds: 300,
            packsEnabled: [.coreGit, .coreFilesystem],
            checks: [DoctorCheck(id: .xpc, status: .ok, message: "listener")]
        )
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", status: .ok),
            responseResult: .doctorSnapshot(snapshot)
        )
        let client = try isolatedClient(transport: transport)
        _ = await client.status()
        #expect(transport.helloCount == 1)
        #expect(transport.sendCount == 1)
    }

    private func grokHookFixture(_ name: String) throws -> String {
        try hookFixture("grok", name)
    }

    private func hookFixture(_ host: String, _ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("RVHooksTests/Fixtures/\(host)/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func spoofedHookEvaluateResponse(via: String, stdout: String, exitCode: Int32) throws -> Data {
        let valid = try IPCJSON.encode(
            IPCResponse(
                id: UUID(),
                result: .hookEvaluate(HookEvaluateReply(stdout: stdout, exitCode: exitCode))
            )
        )
        var object = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var resultObject = try #require(object["result"] as? [String: Any])
        var hookEvaluate = try #require(resultObject["hookEvaluate"] as? [String: Any])
        hookEvaluate["via"] = via
        resultObject["hookEvaluate"] = hookEvaluate
        object["result"] = resultObject
        return try JSONSerialization.data(withJSONObject: object)
    }
}
