#if canImport(Darwin)
import Foundation
import Testing
import RVDomain
import RVIPC
@testable import RVService

@Suite(.serialized)
struct FakeXPCUnixSocketTests {
    @Test func oneShotEvaluateWithoutPriorHello_isDenied() async throws {
        let runtime = try isolatedRuntime()
        let path = "/tmp/rv-t14-\(UUID().uuidString).sock"
        let server = FakeXPCServer(runtime: runtime, path: path)
        try server.start()
        defer { server.stop() }

        let client = try retryConnect(path: path)
        defer { client.close() }

        let reply = try client.sendJSON(
            evaluateJSON("git reset --hard", clientSemver: ProtocolVersion.serviceSemver)
        )
        let result = try #require(reply["result"] as? [String: Any])
        let error = try #require(result["error"] as? [String: Any])
        #expect(error["authorizationDenied"] as? Bool == true)
        #expect(result["evaluate"] == nil)
    }

    @Test func handshakeAndEvaluate_isDenied() async throws {
        let runtime = try isolatedRuntime()
        let path = "/tmp/rv-t3-\(UUID().uuidString).sock"
        let server = FakeXPCServer(runtime: runtime, path: path)
        try server.start()
        defer { server.stop() }

        let client = try retryConnect(path: path)
        defer { client.close() }

        let ack = try client.hello()
        #expect(ack["ok"] as? Bool == true)
        #expect(ack["protocol"] as? String == "rv.ipc.v1")

        let reply = try client.sendJSON(evaluateJSON("git reset --hard"))
        let result = try #require(reply["result"] as? [String: Any])
        let error = try #require(result["error"] as? [String: Any])
        #expect(error["authorizationDenied"] as? Bool == true)
        #expect(result["evaluate"] == nil)
    }

    @Test func handshakeAndEvaluateGitStatus_isDenied() async throws {
        let runtime = try isolatedRuntime()
        let path = "/tmp/rv-t3-\(UUID().uuidString).sock"
        let server = FakeXPCServer(runtime: runtime, path: path)
        try server.start()
        defer { server.stop() }
        let client = try retryConnect(path: path)
        defer { client.close() }
        #expect(try client.hello()["ok"] as? Bool == true)
        let reply = try client.sendJSON(evaluateJSON("git status"))
        let error = nested(reply, ["result", "error"])
        #expect(error?["authorizationDenied"] as? Bool == true)
        #expect(nested(reply, ["result", "evaluate"]) == nil)
    }

    @Test func remainingMethodsRoundTripOnSocket() async throws {
        let runtime = try isolatedRuntime()
        let path = "/tmp/rv-t3-\(UUID().uuidString).sock"
        let server = FakeXPCServer(runtime: runtime, path: path)
        try server.start()
        defer { server.stop() }
        let client = try retryConnect(path: path)
        defer { client.close() }
        #expect(try client.hello()["ok"] as? Bool == true)

        let requests: [[String: Any]] = [
            methodJSON("explain", ["request": requestObject("git status")]),
            methodJSON("classify", ["request": requestObject("git reset --hard")]),
            methodJSON("listPacks", [:] as [String: Any]),
            methodJSON("doctorSnapshot", [:] as [String: Any]),
        ]
        let keys = ["explain", "classify", "listPacks", "doctorSnapshot"]
        for (request, key) in zip(requests, keys) {
            let reply = try client.sendJSON(request)
            let result = try #require(reply["result"] as? [String: Any])
            #expect(result[key] != nil, "missing result key \(key)")
        }
        // Step 8: grant-spending evaluate and owner-mutating
        // setPackEnabled stay denied for socket callers.
        for request in [
            evaluateJSON("git status"),
            methodJSON("setPackEnabled", ["id": "core.git", "enabled": true]),
        ] {
            let reply = try client.sendJSON(request)
            let result = try #require(reply["result"] as? [String: Any])
            let error = try #require(result["error"] as? [String: Any])
            #expect(error["authorizationDenied"] as? Bool == true)
        }
    }

    @Test func listPacksIncludesDayOneEnabled() async throws {
        let runtime = try isolatedRuntime()
        let path = "/tmp/rv-t3-\(UUID().uuidString).sock"
        let server = FakeXPCServer(runtime: runtime, path: path)
        try server.start()
        defer { server.stop() }
        let client = try retryConnect(path: path)
        defer { client.close() }
        _ = try client.hello()
        let reply = try client.sendJSON(methodJSON("listPacks", [:] as [String: Any]))
        let list = try #require(nested(reply, ["result", "listPacks"]))
        #expect(list["enabledCount"] as? Int == dayOnePackIDs.count)
        let packs = try #require(list["packs"] as? [[String: Any]])
        let ids = Set(packs.compactMap { $0["id"] as? String })
        #expect(ids.contains("core.git"))
        #expect(ids.contains("core.filesystem"))
        #expect(ids.contains("system.disk"))
    }

    @Test func unknownPackDeniedBeforeLookup() async throws {
        let runtime = try isolatedRuntime()
        let path = "/tmp/rv-t3-\(UUID().uuidString).sock"
        let server = FakeXPCServer(runtime: runtime, path: path)
        try server.start()
        defer { server.stop() }
        let client = try retryConnect(path: path)
        defer { client.close() }
        _ = try client.hello()
        let reply = try client.sendJSON(
            methodJSON("setPackEnabled", ["id": "core.unknown", "enabled": false])
        )
        let error = try #require(nested(reply, ["result", "error"]))
        #expect(error["authorizationDenied"] as? Bool == true)
        #expect(error["packNotFound"] == nil)
    }

