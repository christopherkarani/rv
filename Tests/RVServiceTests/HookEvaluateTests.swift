import Foundation
import Testing
import RVDomain
import RVEngine
import RVPolicy
import RVIPC
@preconcurrency import XPC
@testable import RVService

private let canonicalResetHardDeny =
    "Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once."

struct HookEvaluateTests {
    @Test func implicitHello_grokResetHardReturnsCanonicalDenyWire() async throws {
        let runtime = try isolatedRuntime()
        let stdin = try grokFixture("deny-git-reset-hard.json")
        let (data, ok) = await runtime.handleIncoming(
            try hookEvaluateBody(host: .grok, stdin: stdin, clientSemver: ProtocolVersion.serviceSemver),
            handshakeOK: false
        )
        #expect(ok == true)
        let response = try IPCJSON.decode(IPCResponse.self, from: data)
        guard case .hookEvaluate(let reply) = response.result else {
            Issue.record("implicit hello hookEvaluate must dispatch")
            return
        }
        #expect(reply.via == .xpc)
        #expect(reply.serviceSemver == ProtocolVersion.serviceSemver)
        #expect(reply.exitCode == 0)
        let json = try grokDenyJSON(reply.stdout)
        #expect(json["decision"] as? String == "deny")
        #expect(json["reason"] as? String == canonicalResetHardDeny)
    }

    /// Warm-rvd hook evaluation must resolve packs through the same door as
    /// the rv-cli miss path (`EnabledPacks.resolve`), never a hardcoded
    /// day-one set: a config that disables `core.git` must allow here, or
    /// warm and cold rvd would decide the same command differently.
    @Test func hookEvaluate_resolvesPacksFromConfig_notDayOne() async throws {
        let home = try isolatedHomeDirectory()
        let configDir = home.appendingPathComponent(".config/rv", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try Data("[packs]\ndisabled = [\"core.git\"]\n".utf8)
            .write(to: configDir.appendingPathComponent("config.toml"))
        let runtime = try isolatedRuntime(home: HomeDirectory(validating: home.path))

        let stdin = try grokFixture("deny-git-reset-hard.json")
        let (data, ok) = await runtime.handleIncoming(
            try hookEvaluateBody(host: .grok, stdin: stdin, clientSemver: ProtocolVersion.serviceSemver),
            handshakeOK: false
        )
        #expect(ok == true)
        let response = try IPCJSON.decode(IPCResponse.self, from: data)
        guard case .hookEvaluate(let reply) = response.result else {
            Issue.record("config-resolved hookEvaluate must dispatch")
            return
        }
        // core.git disabled by readable config => no rule matches => allow.
        // The day-one-hardcoded path would deny; this assertion fails there.
        #expect(reply.stdout.isEmpty)
        #expect(reply.exitCode == 0)
    }

    @Test func majorSemver_doesNotEvaluate() async throws {
        let runtime = try isolatedRuntime()
        let stdin = try grokFixture("deny-git-reset-hard.json")
        let (data, ok) = await runtime.handleIncoming(
            try hookEvaluateBody(host: .grok, stdin: stdin, clientSemver: "2.0.0"),
            handshakeOK: false
        )
        #expect(ok == false)
        let response = try IPCJSON.decode(IPCResponse.self, from: data)
        guard case .error(.protocolSkew(let reason)) = response.result else {
            Issue.record("major semver skew must error, not evaluate")
            return
        }
        #expect(reason == .majorVersion)
        if case .hookEvaluate = response.result {
            Issue.record("do not evaluate hookEvaluate against a major-skewed listener")
        }
    }

    @Test func missingClientSemverAndNoHello_isHandshakeRequired() async throws {
        let runtime = try isolatedRuntime()
        let stdin = try grokFixture("deny-git-reset-hard.json")
        let (data, ok) = await runtime.handleIncoming(
            try hookEvaluateBody(host: .grok, stdin: stdin),
            handshakeOK: false
        )
        #expect(ok == false)
        let response = try IPCJSON.decode(IPCResponse.self, from: data)
        guard case .error(.handshakeRequired) = response.result else {
            Issue.record("hookEvaluate without clientSemver must stay handshake required")
            return
        }
        if case .hookEvaluate = response.result {
            Issue.record("handshake-required must not evaluate")
        }
    }

    @Test func grokStashDrop_emptyStdout() async throws {
        let runtime = try isolatedRuntime()
        let stdin = try grokFixture("allow-medium-stash-drop.json")
        let (data, ok) = await runtime.handleIncoming(
            try hookEvaluateBody(host: .grok, stdin: stdin, clientSemver: ProtocolVersion.serviceSemver),
            handshakeOK: false
        )
        #expect(ok == true)
        let response = try IPCJSON.decode(IPCResponse.self, from: data)
        guard case .hookEvaluate(let reply) = response.result else {
            Issue.record("stash drop must dispatch hookEvaluate")
            return
        }
        #expect(reply.via == .xpc)
        #expect(reply.stdout.isEmpty)
        #expect(reply.exitCode == 0)
    }

    @Test func unknownHost_failsDecodeAsDecodeFailedAndDoesNotEvaluate() async throws {
        let runtime = try isolatedRuntime()
        let frame = String(
            data: try IPCJSON.encode(
                IPCRequest(
                    method: .hookEvaluate(
                        HookEvaluateParams(
                            host: .grok,
                            stdin: try grokFixture("deny-git-reset-hard.json"),
                            clientSemver: ProtocolVersion.serviceSemver
                        )
                    )
                )
            ),
            encoding: .utf8
        )
        let hostile = try #require(frame.map {
            $0.replacingOccurrences(of: "\"host\":\"grok\"", with: "\"host\":\"nope\"")
        })
        let (data, ok) = await runtime.handleIncoming(Data(hostile.utf8), handshakeOK: true)
        #expect(ok == true)
        let response = try IPCJSON.decode(IPCResponse.self, from: data)
        guard case .error(.decodeFailed) = response.result else {
            Issue.record("unknown host on the wire must fail decode")
            return
        }
        if case .hookEvaluate = response.result {
            Issue.record("unknown host must not return hookEvaluate")
        }
    }

    @Test func oldEvaluate_stillWorksAfterHookEvaluate() async throws {
        let runtime = try isolatedRuntime()
        let hook = await runtime.handleIncoming(
            try hookEvaluateBody(
                host: .grok,
                stdin: try grokFixture("allow-medium-stash-drop.json"),
                clientSemver: ProtocolVersion.serviceSemver
            ),
            handshakeOK: false
        )
        #expect(hook.1 == true)

        let (data, ok) = await runtime.handleIncoming(
            try evaluateBody(command: "git reset --hard", clientSemver: ProtocolVersion.serviceSemver),
            handshakeOK: hook.1
        )
        #expect(ok == true)
        let response = try IPCJSON.decode(IPCResponse.self, from: data)
        guard case .evaluate(let reply) = response.result else {
            Issue.record("old evaluate must still dispatch (additive)")
            return
        }
        guard case .deny(let deny) = reply.result.decision else {
            Issue.record("old evaluate must still deny git reset --hard")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
        #expect(reply.via == .xpc)
    }

    @Test func hookEvaluate_doesNotLogCommandText() async throws {
        let log = RecordingLog()
        let runtime = try isolatedRuntime(log: log)
        _ = await runtime.handleIncoming(
            try hookEvaluateBody(
                host: .grok,
                stdin: try grokFixture("deny-git-reset-hard.json"),
                clientSemver: ProtocolVersion.serviceSemver
            ),
            handshakeOK: false
        )
        let blob = log.snapshot.map { "\($0.method)|\($0.decision ?? "")|\($0.ruleID ?? "")" }.joined()
        #expect(blob.contains("hookEvaluate"))
        #expect(blob.contains("git reset") == false)
        #expect(blob.contains("reset-hard") == false)
        #expect(blob.contains("/tmp/rv-hook-fixture") == false)
    }

    @Test func emptyStdin_isEmptyAllow() async throws {
        let probe = EvaluateCallProbe()
        let reply = try await HookDoor.run(host: .grok, stdin: "") { command, cwd in
            await probe.evaluate(command, cwd: cwd)
        }
        #expect(probe.calls == 0)
        #expect(reply.stdout.isEmpty)
        #expect(reply.exitCode == 0)
        #expect(reply.via == .xpc)
    }

    @Test func xpcIPCFrame_roundTripsJSONData() {
        let payload = Data("{\"decision\":\"deny\"}".utf8)
        let dictionary = xpc_dictionary_create_empty()
        XPCIPCWire.set(payload, on: dictionary)
        #expect(XPCIPCWire.key == "rv.ipc")
        #expect(XPCIPCWire.body(from: dictionary) == payload)
    }
}

