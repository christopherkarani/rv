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
        WorkspaceControlRequest(operation: .hello, id: ControlRPCFixtures.id, token: ControlRPCFixtures.token),
        WorkspaceControlRequest(operation: .capabilities, id: ControlRPCFixtures.id),
        WorkspaceControlRequest(operation: .ping, id: ControlRPCFixtures.id),
        WorkspaceControlRequest(operation: .describeWorkspace, id: ControlRPCFixtures.id),
        WorkspaceControlRequest(operation: .listRuntimes, id: ControlRPCFixtures.id),
        WorkspaceControlRequest(
            operation: .launchRuntime,
            id: ControlRPCFixtures.id,
            executable: "/bin/sh",
            arguments: ["-c", "echo hi"],
            hook: "pre",
            io: "terminal",
            rows: 24,
            columns: 80
        ),
        WorkspaceControlRequest(
            operation: .ensureTerminalRuntime,
            id: ControlRPCFixtures.id,
            executable: "/bin/sh",
            io: "terminal",
            rows: 24,
            columns: 80
        ),
        WorkspaceControlRequest(operation: .cancelRuntime, id: ControlRPCFixtures.id, runtime: ControlRPCFixtures.runtime),
        WorkspaceControlRequest(operation: .closeWorkspace, id: ControlRPCFixtures.id),
        WorkspaceControlRequest(operation: .detach, id: ControlRPCFixtures.id),
        WorkspaceControlRequest(operation: .subscribeTerminal, id: ControlRPCFixtures.id, runtime: ControlRPCFixtures.runtime),
        WorkspaceControlRequest(operation: .unsubscribeTerminal, id: ControlRPCFixtures.id, runtime: ControlRPCFixtures.runtime),
        WorkspaceControlRequest(
            operation: .terminalInput,
            id: ControlRPCFixtures.id,
            runtime: ControlRPCFixtures.runtime,
            bytes: TerminalBytesCodec.encode(Data("ls\n".utf8))
        ),
        WorkspaceControlRequest(operation: .acquireTerminalInput, id: ControlRPCFixtures.id, runtime: ControlRPCFixtures.runtime),
        WorkspaceControlRequest(operation: .releaseTerminalInput, id: ControlRPCFixtures.id, runtime: ControlRPCFixtures.runtime),
        WorkspaceControlRequest(
            operation: .resizeTerminal,
            id: ControlRPCFixtures.id,
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
            operation: .hello,
            id: ControlRPCFixtures.id,
            ok: true,
            workspace: ControlRPCFixtures.workspace,
            host: ControlRPCFixtures.host
        ),
        WorkspaceControlResponse(
            operation: .capabilities,
            id: ControlRPCFixtures.id,
            ok: true,
            features: [WorkspaceControlFeature.ensureTerminalRuntime]
        ),
        WorkspaceControlResponse(operation: .ping, id: ControlRPCFixtures.id, ok: true, host: ControlRPCFixtures.host),
        WorkspaceControlResponse(
            operation: .describeWorkspace,
            id: ControlRPCFixtures.id,
            ok: true,
            workspace: ControlRPCFixtures.workspace,
            host: ControlRPCFixtures.host,
            phase: "open",
            project: "/tmp/demo",
            attached: 2
        ),
        WorkspaceControlResponse(
            operation: .listRuntimes,
            id: ControlRPCFixtures.id,
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
            operation: .launchRuntime,
            id: ControlRPCFixtures.id,
            runtime: ControlRPCFixtures.runtime,
            ok: true,
            running: true,
            rows: 24,
            columns: 80,
            terminal: true,
            inputOwner: false
        ),
        WorkspaceControlResponse(
            operation: .ensureTerminalRuntime,
            id: ControlRPCFixtures.id,
            runtime: ControlRPCFixtures.runtime,
            ok: true,
            running: true,
            terminal: true,
            inputOwner: false,
            created: true
        ),
        WorkspaceControlResponse(operation: .cancelRuntime, id: ControlRPCFixtures.id, runtime: ControlRPCFixtures.runtime, ok: true),
        WorkspaceControlResponse(operation: .detach, id: ControlRPCFixtures.id, ok: true),
        WorkspaceControlResponse(
            operation: .closeWorkspace,
            id: ControlRPCFixtures.id,
            ok: true,
            workspace: ControlRPCFixtures.workspace,
            host: ControlRPCFixtures.host,
            phase: "closed",
            project: "/tmp/demo",
            attached: 0
        ),
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
            operation: try #require(WorkspaceControlOp(rawValue: legacy.op)),
            id: legacy.id,
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
            operation: try #require(WorkspaceControlOp(rawValue: legacy.op)),
            id: legacy.id,
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

