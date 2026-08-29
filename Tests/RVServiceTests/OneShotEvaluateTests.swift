import Foundation
import Testing
import RVDomain
import RVIPC
@testable import RVService

struct OneShotEvaluateTests {
    @Test func implicitHelloOnEvaluate_oneShotDeniesResetHard() async throws {
        let runtime = try isolatedRuntime()
        let (data, ok) = await runtime.handleIncoming(
            try evaluateBody(command: "git reset --hard", clientSemver: ProtocolVersion.serviceSemver),
            handshakeOK: false
        )
        #expect(ok == true)
        let response = try IPCJSON.decode(IPCResponse.self, from: data)
        guard case .evaluate(let reply) = response.result else {
            Issue.record("one-shot evaluate must dispatch after implicit hello")
            return
        }
        guard case .deny(let deny) = reply.result.decision else {
            Issue.record("one-shot evaluate must deny git reset --hard")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
        #expect(reply.via == .xpc)
        #expect(reply.serviceSemver == ProtocolVersion.serviceSemver)
    }

    @Test func evaluateWithoutClientSemverAndNoHello_isHandshakeRequired() async throws {
        let runtime = try isolatedRuntime()
        let (data, ok) = await runtime.handleIncoming(
            try evaluateBody(command: "git reset --hard"),
            handshakeOK: false
        )
        #expect(ok == false)
        let response = try IPCJSON.decode(IPCResponse.self, from: data)
        guard case .error(.protocolSkew(let reason)) = response.result else {
            Issue.record("old evaluate without Hello must stay handshake required")
            return
        }
        #expect(reason == .handshakeRequired)
        #expect(reason.rawValue == "handshake required")
    }

    @Test func failedImplicitHello_doesNotEvaluateAndKeepsHandshakeClosed() async throws {
        let runtime = try isolatedRuntime(snapshots: [])
        #expect(await runtime.corePacksReady == false)
        let firstBody = try evaluateBody(
            command: "git reset --hard",
            clientSemver: ProtocolVersion.serviceSemver
        )
        let (first, ok) = await runtime.handleIncoming(firstBody, handshakeOK: false)
        #expect(ok == false)
        let firstResponse = try IPCJSON.decode(IPCResponse.self, from: first)
        guard case .error(.protocolSkew(let reason)) = firstResponse.result else {
            Issue.record("unready core must not evaluate on implicit hello")
            return
        }
        #expect(reason == .corePacksUnavailable)
        #expect(reason.rawValue == "core packs unavailable")
        if case .evaluate = firstResponse.result {
            Issue.record("failed implicit hello must not return evaluate")
        }

        let (second, stillClosed) = await runtime.handleIncoming(
            try evaluateBody(command: "git reset --hard"),
            handshakeOK: ok
        )
        #expect(stillClosed == false)
        let secondResponse = try IPCJSON.decode(IPCResponse.self, from: second)
        guard case .error(.protocolSkew(let again)) = secondResponse.result else {
            Issue.record("handshake must stay closed after failed implicit hello")
            return
        }
        #expect(again == .handshakeRequired)
        #expect(again.rawValue == "handshake required")
    }

    @Test func skewedImplicitHello_doesNotEvaluate() async throws {
        let runtime = try isolatedRuntime()
        let (data, ok) = await runtime.handleIncoming(
            try evaluateBody(
                command: "git reset --hard",
                clientSemver: ProtocolVersion.serviceSemver,
                protocolName: "rv.ipc.v0"
            ),
            handshakeOK: false
        )
        #expect(ok == false)
        let response = try IPCJSON.decode(IPCResponse.self, from: data)
        guard case .error(.protocolSkew(let reason)) = response.result else {
            Issue.record("protocol skew must error, not evaluate")
            return
        }
        #expect(reason == .protocolSkew)
        #expect(reason.rawValue == "protocol")
        if case .evaluate = response.result {
            Issue.record("do not evaluate against a skewed listener")
        }
    }

    @Test func majorSemverImplicitHello_doesNotEvaluate() async throws {
        let runtime = try isolatedRuntime()
        let (data, ok) = await runtime.handleIncoming(
            try evaluateBody(
                command: "git reset --hard",
                clientSemver: "2.0.0"
            ),
            handshakeOK: false
        )
        #expect(ok == false)
        let response = try IPCJSON.decode(IPCResponse.self, from: data)
        guard case .error(.protocolSkew(let reason)) = response.result else {
            Issue.record("major semver skew must error, not evaluate")
            return
        }
        #expect(reason == .majorVersion)
        #expect(reason.rawValue == "major version")
        if case .evaluate = response.result {
            Issue.record("do not evaluate against a major-skewed listener")
        }
    }

    @Test func majorSemverEvaluateAfterSuccessfulHello_doesNotEvaluate() async throws {
        let runtime = try isolatedRuntime()
        let hello = Hello(
            protocolName: ProtocolVersion.name,
            clientSemver: ProtocolVersion.serviceSemver
        )
        let (_, helloOK) = await runtime.handleIncoming(try IPCJSON.encode(hello), handshakeOK: false)
        #expect(helloOK == true)

        let (data, ok) = await runtime.handleIncoming(
            try evaluateBody(command: "git reset --hard", clientSemver: "2.0.0"),
            handshakeOK: helloOK
        )
        #expect(ok == true)
        let response = try IPCJSON.decode(IPCResponse.self, from: data)
        guard case .error(.protocolSkew(let reason)) = response.result else {
            Issue.record("major-skewed evaluate must error even on an open handshake")
            return
        }
        #expect(reason == .majorVersion)
        #expect(reason.rawValue == "major version")
        if case .evaluate = response.result {
            Issue.record("an open handshake must not carry a skewed clientSemver into evaluation")
        }
    }

    @Test func dispatchProtocolNameMismatch_usesProtocolSkewCaseNotRequestName() async throws {
        let runtime = try isolatedRuntime()
        let hello = Hello(
            protocolName: ProtocolVersion.name,
            clientSemver: ProtocolVersion.serviceSemver
        )
        let (_, helloOK) = await runtime.handleIncoming(try IPCJSON.encode(hello), handshakeOK: false)
        #expect(helloOK == true)

        let (data, ok) = await runtime.handleIncoming(
            try evaluateBody(
                command: "git reset --hard",
                clientSemver: ProtocolVersion.serviceSemver,
                protocolName: "rv.ipc.v0"
            ),
            handshakeOK: helloOK
        )
        #expect(ok == true)
        let response = try IPCJSON.decode(IPCResponse.self, from: data)
        guard case .error(.protocolSkew(let reason)) = response.result else {
            Issue.record("open-handshake protocol-name mismatch must be protocolSkew")
            return
        }
        #expect(reason == .protocolSkew)
        #expect(reason.rawValue == "protocol")
        if case .evaluate = response.result {
            Issue.record("do not evaluate a protocol-name mismatch after handshake")
        }
    }

    @Test func matchingClientSemverAfterSuccessfulHello_stillEvaluates() async throws {
        let runtime = try isolatedRuntime()
        let hello = Hello(
            protocolName: ProtocolVersion.name,
            clientSemver: ProtocolVersion.serviceSemver
        )
        let (_, helloOK) = await runtime.handleIncoming(try IPCJSON.encode(hello), handshakeOK: false)
        #expect(helloOK == true)

        let (data, ok) = await runtime.handleIncoming(
            try evaluateBody(
                command: "git reset --hard",
                clientSemver: ProtocolVersion.serviceSemver
            ),
            handshakeOK: helloOK
        )
        #expect(ok == true)
        let response = try IPCJSON.decode(IPCResponse.self, from: data)
        guard case .evaluate(let reply) = response.result else {
            Issue.record("matching clientSemver on an open handshake must still dispatch")
            return
        }
        guard case .deny(let deny) = reply.result.decision else {
            Issue.record("open-handshake evaluate must still deny git reset --hard")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }

    @Test func oldHelloThenEvaluateWithoutClientSemver_stillWorks() async throws {
        let runtime = try isolatedRuntime()
        let hello = Hello(protocolName: ProtocolVersion.name, clientSemver: ProtocolVersion.serviceSemver)
        let (ackData, helloOK) = await runtime.handleIncoming(try IPCJSON.encode(hello), handshakeOK: false)
        let ack = try IPCJSON.decode(HelloAck.self, from: ackData)
        #expect(helloOK == true)
        #expect(ack.status == .ok)

        let (data, ok) = await runtime.handleIncoming(
            try evaluateBody(command: "git reset --hard"),
            handshakeOK: helloOK
        )
        #expect(ok == true)
        let response = try IPCJSON.decode(IPCResponse.self, from: data)
        guard case .evaluate(let reply) = response.result else {
            Issue.record("legacy Hello-then-evaluate must still dispatch")
            return
        }
        guard case .deny(let deny) = reply.result.decision else {
            Issue.record("legacy path must still deny git reset --hard")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }
}

private func evaluateBody(
    command: String,
    clientSemver: String? = nil,
    protocolName: String = ProtocolVersion.name
) throws -> Data {
    try IPCJSON.encode(
        IPCRequest(
            protocolName: protocolName,
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
