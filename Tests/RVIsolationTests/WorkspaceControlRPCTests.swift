import Foundation
import Testing
@testable import RVIsolation

private enum ControlRPCFixtures {
    static let id = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    static let token = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    static let runtime = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
    static let workspace = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
    static let host = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!

    static func legacyMessage(
        op: WorkspaceControlOp,
        configure: (inout WorkspaceControlMessage) -> Void = { _ in }
    ) -> WorkspaceControlMessage {
        var message = WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            id: id,
            op: op.rawValue
        )
        configure(&message)
        return message
    }
}

private func sortedJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}

@Test func controlRPCRequestRoundTrips() throws {
    let requests: [WorkspaceControlRequest] = [
        WorkspaceControlRequest(id: ControlRPCFixtures.id, operation: .hello, token: ControlRPCFixtures.token),
        WorkspaceControlRequest(id: ControlRPCFixtures.id, operation: .capabilities),
        WorkspaceControlRequest(id: ControlRPCFixtures.id, operation: .ping),
        WorkspaceControlRequest(id: ControlRPCFixtures.id, operation: .describeWorkspace),
        WorkspaceControlRequest(id: ControlRPCFixtures.id, operation: .listRuntimes),
        WorkspaceControlRequest(
            id: ControlRPCFixtures.id,
            operation: .launchRuntime,
            executable: "/bin/sh",
            arguments: ["-c", "echo hi"],
            hook: "pre",
            io: "terminal",
            rows: 24,
            columns: 80
        ),
        WorkspaceControlRequest(
            id: ControlRPCFixtures.id,
            operation: .ensureTerminalRuntime,
            executable: "/bin/sh",
            io: "terminal",
            rows: 24,
            columns: 80
        ),
        WorkspaceControlRequest(id: ControlRPCFixtures.id, operation: .cancelRuntime, runtime: ControlRPCFixtures.runtime),
        WorkspaceControlRequest(id: ControlRPCFixtures.id, operation: .closeWorkspace),
        WorkspaceControlRequest(id: ControlRPCFixtures.id, operation: .detach),
        WorkspaceControlRequest(id: ControlRPCFixtures.id, operation: .subscribeTerminal, runtime: ControlRPCFixtures.runtime),
        WorkspaceControlRequest(id: ControlRPCFixtures.id, operation: .unsubscribeTerminal, runtime: ControlRPCFixtures.runtime),
        WorkspaceControlRequest(
            id: ControlRPCFixtures.id,
            operation: .terminalInput,
            runtime: ControlRPCFixtures.runtime,
            bytes: TerminalBytesCodec.encode(Data("ls\n".utf8))
        ),
        WorkspaceControlRequest(id: ControlRPCFixtures.id, operation: .acquireTerminalInput, runtime: ControlRPCFixtures.runtime),
        WorkspaceControlRequest(id: ControlRPCFixtures.id, operation: .releaseTerminalInput, runtime: ControlRPCFixtures.runtime),
        WorkspaceControlRequest(
            id: ControlRPCFixtures.id,
            operation: .resizeTerminal,
            runtime: ControlRPCFixtures.runtime,
            rows: 30,
            columns: 100
        ),
    ]
    for request in requests {
        let body = try #require(request.encode())
        guard case .request(let decoded) = WorkspaceControlRequest.decode(body) else {
            Issue.record("request \(String(describing: request.operation)) did not decode")
            continue
        }
        #expect(decoded == request)
        #expect(decoded.operation == request.operation)
    }
}

