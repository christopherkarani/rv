import Foundation
import Testing
@testable import RVIsolation

// Codec seam tests for T1: one wire codec, typed per-op payloads. The
// golden literals are the exact bytes the legacy message/mirror codec
// emitted (captured before the refactor); the module must keep emitting
// and accepting them byte for byte.

private enum ControlRPCFixtures {
    static let id = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    static let token = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    static let runtime = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
    static let workspace = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
    static let host = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
}

@Test func controlRPCRequestGoldenBytes() throws {
    let cases: [(WorkspaceControlRequestFrame, String)] = [
        (
            WorkspaceControlRequestFrame(
                id: ControlRPCFixtures.id,
                payload: .hello(.init(token: ControlRPCFixtures.token))
            ),
            #"{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","op":"hello","token":"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB","v":1}"#
        ),
        (
            WorkspaceControlRequestFrame(id: ControlRPCFixtures.id, payload: .capabilities),
            #"{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","op":"capabilities","v":1}"#
        ),
        (
            WorkspaceControlRequestFrame(id: ControlRPCFixtures.id, payload: .ping),
            #"{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","op":"ping","v":1}"#
        ),
        (
            WorkspaceControlRequestFrame(id: ControlRPCFixtures.id, payload: .describeWorkspace),
            #"{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","op":"describeWorkspace","v":1}"#
        ),
        (
            WorkspaceControlRequestFrame(id: ControlRPCFixtures.id, payload: .listRuntimes),
            #"{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","op":"listRuntimes","v":1}"#
        ),
        (
            WorkspaceControlRequestFrame(
                id: ControlRPCFixtures.id,
                payload: .launchRuntime(.init(
                    executable: "/bin/sh",
                    arguments: ["-c", "echo hi"],
                    resourceProfileID: "shell",
                    hook: "codex",
                    io: "terminal",
                    rows: 24,
                    columns: 80
                ))
            ),
            #"{"arguments":["-c","echo hi"],"cols":80,"executable":"\/bin\/sh","hook":"codex","id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","io":"terminal","op":"launchRuntime","resourceProfileID":"shell","rows":24,"v":1}"#
        ),
        (
            WorkspaceControlRequestFrame(
                id: ControlRPCFixtures.id,
                payload: .launchRuntime(.init(executable: "/bin/sh"))
            ),
            #"{"executable":"\/bin\/sh","id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","op":"launchRuntime","v":1}"#
        ),
        (
            WorkspaceControlRequestFrame(
                id: ControlRPCFixtures.id,
                payload: .launchAgentRuntime(.init(
                    agentDefinitionID: "agent",
                    arguments: ["--once"],
                    io: "terminal",
                    rows: 24,
                    columns: 80
                ))
            ),
            #"{"agentDefinitionID":"agent","arguments":["--once"],"cols":80,"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","io":"terminal","op":"launchAgentRuntime","rows":24,"v":1}"#
        ),
        (
            WorkspaceControlRequestFrame(
                id: ControlRPCFixtures.id,
                payload: .launchCustomRuntime(.init(
                    executable: "/bin/sleep",
                    arguments: ["30"],
                    customDefinitionDigest: String(repeating: "a", count: 64)
                ))
            ),
            #"{"arguments":["30"],"customDefinitionDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","executable":"\/bin\/sleep","id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","op":"launchCustomRuntime","v":1}"#
        ),
        (
            WorkspaceControlRequestFrame(
                id: ControlRPCFixtures.id,
                payload: .ensureTerminalRuntime(.init(
                    executable: "/bin/sh",
                    io: "terminal",
                    rows: 24,
                    columns: 80
                ))
            ),
            #"{"cols":80,"executable":"\/bin\/sh","id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","io":"terminal","op":"ensureTerminalRuntime","rows":24,"v":1}"#
        ),
        (
            WorkspaceControlRequestFrame(
                id: ControlRPCFixtures.id,
                payload: .cancelRuntime(.init(runtime: ControlRPCFixtures.runtime))
            ),
            #"{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","op":"cancelRuntime","runtime":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","v":1}"#
        ),
        (
            WorkspaceControlRequestFrame(id: ControlRPCFixtures.id, payload: .closeWorkspace),
            #"{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","op":"closeWorkspace","v":1}"#
        ),
        (
            WorkspaceControlRequestFrame(id: ControlRPCFixtures.id, payload: .detach),
            #"{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","op":"detach","v":1}"#
        ),
        (
            WorkspaceControlRequestFrame(
                id: ControlRPCFixtures.id,
                payload: .subscribeTerminal(.init(
                    runtime: ControlRPCFixtures.runtime,
                    features: [
                        WorkspaceControlFeature.terminalWindowNoticesV1,
                        WorkspaceControlFeature.terminalReplayBatchesV1,
                    ]
                ))
            ),
            #"{"features":["terminalWindowNoticesV1","terminalReplayBatchesV1"],"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","op":"subscribeTerminal","runtime":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","v":1}"#
        ),
        (
            WorkspaceControlRequestFrame(
                id: ControlRPCFixtures.id,
                payload: .unsubscribeTerminal(.init(runtime: ControlRPCFixtures.runtime))
            ),
            #"{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","op":"unsubscribeTerminal","runtime":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","v":1}"#
        ),
        (
            WorkspaceControlRequestFrame(
                id: ControlRPCFixtures.id,
                payload: .terminalInput(.init(
                    runtime: ControlRPCFixtures.runtime,
                    bytes: TerminalBytesCodec.encode(Data("ls\n".utf8))
                ))
            ),
            #"{"bytes":"bHMK","id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","op":"terminalInput","runtime":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","v":1}"#
        ),
        (
            WorkspaceControlRequestFrame(
                id: ControlRPCFixtures.id,
                payload: .acquireTerminalInput(.init(runtime: ControlRPCFixtures.runtime))
            ),
            #"{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","op":"acquireTerminalInput","runtime":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","v":1}"#
        ),
        (
            WorkspaceControlRequestFrame(
                id: ControlRPCFixtures.id,
                payload: .releaseTerminalInput(.init(runtime: ControlRPCFixtures.runtime))
            ),
            #"{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","op":"releaseTerminalInput","runtime":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","v":1}"#
        ),
        (
            WorkspaceControlRequestFrame(
                id: ControlRPCFixtures.id,
                payload: .resizeTerminal(.init(
                    runtime: ControlRPCFixtures.runtime,
                    rows: 30,
                    columns: 100
                ))
            ),
            #"{"cols":100,"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","op":"resizeTerminal","rows":30,"runtime":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","v":1}"#
        ),
    ]
    for (frame, golden) in cases {
        let body = try #require(WorkspaceControlCodec.encodeRequest(frame))
        #expect(body == Data(golden.utf8), "\(frame.rawOperation) encode drifted from the golden bytes")
        #expect(WorkspaceControlCodec.decodeRequest(body) == .frame(frame), "\(frame.rawOperation) round-trip")
    }
}

