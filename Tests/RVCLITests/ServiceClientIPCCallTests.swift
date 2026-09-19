import Foundation
import Testing
import RVDomain
import RVIPC
@testable import RVCLI

struct ServiceClientIPCCallTests {
    private let resetHard = ShellCommand(rawValue: "git reset --hard")

    @Test func evaluateCall_extractsEvaluateAndRejectsDoctorSnapshot() {
        let allowed = EvaluationResult(outcome: .plain, matchingView: MatchingView(resetHard.rawValue))
        let evaluate = IPCResult.evaluate(EvaluateReply(result: allowed))
        let doctor = IPCResult.doctorSnapshot(distinctiveDoctorSnapshot())

        let extracted = EvaluateCall.extract(evaluate)
        #expect(extracted?.result.matchingView == MatchingView(resetHard.rawValue))
        #expect(EvaluateCall.extract(doctor) == nil)
        #expect(EvaluateCall.extract(.error(.unknownMethod)) == nil)
        #expect(EvaluateCall(params: evaluateParams()).method == .evaluate(evaluateParams()))
    }

    @Test func hookEvaluateCall_extractsHookAndRejectsEvaluate() {
        let hook = IPCResult.hookEvaluate(HookEvaluateReply(stdout: "hook-ok", exitCode: 0))
        let evaluate = IPCResult.evaluate(
            EvaluateReply(result: EvaluationResult(outcome: .plain, matchingView: MatchingView(resetHard.rawValue)))
        )

        #expect(HookEvaluateCall.extract(hook)?.stdout == "hook-ok")
        #expect(HookEvaluateCall.extract(evaluate) == nil)
        #expect(HookEvaluateCall.extract(.error(.hookEvaluateFailed)) == nil)
    }

    @Test func doctorSnapshotCall_extractsSnapshotAndRejectsEvaluate() {
        let snapshot = distinctiveDoctorSnapshot()
        #expect(DoctorSnapshotCall.extract(.doctorSnapshot(snapshot)) == snapshot)
        #expect(
            DoctorSnapshotCall.extract(
                .evaluate(EvaluateReply(result: EvaluationResult(outcome: .plain)))
            ) == nil
        )
        #expect(DoctorSnapshotCall().method == .doctorSnapshot)
    }

    @Test func evaluate_doctorSnapshotReply_isNotServiceEvaluateSuccess() async throws {
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: ProtocolVersion.name, serviceSemver: "1.0.0", status: .ok),
            responseResult: .doctorSnapshot(distinctiveDoctorSnapshot())
        )
        let client = try isolatedClient(transport: transport)

        let routed = await client.evaluate(command: resetHard)

        let sent = try #require(transport.sends.first)
        let request = try IPCJSON.decode(IPCRequest.self, from: sent)
        guard case .evaluate = request.method else {
            Issue.record("evaluate must send an evaluate request")
            return
        }
        #expect(EvaluateCall.extract(.doctorSnapshot(distinctiveDoctorSnapshot())) == nil)
        #expect(routed.path == .inProcess)
        #expect(routed.path != .service)
        let deny = try #require(denyPayload(from: routed.result.decision))
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
        #expect(routed.result.matchingView == MatchingView(resetHard.rawValue))
        #expect(transport.sendCount == 1)
        #expect(transport.helloCount == 0)
        #expect(transport.invalidationCount == 1)
    }

    @Test func evaluate_matchingEvaluateReply_staysOnServicePath() async throws {
        let denied = EvaluationResult(
            outcome: .deny(
                Deny(
                    ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                    reason: "git reset --hard destroys uncommitted changes"
                ),
                matched: nil
            ),
            matchingView: MatchingView(resetHard.rawValue)
        )
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: ProtocolVersion.name, serviceSemver: "1.0.0", status: .ok),
            responseResult: .evaluate(EvaluateReply(result: denied))
        )
        let client = try isolatedClient(transport: transport)

        let routed = await client.evaluate(command: resetHard)

        #expect(routed.path == .service)
        #expect(routed.result == denied)
        #expect(transport.invalidationCount == 0)
    }

    @Test func hookEvaluate_matchingReply_isForwarded() async throws {
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: ProtocolVersion.name, serviceSemver: "1.0.0", status: .ok),
            responseResult: .hookEvaluate(HookEvaluateReply(stdout: "{\"decision\":\"ask\"}\n", exitCode: 1))
        )
        let client = try isolatedClient(transport: transport)

        let wire = await client.hookEvaluate(host: .grok, stdin: #"{"toolName":"bash"}"#)

        #expect(wire.stdout.contains("\"decision\":\"ask\""))
        #expect(wire.exitCode == 1)
        let sent = try #require(transport.sends.first)
        let request = try IPCJSON.decode(IPCRequest.self, from: sent)
        guard case .hookEvaluate = request.method else {
            Issue.record("hookEvaluate must send a hookEvaluate request")
            return
        }
    }

    @Test func diagnostics_matchingDoctorSnapshot_staysOnXPC() async throws {
        let snapshot = distinctiveDoctorSnapshot()
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: ProtocolVersion.name, serviceSemver: "1.0.0", status: .ok),
            responseResult: .doctorSnapshot(snapshot)
        )
        let client = try isolatedClient(transport: transport)

        let result = await client.diagnostics()

        #expect(result == .xpc(snapshot: snapshot, localCorePacksReady: true))
        let sent = try #require(transport.sends.first)
        #expect(try IPCJSON.decode(IPCRequest.self, from: sent).method == .doctorSnapshot)
    }

    private func evaluateParams() -> EvaluateParams {
        EvaluateParams(
            request: EvaluationRequest(command: resetHard, enabledPacks: []),
            cwd: nil,
            clientSemver: ProtocolVersion.serviceSemver
        )
    }
}

private func distinctiveDoctorSnapshot() -> DoctorSnapshotReply {
    DoctorSnapshotReply(
        state: .running,
        idleExitSeconds: 300,
        packsEnabled: [.coreGit],
        lastError: "DOCTOR-NOT-EVALUATE",
        checks: [DoctorCheck(id: .xpc, status: .ok, message: "listener")]
    )
}