@Test func controlRPCResponseRoundTrips() throws {
    let responses: [WorkspaceControlResponse] = [
        WorkspaceControlResponse(
            id: ControlRPCFixtures.id,
            operation: .hello,
            ok: true,
            workspace: ControlRPCFixtures.workspace,
            host: ControlRPCFixtures.host
        ),
        WorkspaceControlResponse(
            id: ControlRPCFixtures.id,
            operation: .capabilities,
            ok: true,
            features: [WorkspaceControlFeature.ensureTerminalRuntime]
        ),
        WorkspaceControlResponse(id: ControlRPCFixtures.id, operation: .ping, ok: true, host: ControlRPCFixtures.host),
        WorkspaceControlResponse(
            id: ControlRPCFixtures.id,
            operation: .describeWorkspace,
            ok: true,
            workspace: ControlRPCFixtures.workspace,
            host: ControlRPCFixtures.host,
            phase: "open",
            project: "/tmp/demo",
            attached: 2
        ),
        WorkspaceControlResponse(
            id: ControlRPCFixtures.id,
            operation: .listRuntimes,
            ok: true,
            runtimes: [
                WorkspaceRuntimeReport(
                    runtime: ControlRPCFixtures.runtime,
                    hook: nil,
                    running: true,
                    terminal: true,
                    rows: 24,
                    columns: 80,
                    inputOwner: false
                )
            ]
        ),
        WorkspaceControlResponse(
            id: ControlRPCFixtures.id,
            operation: .launchRuntime,
            runtime: ControlRPCFixtures.runtime,
            ok: true,
            running: true,
            rows: 24,
            columns: 80,
            terminal: true,
            inputOwner: false
        ),
        WorkspaceControlResponse(
            id: ControlRPCFixtures.id,
            operation: .ensureTerminalRuntime,
            runtime: ControlRPCFixtures.runtime,
            ok: true,
            running: true,
            terminal: true,
            inputOwner: false,
            created: true
        ),
        WorkspaceControlResponse(id: ControlRPCFixtures.id, operation: .cancelRuntime, runtime: ControlRPCFixtures.runtime, ok: true),
        WorkspaceControlResponse(id: ControlRPCFixtures.id, operation: .detach, ok: true),
        WorkspaceControlResponse(
            operation: .workspaceClosed,
            ok: true,
            workspace: ControlRPCFixtures.workspace,
            host: ControlRPCFixtures.host,
            phase: "closed",
            project: "/tmp/demo",
            attached: 0
        ),
        WorkspaceControlResponse(
            operation: .terminalReplay,
            runtime: ControlRPCFixtures.runtime,
            ok: true,
            sequence: 7,
            bytes: TerminalBytesCodec.encode(Data("replay".utf8))
        ),
        WorkspaceControlResponse(
            operation: .terminalOutput,
            runtime: ControlRPCFixtures.runtime,
            ok: true,
            sequence: 8,
            bytes: TerminalBytesCodec.encode(Data("output".utf8))
        ),
        WorkspaceControlResponse(
            operation: .terminalInputOwner,
            runtime: ControlRPCFixtures.runtime,
            ok: true,
            inputOwner: true
        ),
        WorkspaceControlResponse(
            operation: .runtimeExited,
            runtime: ControlRPCFixtures.runtime,
            ok: true,
            running: false,
            exitStatus: 3
        ),
        WorkspaceControlResponse(operation: .terminalOverflow, runtime: ControlRPCFixtures.runtime, ok: true),
        WorkspaceControlResponse.failure(id: ControlRPCFixtures.id, operation: .ping, code: .invalidRequest),
    ]
    for response in responses {
        let body = try #require(response.encode())
        guard case .response(let decoded) = WorkspaceControlResponse.decode(body) else {
            Issue.record("response \(String(describing: response.operation)) did not decode")
            continue
        }
        #expect(decoded == response)
        #expect(decoded.operation == response.operation)
    }
}

