import Foundation
import Testing
@testable import RVIsolation

@Suite("Terminal stream")
struct TerminalStreamTests {
    @Test func replayKeepsTheNewestBoundedBytes() {
        var buffer = TerminalReplayBuffer()
        var expected = Data()
        var next = Int64(1)
        for index in 0..<20 {
            let chunk = Data(repeating: UInt8(index), count: 4_000)
            expected.append(chunk)
            let sequence = next
            next += 1
            buffer.append(
                sequence: sequence,
                bytes: chunk,
                limit: TerminalStreamLimits.replayBytes,
                nextSequence: &next
            )
        }
        #expect(buffer.byteCount <= TerminalStreamLimits.replayBytes)
        #expect(buffer.byteCount == TerminalStreamLimits.replayBytes)
        let retained = buffer.chunks.reduce(into: Data()) { $0.append($1.bytes) }
        #expect(retained == expected.suffix(TerminalStreamLimits.replayBytes))
        #expect(buffer.chunks.first?.sequence != 1)
    }

    @Test func replayTrimsInsideTheOldestChunk() {
        var buffer = TerminalReplayBuffer()
        var next = Int64(3)
        buffer.append(sequence: 1, bytes: Data([1, 2, 3, 4]), limit: 6, nextSequence: &next)
        buffer.append(sequence: 2, bytes: Data([5, 6, 7, 8]), limit: 6, nextSequence: &next)
        #expect(buffer.byteCount == 6)
        #expect(buffer.chunks.first?.bytes == Data([3, 4]))
        #expect(buffer.chunks.last?.bytes == Data([5, 6, 7, 8]))
        let sequences = buffer.chunks.map(\.sequence)
        #expect(sequences.allSatisfy { $0 != 1 && $0 != 2 })
        #expect(zip(sequences, sequences.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func terminalRulesKeepTheNonceDrainAndPartialWrite() {
        #expect(terminalDrainShouldContinue(.data))
        #expect(terminalDrainShouldContinue(.interrupted))
        #expect(terminalDrainShouldContinue(.wouldBlock) == false)
        #expect(terminalDrainShouldContinue(.end) == false)
        let nonce = Data("nonce".utf8)
        #expect(deadLeaderClaimedByHandshake(queued: nonce + Data([1]), nonce: nonce))
        #expect(deadLeaderClaimedByHandshake(queued: Data("no".utf8), nonce: nonce) == false)
        #expect(deadLeaderClaimedByHandshake(queued: Data("xnonce".utf8), nonce: nonce) == false)
        #expect(terminalWriteOutcome(written: 0, hardFailure: false) == .flushed)
        #expect(terminalWriteOutcome(written: 4, hardFailure: true) == .prefixCommitted)
        #expect(terminalWriteOutcome(written: 0, hardFailure: true) == .failed)
        #expect(admitClientTerminalBytes(queued: 100, incoming: 20, limit: 128) == .accept(queued: 120))
        #expect(admitClientTerminalBytes(queued: 100, incoming: 40, limit: 128) == .overflow)
        #expect(
            planClientTerminalFrame(queued: 65_536, incoming: 1, limit: 65_536) == .overflow
        )
        #expect(
            planClientTerminalFrame(queued: 65_536, incoming: 0, limit: 65_536) == .store(queued: 65_536)
        )
        #expect(
            TerminalQueue.decide(queued: 65_536, incoming: 1, limit: 65_536) == .overflow
        )
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

    @Test func capabilityRepliesRoundTripWithinTheirBounds() {
        let message = WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            id: UUID(),
            op: WorkspaceControlOp.capabilities.rawValue,
            ok: true,
            features: [WorkspaceControlFeature.ensureTerminalRuntime]
        )
        guard let encoded = WorkspaceControlCodec.encode(message),
            case .message(let decoded) = WorkspaceControlCodec.decode(encoded)
        else {
            Issue.record("capabilities reply should round-trip")
            return
        }
        #expect(decoded.features == [WorkspaceControlFeature.ensureTerminalRuntime])

        let tooMany = Array(repeating: "x", count: WorkspaceControlLimits.maxFeatures + 1)
        let oversized = WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            id: UUID(),
            op: WorkspaceControlOp.capabilities.rawValue,
            ok: true,
            features: tooMany
        )
        guard let oversizedBytes = WorkspaceControlCodec.encode(oversized) else {
            Issue.record("bounded capability test frame should fit the control frame")
            return
        }
        #expect(WorkspaceControlCodec.decode(oversizedBytes) == .invalid)
    }

    #if os(Linux)
    @Test func linuxContainedTerminalLaunchStaysRefused() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let marker = tree.workspaceURL.appendingPathComponent("must-not-run")
        let command = try #require(IsolatedCommand(executable: "/bin/true"))
        switch await IsolationBackends.applyOffPool(
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