@Test func controlRPCResponseGoldenBytes() throws {
    let id = ControlRPCFixtures.id
    let workspace = ControlRPCFixtures.workspace
    let host = ControlRPCFixtures.host
    let runtime = ControlRPCFixtures.runtime
    let cases: [(WorkspaceControlResponseFrame, String)] = [
        (
            WorkspaceControlResponseFrame(
                id: id, ok: true,
                payload: .hello(.init(workspace: workspace, host: host))
            ),
            #"{"host":"EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE","id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","ok":true,"op":"hello","v":1,"workspace":"DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"}"#
        ),
        (
            WorkspaceControlResponseFrame(
                id: id, ok: true,
                payload: .capabilities(.init(features: [WorkspaceControlFeature.ensureTerminalRuntime]))
            ),
            #"{"features":["ensureTerminalRuntime"],"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","ok":true,"op":"capabilities","v":1}"#
        ),
        (
            WorkspaceControlResponseFrame(id: id, ok: true, payload: .ping(.init(host: host))),
            #"{"host":"EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE","id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","ok":true,"op":"ping","v":1}"#
        ),
        (
            WorkspaceControlResponseFrame(
                id: id, ok: true,
                payload: .describeWorkspace(.init(
                    workspace: workspace, host: host, phase: "open",
                    project: "/tmp/demo", attached: 2
                ))
            ),
            #"{"attached":2,"host":"EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE","id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","ok":true,"op":"describeWorkspace","phase":"open","project":"\/tmp\/demo","v":1,"workspace":"DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"}"#
        ),
        (
            WorkspaceControlResponseFrame(
                id: id, ok: true,
                payload: .listRuntimes(.init(runtimes: [
                    WorkspaceRuntimeReport(
                        runtime: runtime, hook: nil, running: true, terminal: true,
                        rows: 24, columns: 80, inputOwner: false
                    )
                ]))
            ),
            #"{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","ok":true,"op":"listRuntimes","runtimes":[{"cols":80,"input":false,"rows":24,"running":true,"runtime":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","terminal":true}],"v":1}"#
        ),
        (
            WorkspaceControlResponseFrame(
                id: id, ok: true,
                payload: .launchRuntime(.init(
                    runtime: runtime, running: true, rows: 24, columns: 80,
                    terminal: true, inputOwner: false
                ))
            ),
            #"{"cols":80,"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","input":false,"ok":true,"op":"launchRuntime","rows":24,"running":true,"runtime":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","terminal":true,"v":1}"#
        ),
        (
            WorkspaceControlResponseFrame(
                id: id, ok: true,
                payload: .ensureTerminalRuntime(.init(
                    runtime: runtime, running: true,
                    terminal: true, inputOwner: false, created: true
                ))
            ),
            #"{"created":true,"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","input":false,"ok":true,"op":"ensureTerminalRuntime","running":true,"runtime":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","terminal":true,"v":1}"#
        ),
        (
            WorkspaceControlResponseFrame(
                id: id, ok: true,
                payload: .cancelRuntime(.init(runtime: runtime))
            ),
            #"{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","ok":true,"op":"cancelRuntime","runtime":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","v":1}"#
        ),
        (
            WorkspaceControlResponseFrame(id: id, ok: true, payload: .detach),
            #"{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","ok":true,"op":"detach","v":1}"#
        ),
        (
            WorkspaceControlResponseFrame(
                id: id, ok: true,
                payload: .closeWorkspace(.init(
                    workspace: workspace, host: host, phase: "closed",
                    project: "/tmp/demo", attached: 0
                ))
            ),
            #"{"attached":0,"host":"EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE","id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","ok":true,"op":"closeWorkspace","phase":"closed","project":"\/tmp\/demo","v":1,"workspace":"DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"}"#
        ),
        (
            WorkspaceControlResponseFrame(
                ok: true,
                payload: .workspaceClosed(.init(
                    workspace: workspace, host: host, phase: "closed",
                    project: "/tmp/demo", attached: 0
                ))
            ),
            #"{"attached":0,"host":"EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE","ok":true,"op":"workspaceClosed","phase":"closed","project":"\/tmp\/demo","v":1,"workspace":"DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"}"#
        ),
        (
            WorkspaceControlResponseFrame(
                id: id, ok: true,
                payload: .subscribeTerminal(.init(
                    runtime: runtime, rows: 24, columns: 80, terminal: true
                ))
            ),
            #"{"cols":80,"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","ok":true,"op":"subscribeTerminal","rows":24,"runtime":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","terminal":true,"v":1}"#
        ),
        (
            WorkspaceControlResponseFrame(
                id: id, ok: true,
                payload: .unsubscribeTerminal(.init(runtime: runtime))
            ),
            #"{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","ok":true,"op":"unsubscribeTerminal","runtime":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","v":1}"#
        ),
        (
            WorkspaceControlResponseFrame(
                id: id, ok: true,
                payload: .terminalInput(.init(runtime: runtime))
            ),
            #"{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","ok":true,"op":"terminalInput","runtime":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","v":1}"#
        ),
        (
            WorkspaceControlResponseFrame(
                id: id, ok: true,
                payload: .acquireTerminalInput(.init(runtime: runtime, inputOwner: true))
            ),
            #"{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","input":true,"ok":true,"op":"acquireTerminalInput","runtime":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","v":1}"#
        ),
        (
            WorkspaceControlResponseFrame(
                id: id, ok: true,
                payload: .releaseTerminalInput(.init(runtime: runtime, inputOwner: false))
            ),
            #"{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","input":false,"ok":true,"op":"releaseTerminalInput","runtime":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","v":1}"#
        ),
        (
            WorkspaceControlResponseFrame(
                id: id, ok: true,
                payload: .resizeTerminal(.init(runtime: runtime, rows: 30, columns: 100))
            ),
            #"{"cols":100,"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","ok":true,"op":"resizeTerminal","rows":30,"runtime":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","v":1}"#
        ),
        (
            WorkspaceControlResponseFrame(
                ok: true,
                payload: .terminalReplayBegin(.init(
                    runtime: runtime, batch: ControlRPCFixtures.token,
                    truncated: false, replayLength: 6
                ))
            ),
            #"{"batch":"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB","ok":true,"op":"terminalReplayBegin","replayLength":6,"runtime":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","truncated":false,"v":1}"#
        ),
        (
            WorkspaceControlResponseFrame(
                ok: true,
                payload: .terminalReplay(.init(
                    runtime: runtime, sequence: 7,
                    bytes: TerminalBytesCodec.encode(Data("replay".utf8))
                ))
            ),
            #"{"bytes":"cmVwbGF5","ok":true,"op":"terminalReplay","runtime":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","sequence":7,"v":1}"#
        ),
        (
            WorkspaceControlResponseFrame(
                ok: true,
                payload: .terminalReplayEnd(.init(runtime: runtime, batch: ControlRPCFixtures.token))
            ),
            #"{"batch":"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB","ok":true,"op":"terminalReplayEnd","runtime":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","v":1}"#
        ),
        (
            WorkspaceControlResponseFrame(
                ok: true,
                payload: .terminalOutput(.init(
                    runtime: runtime, sequence: 8,
                    bytes: TerminalBytesCodec.encode(Data("output".utf8))
                ))
            ),
            #"{"bytes":"b3V0cHV0","ok":true,"op":"terminalOutput","runtime":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","sequence":8,"v":1}"#
        ),
        (
            WorkspaceControlResponseFrame(
                ok: true,
                payload: .terminalInputOwner(.init(runtime: runtime, inputOwner: true))
            ),
            #"{"input":true,"ok":true,"op":"terminalInputOwner","runtime":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","v":1}"#
        ),
        (
            WorkspaceControlResponseFrame(
                ok: true,
                payload: .terminalWindow(.init(runtime: runtime, rows: 24, columns: 80))
            ),
            #"{"cols":80,"ok":true,"op":"terminalWindow","rows":24,"runtime":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","v":1}"#
        ),
        (
            WorkspaceControlResponseFrame(
                ok: true,
                payload: .runtimeExited(.init(runtime: runtime, running: false, exitStatus: 3))
            ),
            #"{"exit":3,"ok":true,"op":"runtimeExited","running":false,"runtime":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","v":1}"#
        ),
        (
            WorkspaceControlResponseFrame(
                ok: true,
                payload: .terminalOverflow(.init(runtime: runtime))
            ),
            #"{"ok":true,"op":"terminalOverflow","runtime":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","v":1}"#
        ),
        (
            WorkspaceControlResponseFrame.failure(id: id, operation: .ping, code: .invalidRequest),
            #"{"error":"invalidRequest","id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","ok":false,"op":"ping","v":1}"#
        ),
    ]
    for (frame, golden) in cases {
        let body = try #require(WorkspaceControlCodec.encodeResponse(frame))
        #expect(body == Data(golden.utf8), "\(frame.rawOperation) encode drifted from the golden bytes")
        #expect(WorkspaceControlCodec.decodeResponse(body) == .frame(frame), "\(frame.rawOperation) round-trip")
    }
}