    @Test func allowOnceConsumeIsUnknownMethod() async throws {
        let runtime = try isolatedRuntime()
        let path = "/tmp/rv-t3-\(UUID().uuidString).sock"
        let server = FakeXPCServer(runtime: runtime, path: path)
        try server.start()
        defer { server.stop() }
        let client = try retryConnect(path: path)
        defer { client.close() }
        _ = try client.hello()

        let first = try client.sendJSON(
            methodJSON("allowOnceConsume", ["command": "git reset --hard", "cwd": "/tmp/ws"])
        )
        #expect(nested(first, ["result", "error"])?["decodeFailed"] as? Bool == true)
        #expect(nested(first, ["result", "allowOnceConsume"]) == nil)

        let second = try client.sendJSON(
            methodJSON("allowOnceConsume", ["command": "git reset --hard", "cwd": "/tmp/ws"])
        )
        #expect(nested(second, ["result", "error"])?["decodeFailed"] as? Bool == true)
        #expect(nested(second, ["result", "allowOnceConsume"]) == nil)
    }

    @Test func doctorSnapshotSkipsHostChecks() async throws {
        let runtime = try isolatedRuntime()
        let path = "/tmp/rv-t3-\(UUID().uuidString).sock"
        let server = FakeXPCServer(runtime: runtime, path: path)
        try server.start()
        defer { server.stop() }
        let client = try retryConnect(path: path)
        defer { client.close() }
        _ = try client.hello()
        let reply = try client.sendJSON(methodJSON("doctorSnapshot", [:] as [String: Any]))
        let snap = try #require(nested(reply, ["result", "doctorSnapshot"]))
        #expect(snap["keepAlive"] as? Bool == false)
        #expect(snap["idleExitSeconds"] as? Int == 300)
        let checks = try #require(snap["checks"] as? [[String: Any]])
        let ids = checks.compactMap { $0["id"] as? String }
        #expect(ids.contains("xpc"))
        #expect(ids.contains("protocol"))
        #expect(ids.contains("packs"))
        #expect(ids.contains("launchd"))
        for host in ["pi", "grok", "opencode"] {
            let check = try #require(checks.first { $0["id"] as? String == host })
            #expect(check["status"] as? String == "skipped")
            #expect(check["message"] as? String == "T7")
        }
    }

    @Test func uncompilableResetHardIsNotOkAndDoesNotAllow() async throws {
        let runtime = try isolatedRuntime(snapshots: BrokenCoreSnapshots.uncompilableResetHard())
        #expect(await runtime.corePacksReady == false)
        let path = "/tmp/rv-t3-\(UUID().uuidString).sock"
        let server = FakeXPCServer(runtime: runtime, path: path)
        try server.start()
        defer { server.stop() }
        let client = try retryConnect(path: path)
        defer { client.close() }
        let ack = try client.hello()
        #expect(ack["ok"] as? Bool == false)

        let body = Data(
            """
            {"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","protocol":"rv.ipc.v1","method":{"evaluate":{"request":{"command":"git reset --hard","enabledPacks":["core.filesystem","core.git"]}}}}
            """.utf8
        )
        let incoming = await runtime.handleIncoming(body, handshakeOK: true)
        let replyData = incoming.frame
        let object = try #require(JSONSerialization.jsonObject(with: replyData) as? [String: Any])
        let error = nested(object, ["result", "error"])
        #expect(error?["authorizationDenied"] as? Bool == true)
        #expect(nested(object, ["result", "evaluate"]) == nil)
    }

    @Test func emptyCoreHandshakeIsNotOk() async throws {
        let runtime = try isolatedRuntime(snapshots: [])
        let path = "/tmp/rv-t3-\(UUID().uuidString).sock"
        let server = FakeXPCServer(runtime: runtime, path: path)
        try server.start()
        defer { server.stop() }
        let client = try retryConnect(path: path)
        defer { client.close() }
        let ack = try client.hello()
        #expect(ack["ok"] as? Bool == false)
        #expect(ack["skewReason"] as? String == "core packs unavailable")
    }

    @Test func evaluateDoesNotLogCommandText() async throws {
        let log = RecordingLog()
        let runtime = try isolatedRuntime(log: log)
        let request = Data(
            """
            {"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","protocol":"rv.ipc.v1","method":{"evaluate":{"request":{"command":"rm -rf /Users/me","enabledPacks":["core.filesystem","core.git"]}}}}
            """.utf8
        )
        _ = await runtime.handleIncoming(request, handshakeOK: true)
        let blob = log.snapshot.map { "\($0.method)|\($0.decision ?? "")|\($0.ruleID ?? "")" }.joined()
        #expect(blob.isEmpty)
    }
}

private func evaluateJSON(
    _ command: String,
    cwd: WorkingDirectory? = nil,
    clientSemver: String? = nil
) -> [String: Any] {
    var params: [String: Any] = ["request": requestObject(command)]
    if let cwd {
        params["cwd"] = cwd.rawValue
    }
    if let clientSemver {
        params["clientSemver"] = clientSemver
    }
    return methodJSON("evaluate", params)
}

private func requestObject(_ command: String) -> [String: Any] {
    [
        "command": command,
        "enabledPacks": ["core.filesystem", "core.git"],
    ]
}

private func methodJSON(_ name: String, _ params: [String: Any]) -> [String: Any] {
    [
        "id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        "protocol": "rv.ipc.v1",
        "method": [name: params],
    ]
}

private func nested(_ root: [String: Any], _ path: [String]) -> [String: Any]? {
    var current: Any = root
    for key in path {
        guard let object = current as? [String: Any], let next = object[key] else {
            return nil
        }
        current = next
    }
    return current as? [String: Any]
}
#endif