@Test func controlRPCFailureTypedOverloadShape() throws {
    let failure = WorkspaceControlResponse.failure(
        id: ControlRPCFixtures.id,
        operation: .ping,
        code: .invalidRequest
    )
    #expect(failure.ok == false)
    #expect(failure.error == WorkspaceControlCode.invalidRequest.rawValue)
    #expect(failure.code == .invalidRequest)
    #expect(failure.operation == .ping)
    #expect(failure.rawOperation == WorkspaceControlOp.ping.rawValue)
    #expect(failure.id == ControlRPCFixtures.id)
    let legacy = WorkspaceControlMessage.error(
        id: ControlRPCFixtures.id,
        op: WorkspaceControlOp.ping.rawValue,
        code: .invalidRequest
    )
    #expect(failure.encode() == WorkspaceControlCodec.encode(legacy))
}

@Test func controlRPCResponseCodeRoundTrips() {
    var response = WorkspaceControlResponse(operation: .ping, ok: false, error: "bogus")
    #expect(response.code == nil)
    response.error = nil
    #expect(response.code == nil)
    response.code = .terminalBusy
    #expect(response.error == WorkspaceControlCode.terminalBusy.rawValue)
    #expect(response.code == .terminalBusy)
    response.code = nil
    #expect(response.error == nil)
    #expect(response.code == nil)
}

@Test func controlRPCCodableEncodeAgreesWithValidatedEncode() throws {
    let oversized = String(repeating: "x", count: WorkspaceControlLimits.maxBodyBytes)
    let request = WorkspaceControlRequest(
        operation: .launchRuntime,
        id: ControlRPCFixtures.id,
        executable: oversized
    )
    #expect(request.encode() == nil)
    do {
        _ = try JSONEncoder().encode(request)
        Issue.record("generic encode of an oversized request must throw")
    } catch {
        // Expected: the body cap rejects the frame on both encode paths.
    }
    let response = WorkspaceControlResponse(
        operation: .describeWorkspace,
        id: ControlRPCFixtures.id,
        ok: true,
        project: oversized
    )
    #expect(response.encode() == nil)
    do {
        _ = try JSONEncoder().encode(response)
        Issue.record("generic encode of an oversized response must throw")
    } catch {
        // Expected: the body cap rejects the frame on both encode paths.
    }
    let overField = String(repeating: "x", count: WorkspaceControlLimits.maxExecutableBytes + 1)
    let limited = WorkspaceControlRequest(
        operation: .launchRuntime,
        id: ControlRPCFixtures.id,
        executable: overField
    )
    #expect(try #require(limited.encode()).count <= WorkspaceControlLimits.maxBodyBytes)
    do {
        _ = try JSONEncoder().encode(limited)
        Issue.record("generic encode of an over-limit request must throw")
    } catch {
        // Expected: per-field limits fail closed on the Codable path.
    }
    let valid = WorkspaceControlRequest(operation: .ping, id: ControlRPCFixtures.id)
    #expect(try JSONEncoder().encode(valid).isEmpty == false)
}