@Test func controlRPCUnknownOperationPreservesRawEcho() throws {
    let unknown = Data(
        "{\"v\":1,\"id\":\"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA\",\"op\":\"killProcess\"}".utf8
    )
    guard case .frame(let request) = WorkspaceControlCodec.decodeRequest(unknown) else {
        Issue.record("unknown op must decode so the host can refuse it")
        return
    }
    #expect(request.operation == nil)
    #expect(request.rawOperation == "killProcess")
    #expect(request.payload == .unknown(rawOperation: "killProcess"))
    let failure = WorkspaceControlResponseFrame.failure(request: request, code: .invalidRequest)
    #expect(failure.operation == nil)
    #expect(failure.rawOperation == "killProcess")
    #expect(failure.code == .invalidRequest)
    // Golden bytes captured from the legacy codec's failure echo.
    let golden = Data(
        #"{"error":"invalidRequest","id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","ok":false,"op":"killProcess","v":1}"#.utf8
    )
    #expect(WorkspaceControlCodec.encodeResponse(failure) == golden)
    guard case .frame(let decoded) = WorkspaceControlCodec.decodeResponse(golden) else {
        Issue.record("failure echo must decode")
        return
    }
    #expect(decoded == failure)
    #expect(decoded.payload == .unknown(rawOperation: "killProcess"))
}

