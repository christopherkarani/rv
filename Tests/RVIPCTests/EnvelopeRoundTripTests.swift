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

    @Test func evaluateViaRoundTripsAsXpcAndRejectsOtherPaths() throws {
        let reply = EvaluateReply(result: EvaluationResult(outcome: .plain))
        let data = try IPCJSON.encode(reply)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["via"] as? String == "xpc")
        #expect(try IPCJSON.decode(EvaluateReply.self, from: data).via == .xpc)
        #expect(try IPCJSON.decode(EvaluateReply.self, from: data).serviceSemver == ProtocolVersion.serviceSemver)

        for badVia in ["inProcess", "bogus"] {
            var spoofed = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            spoofed["via"] = badVia
            let bad = try JSONSerialization.data(withJSONObject: spoofed)
            #expect(throws: DecodingError.self) {
                try IPCJSON.decode(EvaluateReply.self, from: bad)
            }
        }
    }

    @Test func evaluateReplyServiceSemver_isAdditiveOptionalOnV1() throws {
        let data = try IPCJSON.encode(EvaluateReply(result: EvaluationResult(outcome: .plain)))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "serviceSemver")
        let omitted = try JSONSerialization.data(withJSONObject: object)
        let decoded = try IPCJSON.decode(EvaluateReply.self, from: omitted)
        #expect(decoded.via == .xpc)
        #expect(decoded.serviceSemver == nil)
    }

    @Test func evaluateParamsClientSemver_isAdditiveOptionalOnV1() throws {
        let request = EvaluationRequest(
            command: ShellCommand(rawValue: "git reset --hard"),
            enabledPacks: dayOnePackIDs
        )
        let omitted = try IPCJSON.encode(EvaluateParams(request: request, cwd: "/tmp/ws"))
        let omittedObject = try #require(JSONSerialization.jsonObject(with: omitted) as? [String: Any])
        #expect(omittedObject["clientSemver"] == nil)
        #expect(try IPCJSON.decode(EvaluateParams.self, from: omitted).clientSemver == nil)

        let oldShape = try JSONSerialization.data(withJSONObject: [
            "request": [
                "command": "git reset --hard",
                "enabledPacks": ["core.filesystem", "core.git"],
            ],
            "cwd": "/tmp/ws",
        ])
        #expect(try IPCJSON.decode(EvaluateParams.self, from: oldShape).clientSemver == nil)

        let withSemver = EvaluateParams(
            request: request,
            cwd: "/tmp/ws",
            clientSemver: ProtocolVersion.serviceSemver
        )
        let encoded = try IPCJSON.encode(withSemver)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["clientSemver"] as? String == ProtocolVersion.serviceSemver)
        #expect(try IPCJSON.decode(EvaluateParams.self, from: encoded) == withSemver)
        #expect(ProtocolVersion.name == "rv.ipc.v1")
    }

    @Test func classifyRiskRoundTripsAllFiveWireStrings() throws {
        let samples: [(string: String, risk: ClassifyRisk)] = [
            ("safe", .safe),
            ("low", .rated(.low)),
            ("medium", .rated(.medium)),
            ("high", .rated(.high)),
            ("critical", .rated(.critical)),
        ]
        for sample in samples {
            let encoded = try IPCJSON.encode(sample.risk)
            #expect(String(data: encoded, encoding: .utf8) == "\"\(sample.string)\"")
            let decoded = try IPCJSON.decode(ClassifyRisk.self, from: encoded)
            #expect(decoded == sample.risk)
            let legacy = Data("\"\(sample.string)\"".utf8)
            #expect(try IPCJSON.decode(ClassifyRisk.self, from: legacy) == sample.risk)
        }
    }

    @Test func classifyRiskRejectsUnknownStringsAsDataCorrupted() throws {
        for bad in ["bogus", "Safe", "severe", ""] {
            let payload = try JSONEncoder().encode(bad)
            do {
                _ = try IPCJSON.decode(ClassifyRisk.self, from: payload)
                Issue.record("unknown ClassifyRisk string must not decode")
            } catch let error as DecodingError {
                guard case .dataCorrupted = error else {
                    Issue.record("expected dataCorrupted, got \(error)")
                    return
                }
            }
        }
    }

    @Test func classifyRiskDeriveMatchesTruthTable() {
        let severities: [Severity] = [.low, .medium, .high, .critical]
        let match = RuleMatch(
            ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
            packID: .coreGit,
            patternName: "reset-hard",
            severity: .high,
            reason: "destroys uncommitted changes"
        )
        for severity in severities {
            let matched = RuleMatch(
                ruleID: match.ruleID,
                packID: match.packID,
                patternName: match.patternName,
                severity: severity,
                reason: match.reason
            )
            #expect(
                ClassifyRisk.derive(decision: .allow, matched: matched) == .rated(severity)
            )
            #expect(
                ClassifyRisk.derive(decision: .deny(Deny(ruleID: match.ruleID, reason: match.reason)), matched: matched)
                    == .rated(severity)
            )
        }
        #expect(ClassifyRisk.derive(decision: .allow, matched: nil) == .safe)
        #expect(
            ClassifyRisk.derive(decision: .deny(Deny(ruleID: match.ruleID, reason: match.reason)), matched: nil)
                == .rated(.high)
        )
        #expect(ClassifyRisk.derive(decision: .indeterminate(.corePacksUnavailable), matched: nil) == .rated(.high))
        #expect(
            ClassifyRisk.derive(decision: .indeterminate(.budgetExhausted), matched: match) == .rated(.high)
        )
    }

    @Test func emptyCwdOnHonorParamsIsNil() throws {
        let request = EvaluationRequest(
            command: ShellCommand(rawValue: "git reset --hard"),
            enabledPacks: dayOnePackIDs
        )
        #expect(EvaluateParams(request: request, cwd: "").cwd == nil)
        #expect(ExplainParams(request: request, cwd: "").cwd == nil)
        #expect(ClassifyParams(request: request, cwd: "").cwd == nil)

        let payload = try IPCJSON.encode(EvaluateParams(request: request, cwd: "/tmp/ws"))
        var object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        object["cwd"] = ""
        let emptied = try JSONSerialization.data(withJSONObject: object)
        let decoded = try IPCJSON.decode(EvaluateParams.self, from: emptied)
        #expect(decoded.cwd == nil)
        #expect(try IPCJSON.decode(ExplainParams.self, from: emptied).cwd == nil)
        #expect(try IPCJSON.decode(ClassifyParams.self, from: emptied).cwd == nil)
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
            outcome: .deny(
                Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "destroys uncommitted changes"),
                matched: nil
            )
        )
        return [
            NamedResult(key: "evaluate", id: id, result: .evaluate(EvaluateReply(result: deny))),
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
                        risk: .rated(.critical),
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
