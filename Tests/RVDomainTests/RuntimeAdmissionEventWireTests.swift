import Foundation
import Testing
@testable import RVDomain

/// RuntimeAdmissionEvent is a persisted JSONL evidence row. These goldens pin
/// the exact bytes of every `result` spelling written before the typed enum.
@Suite("RuntimeAdmissionEventWire")
struct RuntimeAdmissionEventWireTests {
    static let wires: [String] = [
        "authorized",
        "exit:0", "exit:-1", "exit:137",
        "http:200", "http:302", "http:503",
        "evaluationFailed",
        "approvalUnavailable", "resumedButChannelGone", "principalRevoked",
        "approvalTimeout", "approvalReplay", "approvalCancelled",
        "approvalExpired", "approvalInvalidated", "approvalFailed", "approvalUnknown",
        "unknownSession", "inactiveSession", "invalidCapability", "impersonation",
        "malformed", "replay", "channelClosed", "principalRequired",
        "unavailable", "compileFailed", "spawnFailed", "notEstablished", "cancelled",
        "forbiddenDestination",
        "redirect", "responseTooLarge", "timedOut", "transport",
        "malformedResponse", "unsupportedTransfer", "tooManyHeaders",
        "mandatoryHuman", "reviewAsk", "hostAsk",
        "core.git:reset-hard",
        "credentialGranted:API_KEY", "credentialUnwired:API_KEY",
        "credentialWithheld:endpointNotApproved",
    ]

    static func golden(_ wire: String) -> String {
        "{\"authorization\":\"allowed\",\"executionAttempted\":true,\"fingerprint\":\"fp\","
            + "\"requestID\":\"req\",\"result\":\"\(wire)\",\"session\":\"sess\"}"
    }

    static func event(_ wire: String) -> RuntimeAdmissionEvent {
        RuntimeAdmissionEvent(
            session: "sess", requestID: "req", fingerprint: "fp",
            authorization: .allowed, executionAttempted: true,
            result: RuntimeAdmissionResult(wire: wire)!
        )
    }