@Test func controlRPCDecodeYieldsTypedPayloads() throws {
    // A server→client op arriving as a request stays typed (the host
    // refuses it after authorization, like the legacy op switch did).
    let event = Data(
        "{\"v\":1,\"op\":\"terminalOutput\",\"runtime\":\"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC\"}".utf8
    )
    guard case .frame(let driven) = WorkspaceControlCodec.decodeRequest(event) else {
        Issue.record("event op as request must decode")
        return
    }
    #expect(driven.payload == .unsupported(.terminalOutput))
    #expect(driven.operation == .terminalOutput)
    // Hello carries its token in the payload, not a bag field.
    let hello = Data(
        "{\"v\":1,\"id\":\"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA\",\"op\":\"hello\",\"token\":\"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB\"}".utf8
    )
    guard case .frame(let greeting) = WorkspaceControlCodec.decodeRequest(hello),
        case .hello(let fields) = greeting.payload
    else {
        Issue.record("hello must decode to its payload")
        return
    }
    #expect(fields.token == ControlRPCFixtures.token)
    #expect(greeting.id == ControlRPCFixtures.id)
}

@Test func controlRPCPropagatesInvalidAndIncompatible() {
    let invalid = Data(
        "{\"v\":1,\"id\":\"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA\",\"op\":\"ping\",\"pid\":1}".utf8
    )
    #expect(WorkspaceControlCodec.decodeRequest(invalid) == .invalid)
    #expect(WorkspaceControlCodec.decodeResponse(invalid) == .invalid)
    let incompatible = Data(
        "{\"v\":2,\"id\":\"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA\",\"op\":\"ping\"}".utf8
    )
    #expect(WorkspaceControlCodec.decodeRequest(incompatible) == .incompatible)
    #expect(WorkspaceControlCodec.decodeResponse(incompatible) == .incompatible)
    // The body cap is a property of the wire data: empty and over-cap
    // bodies fail before any field is read.
    #expect(WorkspaceControlCodec.decodeRequest(Data()) == .invalid)
    let overCap = Data(repeating: 0x7B, count: WorkspaceControlLimits.maxBodyBytes + 1)
    #expect(WorkspaceControlCodec.decodeRequest(overCap) == .invalid)
    #expect(WorkspaceControlCodec.decodeResponse(overCap) == .invalid)
}