@Test func controlRPCFramesAreByteIdenticalToLegacyCodec() throws {
    let legacyMessages: [WorkspaceControlMessage] = [
        ControlRPCFixtures.legacyMessage(op: .hello) { $0.token = ControlRPCFixtures.token },
        ControlRPCFixtures.legacyMessage(op: .capabilities) {
            $0.ok = true
            $0.features = [WorkspaceControlFeature.ensureTerminalRuntime]
        },
        ControlRPCFixtures.legacyMessage(op: .ping),
        ControlRPCFixtures.legacyMessage(op: .describeWorkspace) {
            $0.ok = true
            $0.workspace = ControlRPCFixtures.workspace
            $0.host = ControlRPCFixtures.host
            $0.phase = "open"
            $0.project = "/tmp/demo"
            $0.attached = 2
        },
        ControlRPCFixtures.legacyMessage(op: .launchRuntime) {
            $0.executable = "/bin/sh"
            $0.arguments = ["-c", "echo hi"]
            $0.hook = "pre"
            $0.io = "terminal"
            $0.rows = 24
            $0.columns = 80
        },
        ControlRPCFixtures.legacyMessage(op: .terminalInput) {
            $0.runtime = ControlRPCFixtures.runtime
            $0.bytes = TerminalBytesCodec.encode(Data("ls\n".utf8))
        },
        ControlRPCFixtures.legacyMessage(op: .hello) {
            $0.ok = true
            $0.workspace = ControlRPCFixtures.workspace
            $0.host = ControlRPCFixtures.host
        },
        ControlRPCFixtures.legacyMessage(op: .listRuntimes) {
            $0.ok = true
            $0.runtimes = [
                WorkspaceRuntimeReport(
                    runtime: ControlRPCFixtures.runtime,
                    hook: nil,
                    running: true,
                    terminal: true,
                    rows: 24,
                    columns: 80,
                    inputOwner: false
                )
            ]
        },
        ControlRPCFixtures.legacyMessage(op: .ensureTerminalRuntime) {
            $0.runtime = ControlRPCFixtures.runtime
            $0.ok = true
            $0.running = true
            $0.terminal = true
            $0.inputOwner = false
            $0.created = true
        },
        ControlRPCFixtures.legacyMessage(op: .terminalOutput) {
            $0.id = nil
            $0.runtime = ControlRPCFixtures.runtime
            $0.ok = true
            $0.sequence = 8
            $0.bytes = TerminalBytesCodec.encode(Data("output".utf8))
        },
        ControlRPCFixtures.legacyMessage(op: .runtimeExited) {
            $0.id = nil
            $0.runtime = ControlRPCFixtures.runtime
            $0.ok = true
            $0.running = false
            $0.exitStatus = 3
        },
        WorkspaceControlMessage.error(id: ControlRPCFixtures.id, op: WorkspaceControlOp.ping.rawValue, code: .invalidRequest),
    ]
    for legacy in legacyMessages {
        let legacyBody = try #require(WorkspaceControlCodec.encode(legacy))
        let request = WorkspaceControlRequest(
            id: legacy.id,
            operation: try #require(WorkspaceControlOp(rawValue: legacy.op)),
            token: legacy.token,
            executable: legacy.executable,
            arguments: legacy.arguments,
            runtime: legacy.runtime,
            hook: legacy.hook,
            ok: legacy.ok,
            error: legacy.error,
            workspace: legacy.workspace,
            host: legacy.host,
            phase: legacy.phase,
            project: legacy.project,
            runtimes: legacy.runtimes,
            attached: legacy.attached,
            running: legacy.running,
            io: legacy.io,
            rows: legacy.rows,
            columns: legacy.columns,
            sequence: legacy.sequence,
            bytes: legacy.bytes,
            exitStatus: legacy.exitStatus,
            terminal: legacy.terminal,
            inputOwner: legacy.inputOwner,
            created: legacy.created,
            features: legacy.features
        )
        let response = WorkspaceControlResponse(
            id: legacy.id,
            operation: try #require(WorkspaceControlOp(rawValue: legacy.op)),
            token: legacy.token,
            executable: legacy.executable,
            arguments: legacy.arguments,
            runtime: legacy.runtime,
            hook: legacy.hook,
            ok: legacy.ok,
            error: legacy.error,
            workspace: legacy.workspace,
            host: legacy.host,
            phase: legacy.phase,
            project: legacy.project,
            runtimes: legacy.runtimes,
            attached: legacy.attached,
            running: legacy.running,
            io: legacy.io,
            rows: legacy.rows,
            columns: legacy.columns,
            sequence: legacy.sequence,
            bytes: legacy.bytes,
            exitStatus: legacy.exitStatus,
            terminal: legacy.terminal,
            inputOwner: legacy.inputOwner,
            created: legacy.created,
            features: legacy.features
        )
        #expect(request.encode() == legacyBody)
        #expect(response.encode() == legacyBody)
        #expect(try sortedJSON(request) == legacyBody)
        #expect(try sortedJSON(response) == legacyBody)
        guard case .request(let decodedRequest) = WorkspaceControlRequest.decode(legacyBody),
            case .response(let decodedResponse) = WorkspaceControlResponse.decode(legacyBody),
            case .message(let decodedLegacy) = WorkspaceControlCodec.decode(legacyBody)
        else {
            Issue.record("op \(legacy.op) did not decode on all paths")
            continue
        }
        #expect(decodedRequest.encode() == legacyBody)
        #expect(decodedResponse.encode() == legacyBody)
        #expect(WorkspaceControlCodec.encode(decodedLegacy) == legacyBody)
    }
}