    static func encode(_ event: RuntimeAdmissionEvent) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(event), as: UTF8.self)
    }

    @Test(arguments: wires)
    func encodesByteIdentically(wire: String) throws {
        #expect(try Self.encode(Self.event(wire)) == Self.golden(wire))
    }

    @Test(arguments: wires)
    func existingRowsDecodeAndReencodeUnchanged(wire: String) throws {
        let row = Self.golden(wire)
        let decoded = try JSONDecoder().decode(RuntimeAdmissionEvent.self, from: Data(row.utf8))
        #expect(try Self.encode(decoded) == row)
    }

    @Test func httpRowKeepsEveryFieldByteIdentical() throws {
        var event = Self.event("http:200")
        event.httpMethod = "GET"
        event.httpDestination = "example.com/x"
        event.httpAddress = "93.184.216.34"
        event.httpQueryPresent = false
        event.httpStatus = 200
        event.workspace = "ws"
        event.agentInstance = "inst"
        event.agentDefinition = "def"
        event.recordedAt = 1.5
        let golden =
            "{\"agentDefinition\":\"def\",\"agentInstance\":\"inst\",\"authorization\":\"allowed\","
            + "\"executionAttempted\":true,\"fingerprint\":\"fp\",\"httpAddress\":\"93.184.216.34\","
            + "\"httpDestination\":\"example.com\\/x\",\"httpMethod\":\"GET\",\"httpQueryPresent\":false,"
            + "\"httpStatus\":200,\"recordedAt\":1.5,\"requestID\":\"req\",\"result\":\"http:200\","
            + "\"session\":\"sess\",\"workspace\":\"ws\"}"
        #expect(try Self.encode(event) == golden)
        let decoded = try JSONDecoder().decode(RuntimeAdmissionEvent.self, from: Data(golden.utf8))
        #expect(decoded == event)
    }

    // MARK: Decode ambiguity is wire-stable

    @Test(arguments: ["cancelled", "unavailable"])
    func sharedSpellingsDecodeToExecutorFailedAndReencodeUnchanged(wire: String) throws {
        let result = try #require(RuntimeAdmissionResult(wire: wire))
        guard case .executorFailed = result else {
            Issue.record("expected executorFailed, got \(result)")
            return
        }
        #expect(result.wire == wire)
    }

    @Test func unrecognizedResultFailsToDecode() {
        let row = Self.golden("not a result")
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(RuntimeAdmissionEvent.self, from: Data(row.utf8))
        }
    }

    @Test func typedResultsRoundTripThroughWire() throws {
        let rule = RuleID(pack: .coreGit, pattern: "reset-hard")
        let typed: [RuntimeAdmissionResult] = [
            .authorized, .exit(-1), .exit(0), .http(204), .evaluationFailed,
            .approvalEnded(.timeout), .rejected(.replay), .denied(rule),
            .pending(.reviewAsk), .executorFailed(.spawnFailed),
            .httpNotOpened(.forbiddenDestination), .httpFailed(.redirect),
            .credentialGranted("API_KEY"), .credentialUnwired("API_KEY"),
            .credentialWithheld("credentialMissing"),
        ]
        for result in typed {
            #expect(RuntimeAdmissionResult(wire: result.wire) == result)
        }
    }

    // MARK: Single outcome invariants

    @Test func allowedDecisionOwesExecutionAndHasNoPlaceholderResponse() {
        let fixture = AdmissionFixture()
        var binding: RuntimeChannelBinding? = fixture.binding
        let decision = RuntimeAdmissionGate.submitLegacy(
            binding: &binding, frame: .success(fixture.frame(command: "touch marker"))
        ) { _ in .success(fixture.inside) }
        guard case .execute = decision.outcome else {
            Issue.record("expected execute, got \(decision.outcome)")
            return
        }
        #expect(decision.execute != nil)
        #expect(decision.response == nil)
        #expect(decision.responseDeferred == false)
        #expect(decision.event.authorization == .allowed)
        #expect(decision.event.result == .authorized)
        #expect(decision.event.executionAttempted == false)
    }

    @Test func deniedDecisionDerivesAuthorizationAndResultFromTheAnswer() {
        let fixture = AdmissionFixture()
        var binding: RuntimeChannelBinding? = fixture.binding
        let decision = RuntimeAdmissionGate.submitLegacy(
            binding: &binding, frame: .success(fixture.frame(command: "touch /tmp/outside"))
        ) { _ in .success(fixture.outside) }
        guard case .answer(.denied(let deny)) = decision.outcome else {
            Issue.record("expected denied answer, got \(decision.outcome)")
            return
        }
        #expect(decision.execute == nil)
        #expect(decision.event.authorization == .denied)
        #expect(decision.event.result == .denied(deny.ruleID))
    }

    @Test func pendingAnswerDerivesAuthorizationAndDeferredProjectsPending() {
        let fixture = AdmissionFixture()
        var binding: RuntimeChannelBinding? = fixture.binding
        var decision = RuntimeAdmissionGate.submitLegacy(
            binding: &binding, frame: .success(fixture.frame(command: "echo hello"))
        ) { _ in .success(fixture.uncovered) }
        #expect(decision.outcome == .answer(.pending(.reviewAsk)))
        #expect(decision.event.authorization == .pending)
        #expect(decision.event.result == .pending(.reviewAsk))
        decision.outcome = .deferred(pending: .reviewAsk)
        #expect(decision.responseDeferred)
        #expect(decision.execute == nil)
        #expect(decision.response == .pending(.reviewAsk))
    }

    @Test func rejectionDerivesAuthorizationAndResultFromTheReason() {
        let fixture = AdmissionFixture()
        var binding: RuntimeChannelBinding? = fixture.binding
        let decision = RuntimeAdmissionGate.submitLegacy(
            binding: &binding, frame: .failure(.malformed)
        ) { _ in .failure(.failed) }
        #expect(decision.outcome == .answer(.rejected(.malformed)))
        #expect(decision.event.authorization == .rejected)
        #expect(decision.event.result == .rejected(.malformed))
    }

    @Test func responseAuthorizationCoversEveryAnswer() {
        #expect(RuntimeAdmissionResponse.executed(exitStatus: 0).authorization == .allowed)
        #expect(RuntimeAdmissionResponse.executorFailed(.cancelled).authorization == .executorFailed)
        #expect(RuntimeAdmissionResponse.httpFailed(.timedOut).authorization == .executorFailed)
        #expect(RuntimeAdmissionResponse.evaluationFailed.authorization == .evaluationFailed)
        #expect(RuntimeAdmissionResponse.approvalUnavailable.authorization == .approvalUnavailable)
    }
}
