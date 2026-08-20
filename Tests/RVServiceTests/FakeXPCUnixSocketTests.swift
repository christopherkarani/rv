import Foundation
import Testing
@testable import RVService

@Suite(.serialized)
struct FakeXPCUnixSocketTests {
    @Test func handshakeAndEvaluateDenyResetHard() async throws {
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
        let evaluate = try #require(result["evaluate"] as? [String: Any])
        #expect(evaluate["via"] as? String == "xpc")
        let payload = try #require(evaluate["result"] as? [String: Any])
        let decision = try #require(payload["decision"] as? [String: Any])
        #expect(decision["decision"] as? String == "deny")
        #expect(decision["ruleID"] as? String == "core.git:reset-hard")
    }

    @Test func handshakeAndEvaluateAllowsGitStatus() async throws {
        let runtime = try isolatedRuntime()
        let path = "/tmp/rv-t3-\(UUID().uuidString).sock"
        let server = FakeXPCServer(runtime: runtime, path: path)
        try server.start()
        defer { server.stop() }
        let client = try retryConnect(path: path)
        defer { client.close() }
        #expect(try client.hello()["ok"] as? Bool == true)
        let reply = try client.sendJSON(evaluateJSON("git status"))
        let decision = nested(reply, ["result", "evaluate", "result", "decision"])
        #expect(decision?["decision"] as? String == "allow")
    }

    @Test func allSevenMethodsRoundTripOnSocket() async throws {
        let runtime = try isolatedRuntime()
        let path = "/tmp/rv-t3-\(UUID().uuidString).sock"
        let server = FakeXPCServer(runtime: runtime, path: path)
        try server.start()
        defer { server.stop() }
        let client = try retryConnect(path: path)
        defer { client.close() }
        #expect(try client.hello()["ok"] as? Bool == true)

        let requests: [[String: Any]] = [
            evaluateJSON("git status"),
            methodJSON("explain", ["request": requestObject("git status")]),
            methodJSON("classify", ["request": requestObject("git reset --hard")]),
            methodJSON("listPacks", [:] as [String: Any]),
            methodJSON("setPackEnabled", ["id": "core.git", "enabled": true]),
            methodJSON("allowOnceConsume", ["command": "git status", "cwd": "/tmp/ws"]),
            methodJSON("doctorSnapshot", [:] as [String: Any]),
        ]
        let keys = [
            "evaluate", "explain", "classify", "listPacks",
            "setPackEnabled", "allowOnceConsume", "doctorSnapshot",
        ]
        for (request, key) in zip(requests, keys) {
            let reply = try client.sendJSON(request)
            let result = try #require(reply["result"] as? [String: Any])
            if key == "allowOnceConsume" {
                #expect(result["error"] != nil || result["allowOnceConsume"] != nil)
            } else {
                #expect(result[key] != nil, "missing result key \(key)")
            }
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
        #expect(list["enabledCount"] as? Int == 2)
        let packs = try #require(list["packs"] as? [[String: Any]])
        let ids = Set(packs.compactMap { $0["id"] as? String })
        #expect(ids.contains("core.git"))
        #expect(ids.contains("core.filesystem"))
    }

    @Test func unknownPackIsPackNotFound() async throws {
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
        #expect(error["packNotFound"] as? String == "core.unknown")
    }

    @Test func allowOnceConsumeTwiceThenEvaluateStillRuns() async throws {
        let runtime = try isolatedRuntime()
        try await runtime.insertGranted(matchingView: "git reset --hard", cwd: "/tmp/ws")
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
        #expect(nested(first, ["result", "error"])?["unknownMethod"] as? Bool == true)
        #expect(nested(first, ["result", "allowOnceConsume"]) == nil)

        let second = try client.sendJSON(
            methodJSON("allowOnceConsume", ["command": "git reset --hard", "cwd": "/tmp/ws"])
        )
        #expect(nested(second, ["result", "error"])?["unknownMethod"] as? Bool == true)

        let honored = try client.sendJSON(evaluateJSON("git reset --hard", cwd: "/tmp/ws"))
        let firstDecision = nested(honored, ["result", "evaluate", "result", "decision"])
        #expect(firstDecision?["decision"] as? String == "allow")

        let spent = try client.sendJSON(evaluateJSON("git reset --hard", cwd: "/tmp/ws"))
        let secondDecision = nested(spent, ["result", "evaluate", "result", "decision"])
        #expect(secondDecision?["decision"] as? String == "deny")
        #expect(secondDecision?["ruleID"] as? String == "core.git:reset-hard")
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
        let (replyData, _) = await runtime.handleIncoming(body, handshakeOK: true)
        let object = try #require(JSONSerialization.jsonObject(with: replyData) as? [String: Any])
        let decision = nested(object, ["result", "evaluate", "result", "decision"])
        #expect(decision?["decision"] as? String == "indeterminate")
        #expect(decision?["indeterminateReason"] as? String == "corePacksUnavailable")
        #expect(decision?["decision"] as? String != "allow")
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
        #expect(blob.contains("evaluate"))
        #expect(blob.contains("/Users/me") == false)
        #expect(blob.contains("rm -rf") == false)
    }
}

final class RecordingLog: ServiceLog, @unchecked Sendable {
    nonisolated(unsafe) private var events: [ServiceLogEvent] = []

    func record(_ event: ServiceLogEvent) {
        events.append(event)
    }

    var snapshot: [ServiceLogEvent] { events }
}

private func evaluateJSON(_ command: String, cwd: String = "") -> [String: Any] {
    methodJSON("evaluate", ["request": requestObject(command), "cwd": cwd])
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