@Test func controlRPCUnknownOperationPreservesRawEcho() throws {
    let unknown = Data(
        "{\"v\":1,\"id\":\"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA\",\"op\":\"killProcess\"}".utf8
    )
    guard case .request(let request) = WorkspaceControlRequest.decode(unknown) else {
        Issue.record("unknown op must decode so the host can refuse it")
        return
    }
    #expect(request.operation == nil)
    #expect(request.rawOperation == "killProcess")
    let failure = WorkspaceControlResponse.failure(request: request, code: .invalidRequest)
    #expect(failure.operation == nil)
    #expect(failure.rawOperation == "killProcess")
    #expect(failure.code == .invalidRequest)
    let legacyFailure = WorkspaceControlMessage.error(
        id: ControlRPCFixtures.id,
        op: "killProcess",
        code: .invalidRequest
    )
    #expect(failure.encode() == WorkspaceControlCodec.encode(legacyFailure))
}

@Test func controlRPCPropagatesInvalidAndIncompatible() {
    let invalid = Data(
        "{\"v\":1,\"id\":\"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA\",\"op\":\"ping\",\"pid\":1}".utf8
    )
    #expect(WorkspaceControlRequest.decode(invalid) == .invalid)
    #expect(WorkspaceControlResponse.decode(invalid) == .invalid)
    let incompatible = Data(
        "{\"v\":2,\"id\":\"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA\",\"op\":\"ping\"}".utf8
    )
    #expect(WorkspaceControlRequest.decode(incompatible) == .incompatible)
    #expect(WorkspaceControlResponse.decode(incompatible) == .incompatible)
}

@Test func controlRPCCodableInitEnforcesVersionAndLimits() throws {
    let decoder = JSONDecoder()
    let oversized = String(repeating: "x", count: WorkspaceControlLimits.maxExecutableBytes + 1)
    let rejected: [Data] = [
        Data("{\"v\":2,\"op\":\"ping\"}".utf8),
        Data("{\"v\":1,\"op\":\"ping\",\"executable\":\"\(oversized)\"}".utf8),
        Data("{\"v\":1,\"op\":\"ping\",\"pid\":1}".utf8),
    ]
    for frame in rejected {
        do {
            _ = try decoder.decode(WorkspaceControlRequest.self, from: frame)
            Issue.record("request Codable init accepted \(String(decoding: frame, as: UTF8.self))")
        } catch {
            // Expected: version, limits, and unknown keys all fail closed.
        }
        do {
            _ = try decoder.decode(WorkspaceControlResponse.self, from: frame)
            Issue.record("response Codable init accepted \(String(decoding: frame, as: UTF8.self))")
        } catch {
            // Expected: version, limits, and unknown keys all fail closed.
        }
    }
    let valid = Data("{\"v\":1,\"op\":\"ping\"}".utf8)
    #expect(try decoder.decode(WorkspaceControlRequest.self, from: valid).operation == .ping)
    #expect(try decoder.decode(WorkspaceControlResponse.self, from: valid).operation == .ping)
}
