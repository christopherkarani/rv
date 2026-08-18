import Foundation
import Testing
import RVDomain
@testable import RVIPC

struct EnvelopeRoundTripTests {
    @Test func methodRoundTrips() throws {
        for sample in IPCMethod.allSamples {
            let request = IPCRequest(id: sample.id, method: sample.method)
            let data = try IPCJSON.encode(request)
            let decoded = try IPCJSON.decode(IPCRequest.self, from: data)
            #expect(decoded == request)

            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["protocol"] as? String == ProtocolVersion.name)
            let method = try #require(object["method"] as? [String: Any])
            #expect(method[sample.key] != nil)
            #expect(String(data: data, encoding: .utf8)?.contains("isDenied") == false)
        }
    }

    @Test func resultRoundTrips() throws {
        for sample in IPCResult.allSamples {
            let response = IPCResponse(id: sample.id, result: sample.result)
            let data = try IPCJSON.encode(response)
            let decoded = try IPCJSON.decode(IPCResponse.self, from: data)
            #expect(decoded == response)

            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let result = try #require(object["result"] as? [String: Any])
            #expect(result[sample.key] != nil)
        }
    }

    @Test func helloRoundTrips() throws {
        let hello = Hello(protocolName: ProtocolVersion.name, clientSemver: "1.2.3")
        let ack = HelloAck(ok: true)
        #expect(try IPCJSON.decode(Hello.self, from: IPCJSON.encode(hello)) == hello)
        #expect(try IPCJSON.decode(HelloAck.self, from: IPCJSON.encode(ack)) == ack)
    }

    @Test func denyDecisionKeepsRulePayload() throws {
        let deny = Decision.deny(
            Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "destroys uncommitted changes")
        )
        let data = try IPCJSON.encode(deny)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["decision"] as? String == "deny")
        #expect(object["ruleID"] as? String == "core.git:reset-hard")
        #expect(object["reason"] as? String == "destroys uncommitted changes")
        #expect(try IPCJSON.decode(Decision.self, from: data) == deny)
    }

    @Test func indeterminateDoesNotBecomeAllow() throws {
        let value = Decision.indeterminate(.corePacksUnavailable)
        let decoded = try IPCJSON.decode(Decision.self, from: IPCJSON.encode(value))
        #expect(decoded == value)
        if case .allow = decoded {
            Issue.record("indeterminate must not decode as allow")
        }
    }
}

struct NamedMethod: Sendable {
    var key: String
    var id: UUID
    var method: IPCMethod
}

struct NamedResult: Sendable {
    var key: String
    var id: UUID
    var result: IPCResult
}

extension IPCMethod {
    static var allSamples: [NamedMethod] {
        let id = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let request = EvaluationRequest(
            command: ShellCommand(rawValue: "git reset --hard"),
            enabledPacks: dayOnePackIDs
        )
        return [
            NamedMethod(key: "evaluate", id: id, method: .evaluate(EvaluateParams(request: request))),
            NamedMethod(key: "explain", id: id, method: .explain(ExplainParams(request: request))),
            NamedMethod(key: "classify", id: id, method: .classify(ClassifyParams(request: request))),
            NamedMethod(key: "listPacks", id: id, method: .listPacks),
            NamedMethod(
                key: "setPackEnabled",
                id: id,
                method: .setPackEnabled(SetPackEnabledParams(id: .coreGit, enabled: true))
            ),
            NamedMethod(
                key: "allowOnceConsume",
                id: id,
                method: .allowOnceConsume(AllowOnceConsumeParams(command: "git reset --hard", cwd: "/tmp/ws"))
            ),
            NamedMethod(key: "doctorSnapshot", id: id, method: .doctorSnapshot),
        ]
    }
}

extension IPCResult {
    static var allSamples: [NamedResult] {
        let id = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let deny = EvaluationResult(
            decision: .deny(
                Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "destroys uncommitted changes")
            )
        )
        return [
            NamedResult(key: "evaluate", id: id, result: .evaluate(EvaluateReply(result: deny, via: "xpc"))),
            NamedResult(
                key: "explain",
                id: id,
                result: .explain(
                    ExplainReply(
                        result: deny,
                        normalized: "git reset --hard",
                        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                        packID: .coreGit,
                        suggestion: "Run it in Terminal, or rv allow-once.",
                        stages: [ExplainStage(name: "normalize", elapsedMs: 0.1)]
                    )
                )
            ),
            NamedResult(
                key: "classify",
                id: id,
                result: .classify(
                    ClassifyReply(
                        decision: deny.decision,
                        risk: .critical,
                        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                        packID: .coreGit
                    )
                )
            ),
            NamedResult(
                key: "listPacks",
                id: id,
                result: .listPacks(
                    ListPacksReply(
                        packs: [PackRecord(id: .coreGit, enabled: true, bundled: true)],
                        enabledCount: 1,
                        totalCount: 1
                    )
                )
            ),
            NamedResult(
                key: "setPackEnabled",
                id: id,
                result: .setPackEnabled(
                    SetPackEnabledReply(pack: PackRecord(id: .coreGit, enabled: false, bundled: true))
                )
            ),
            NamedResult(
                key: "allowOnceConsume",
                id: id,
                result: .allowOnceConsume(AllowOnceConsumeReply(consumed: true, tokenID: "tok-1"))
            ),
            NamedResult(
                key: "doctorSnapshot",
                id: id,
                result: .doctorSnapshot(
                    DoctorSnapshotReply(
                        state: .running,
                        idleExitSeconds: 300,
                        packsEnabled: [.coreGit],
                        checks: [DoctorCheck(id: "xpc", status: .ok, message: "listener")]
                    )
                )
            ),
            NamedResult(
                key: "error",
                id: id,
                result: .error(.packNotFound(PackID(rawValue: "core.unknown")))
            ),
        ]
    }
}