private final class EvaluateCallProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var calls: Int { lock.withLock { count } }

    func evaluate(_ command: ShellCommand, cwd: String?) async -> EvaluationResult {
        _ = command
        _ = cwd
        lock.withLock { count += 1 }
        return EvaluationResult(
            outcome: .plain,
            matchingView: Normalize.matchingView(of: command.rawValue)
        )
    }
}

private func grokFixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("RVHooksTests/Fixtures/grok/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

private func grokDenyJSON(_ stdout: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(stdout.utf8))
    return try #require(object as? [String: Any])
}

private func hookEvaluateBody(
    host: HookHost,
    stdin: String,
    clientSemver: String? = nil,
    protocolName: String = ProtocolVersion.name
) throws -> Data {
    try IPCJSON.encode(
        IPCRequest(
            protocolName: protocolName,
            method: .hookEvaluate(
                HookEvaluateParams(host: host, stdin: stdin, clientSemver: clientSemver)
            )
        )
    )
}

private func evaluateBody(
    command: String,
    clientSemver: String? = nil
) throws -> Data {
    try IPCJSON.encode(
        IPCRequest(
            method: .evaluate(
                EvaluateParams(
                    request: EvaluationRequest(
                        command: ShellCommand(rawValue: command),
                        enabledPacks: dayOnePackIDs
                    ),
                    clientSemver: clientSemver
                )
            )
        )
    )
}