@Test func controlRPCFailureTypedOverloadShape() throws {
    let failure = WorkspaceControlResponseFrame.failure(
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
    #expect(failure.payload == .ping(.init()))
}

@Test func controlRPCResponseCodeRoundTrips() {
    var response = WorkspaceControlResponseFrame(ok: false, error: "bogus", payload: .ping(.init()))
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

@Test func controlRPCEncodeRejectsOversizedBodiesAndLaunchShapes() throws {
    let oversized = String(repeating: "x", count: WorkspaceControlLimits.maxBodyBytes)
    let bodyRequest = WorkspaceControlRequestFrame(
        id: ControlRPCFixtures.id,
        payload: .launchRuntime(.init(executable: oversized))
    )
    #expect(WorkspaceControlCodec.encodeRequest(bodyRequest) == nil)
    let bodyResponse = WorkspaceControlResponseFrame(
        id: ControlRPCFixtures.id,
        ok: true,
        payload: .describeWorkspace(.init(project: oversized))
    )
    #expect(WorkspaceControlCodec.encodeResponse(bodyResponse) == nil)
    // Encode stays narrower than decode: an over-field-limit executable
    // whose body still fits encodes, and the strict decode refuses it —
    // the legacy codec's exact asymmetry.
    let overField = String(repeating: "x", count: WorkspaceControlLimits.maxExecutableBytes + 1)
    let limited = WorkspaceControlRequestFrame(
        id: ControlRPCFixtures.id,
        payload: .launchRuntime(.init(executable: overField))
    )
    let encoded = try #require(WorkspaceControlCodec.encodeRequest(limited))
    #expect(encoded.count <= WorkspaceControlLimits.maxBodyBytes)
    #expect(WorkspaceControlCodec.decodeRequest(encoded) == .invalid)
    // The launch-shape fits encode does check, fail before send.
    let manyArguments = WorkspaceControlRequestFrame(
        id: ControlRPCFixtures.id,
        payload: .launchRuntime(.init(
            executable: "/bin/sh",
            arguments: Array(repeating: "a", count: WorkspaceControlLimits.maxArguments + 1)
        ))
    )
    #expect(WorkspaceControlCodec.encodeRequest(manyArguments) == nil)
    let badProfile = WorkspaceControlRequestFrame(
        id: ControlRPCFixtures.id,
        payload: .launchRuntime(.init(executable: "/bin/sh", resourceProfileID: "bad id!"))
    )
    #expect(WorkspaceControlCodec.encodeRequest(badProfile) == nil)
    let badDigest = WorkspaceControlRequestFrame(
        id: ControlRPCFixtures.id,
        payload: .launchCustomRuntime(.init(executable: "/bin/sh", customDefinitionDigest: "xyz"))
    )
    #expect(WorkspaceControlCodec.encodeRequest(badDigest) == nil)
}

@Test func controlRPCLimitBatteryRejectsOverLimitFrames() {
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
        "{\"v\":1,\"op\":\"ping\",\"detail\":\"\(over(WorkspaceControlLimits.maxDetailBytes + 1))\"}",
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
        #expect(WorkspaceControlCodec.decodeRequest(data) == .invalid, "\(frame.prefix(80))")
        #expect(WorkspaceControlCodec.decodeResponse(data) == .invalid, "\(frame.prefix(80))")
    }
}