@Test func controlRPCLimitBatteryRejectsIdenticalFramesOnBothPaths() {
    let decoder = JSONDecoder()
    let uuid = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    func over(_ count: Int) -> String { String(repeating: "x", count: count) }
    let manyArguments = Array(repeating: "\"a\"", count: WorkspaceControlLimits.maxArguments + 1).joined(
        separator: ","
    )
    let manyFeatures = Array(repeating: "\"f\"", count: WorkspaceControlLimits.maxFeatures + 1).joined(
        separator: ","
    )
    let runtimeEntry = "{\"runtime\":\"\(uuid)\",\"running\":true}"
    let manyRuntimes = Array(repeating: runtimeEntry, count: WorkspaceControlLimits.maxRuntimes + 1).joined(
        separator: ","
    )
    let frames: [String] = [
        "{\"v\":1,\"op\":\"\(over(WorkspaceControlLimits.maxOperationBytes + 1))\"}",
        "{\"v\":1,\"op\":\"ping\",\"executable\":\"\(over(WorkspaceControlLimits.maxExecutableBytes + 1))\"}",
        "{\"v\":1,\"op\":\"ping\",\"hook\":\"\(over(WorkspaceControlLimits.maxHookBytes + 1))\"}",
        "{\"v\":1,\"op\":\"ping\",\"error\":\"\(over(WorkspaceControlLimits.maxErrorBytes + 1))\"}",
        "{\"v\":1,\"op\":\"ping\",\"resourceProfileID\":\"\(over(WorkspaceControlLimits.maxResourceProfileIDBytes + 1))\"}",
        "{\"v\":1,\"op\":\"ping\",\"Detail\":\"\(over(WorkspaceControlLimits.maxDetailBytes + 1))\"}",
        "{\"v\":1,\"op\":\"ping\",\"phase\":\"\(over(33))\"}",
        "{\"v\":1,\"op\":\"ping\",\"project\":\"\(over(WorkspaceControlLimits.maxProjectBytes + 1))\"}",
        "{\"v\":1,\"op\":\"ping\",\"arguments\":[\(manyArguments)]}",
        "{\"v\":1,\"op\":\"ping\",\"arguments\":[\"\(over(WorkspaceControlLimits.maxArgumentBytes + 1))\"]}",
        "{\"v\":1,\"op\":\"ping\",\"features\":[\(manyFeatures)]}",
        "{\"v\":1,\"op\":\"ping\",\"features\":[\"\(over(WorkspaceControlLimits.maxFeatureBytes + 1))\"]}",
        "{\"v\":1,\"op\":\"ping\",\"attached\":\(WorkspaceControlLimits.maxConnections + 1)}",
        "{\"v\":1,\"op\":\"ping\",\"attached\":-1}",
        "{\"v\":1,\"op\":\"ping\",\"io\":\"bogus\"}",
        "{\"v\":1,\"op\":\"ping\",\"rows\":0}",
        "{\"v\":1,\"op\":\"ping\",\"rows\":\(TerminalStreamLimits.maximumRows + 1)}",
        "{\"v\":1,\"op\":\"ping\",\"cols\":0}",
        "{\"v\":1,\"op\":\"ping\",\"cols\":\(TerminalStreamLimits.maximumColumns + 1)}",
        "{\"v\":1,\"op\":\"ping\",\"sequence\":-1}",
        "{\"v\":1,\"op\":\"ping\",\"bytes\":\"!!!\"}",
        "{\"v\":1,\"op\":\"ping\",\"runtimes\":[\(manyRuntimes)]}",
        "{\"v\":1,\"op\":\"ping\",\"runtimes\":[{\"runtime\":\"\(uuid)\",\"running\":true,\"hook\":\"\(over(WorkspaceControlLimits.maxHookBytes + 1))\"}]}",
        "{\"v\":1,\"op\":\"ping\",\"runtimes\":[{\"runtime\":\"\(uuid)\",\"running\":true,\"rows\":0}]}",
        "{\"v\":1,\"op\":\"ping\",\"executable\":\"a\\u0000b\"}",
    ]
    for frame in frames {
        let data = Data(frame.utf8)
        guard data.count <= WorkspaceControlLimits.maxBodyBytes else {
            Issue.record("battery frame trips the body cap instead of its field limit: \(frame.prefix(80))")
            continue
        }
        #expect(WorkspaceControlRequest.decode(data) == .invalid)
        #expect(WorkspaceControlResponse.decode(data) == .invalid)
        do {
            _ = try decoder.decode(WorkspaceControlRequest.self, from: data)
            Issue.record("request Codable init accepted \(frame.prefix(80))")
        } catch {
            // Expected: every over-limit frame fails closed.
        }
        do {
            _ = try decoder.decode(WorkspaceControlResponse.self, from: data)
            Issue.record("response Codable init accepted \(frame.prefix(80))")
        } catch {
            // Expected: every over-limit frame fails closed.
        }
    }
}
