import Foundation
import Testing
@testable import RVIsolation

@Suite("Terminal stream")
struct TerminalStreamTests {
    @Test func replayKeepsTheNewestBoundedBytes() {
        var buffer = TerminalReplayBuffer()
        var expected = Data()
        for index in 0..<20 {
            let chunk = Data(repeating: UInt8(index), count: 4_000)
            expected.append(chunk)
            buffer.append(sequence: Int64(index + 1), bytes: chunk, limit: TerminalStreamLimits.replayBytes)
        }
        #expect(buffer.byteCount <= TerminalStreamLimits.replayBytes)
        #expect(buffer.byteCount == TerminalStreamLimits.replayBytes)
        let retained = buffer.chunks.reduce(into: Data()) { $0.append($1.bytes) }
        #expect(retained == expected.suffix(TerminalStreamLimits.replayBytes))
        #expect(buffer.chunks.first?.sequence != 1)
    }

    @Test func replayTrimsInsideTheOldestChunk() {
        var buffer = TerminalReplayBuffer()
        buffer.append(sequence: 1, bytes: Data([1, 2, 3, 4]), limit: 6)
        buffer.append(sequence: 2, bytes: Data([5, 6, 7, 8]), limit: 6)
        #expect(buffer.byteCount == 6)
        #expect(buffer.chunks.first?.bytes == Data([3, 4]))
        #expect(buffer.chunks.last?.bytes == Data([5, 6, 7, 8]))
    }

    @Test func subscriberQueueOverflowsAboveTheBound() {
        #expect(TerminalQueue.decide(queued: 0, incoming: 4, limit: 8) == .queued(bytes: 4))
        #expect(TerminalQueue.decide(queued: 8, incoming: 1, limit: 8) == .overflow)
        #expect(TerminalQueue.decide(queued: 5, incoming: 4, limit: 8) == .overflow)
        #expect(TerminalStreamLimits.replayBytes == 65_536)
        #expect(TerminalStreamLimits.subscriberQueueBytes == 65_536)
        #expect(TerminalStreamLimits.accepts(rows: 0, columns: 80) == false)
        #expect(TerminalStreamLimits.accepts(rows: 1, columns: 512))
        #expect(TerminalStreamLimits.accepts(rows: 513, columns: 80) == false)
    }

    @Test func codecRoundTripsArbitraryBytes() throws {
        var bytes = Data([0x00, 0x03, 0x0d, 0x0a, 0x1b, 0x5b, 0x33, 0x31, 0x6d, 0xff, 0xfe, 0xc3])
        bytes.append(contentsOf: [0xf0, 0x9f])
        let encoded = TerminalBytesCodec.encode(bytes)
        let decoded = try #require(
            TerminalBytesCodec.decode(encoded, maximum: TerminalStreamLimits.maximumInputBytes)
        )
        #expect(decoded == bytes)
        #expect(TerminalBytesCodec.decode("not base64!", maximum: 16) == nil)
    }

    @Test func oldClientFramesStillDecode() throws {
        let id = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let ping = Data(#"{"id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","op":"ping","v":1}"#.utf8)
        guard case .message(let message) = WorkspaceControlCodec.decode(ping) else {
            Issue.record("a frame without terminal fields must decode")
            return
        }
        #expect(message.version == 1)
        #expect(message.id == id)
        #expect(message.io == nil)
        #expect(message.rows == nil)
        #expect(message.terminal == nil)
        let launch = Data(
            #"{"executable":"/bin/true","id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","op":"launchRuntime","v":1}"#
                .utf8
        )
        guard case .message(let launched) = WorkspaceControlCodec.decode(launch) else {
            Issue.record("launch without io must decode")
            return
        }
        #expect(launched.io == nil)
        #expect(launched.rows == nil)
        #expect(launched.columns == nil)
        #expect(workspaceLaunchIO(io: nil, rows: nil, columns: nil) == .success(.discard))
        #expect(workspaceLaunchIO(io: "discard", rows: nil, columns: nil) == .success(.discard))
        #expect(workspaceLaunchIO(io: "discard", rows: 24, columns: nil) == .failure(.invalidRequest))
        #expect(workspaceLaunchIO(io: "terminal", rows: 24, columns: 80) == .success(.pseudoTerminal(rows: 24, columns: 80)))
        #expect(workspaceLaunchIO(io: "terminal", rows: 0, columns: 80) == .failure(.invalidRequest))
        #expect(workspaceLaunchIO(io: "terminal", rows: 24, columns: 513) == .failure(.invalidRequest))
        #expect(workspaceLaunchIO(io: "raw", rows: 24, columns: 80) == .failure(.invalidRequest))
    }

    @Test func unknownTerminalFieldFailsClosed() {
        let extra = Data(
            #"{"id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","op":"ping","terminalMode":"raw","v":1}"#.utf8
        )
        #expect(WorkspaceControlCodec.decode(extra) == .invalid)
        let version = Data(#"{"op":"ping","v":2}"#.utf8)
        #expect(WorkspaceControlCodec.decode(version) == .incompatible)
        #expect(WorkspaceControlLimits.version == 1)
        #expect(WorkspaceControlLimits.name == "rv.workspace.v1")
    }

    #if os(Linux)
    @Test func linuxContainedTerminalLaunchStaysRefused() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let marker = tree.workspaceURL.appendingPathComponent("must-not-run")
        let command = try #require(IsolatedCommand(executable: "/bin/true"))
        switch IsolationBackends.apply(
            tree.contained,
            command: command,
            io: .pseudoTerminal(rows: 24, columns: 80)
        ) {
        case .failure(.containedGuaranteesUnsupported):
            break
        case .failure(let error):
            Issue.record("Linux contained PTY launch must stay refused, got \(error)")
        case .success(let run):
            Issue.record("Linux contained PTY launch must stay refused, got exit \(run.exitStatus)")
        }
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
    }
    #endif
}
