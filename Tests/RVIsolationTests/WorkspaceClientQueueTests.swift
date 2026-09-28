#if os(macOS)
import Foundation
import Testing
@testable import RVIsolation

@Suite("Workspace client terminal queue")
struct WorkspaceClientQueueTests {
    @Test func drainsRuntimesFairlyWithoutReorderingOneRuntime() throws {
        let board = EventBoard()
        let a = UUID()
        let b = UUID()
        #expect(board.deliver(output(a, sequence: 1, count: 1)))
        #expect(board.deliver(output(a, sequence: 2, count: 1)))
        #expect(board.deliver(output(b, sequence: 1, count: 1)))

        #expect(try next(board).runtime == a)
        #expect(try next(board).runtime == b)
        let last = try next(board)
        #expect(last.runtime == a)
        #expect(last.sequence == 2)
    }

    @Test func overflowIsAttributedToItsRuntimeAndDoesNotDropAnotherStream() throws {
        let board = EventBoard()
        let flooding = UUID()
        let alsoFlooding = UUID()
        let healthy = UUID()
        for sequence in 1...17 {
            #expect(board.deliver(output(flooding, sequence: Int64(sequence), count: 4_096)))
            #expect(board.deliver(output(alsoFlooding, sequence: Int64(sequence), count: 4_096)))
        }
        #expect(board.deliver(output(healthy, sequence: 1, count: 3)))

        let first = try next(board)
        #expect(first.runtime == flooding)
        #expect(first.op == WorkspaceControlOp.terminalOverflow.rawValue)
        let second = try next(board)
        #expect(second.runtime == alsoFlooding)
        #expect(second.op == WorkspaceControlOp.terminalOverflow.rawValue)
        let third = try next(board)
        #expect(third.runtime == healthy)
        #expect(third.op == WorkspaceControlOp.terminalOutput.rawValue)
        #expect(try board.next(timeout: 0).get() == nil)
    }

    @Test func aggregateAndFrameCapsKeepFloodsBounded() throws {
        let board = EventBoard()
        let a = UUID()
        let b = UUID()
        let c = UUID()
        for sequence in 1...12 {
            #expect(board.deliver(output(a, sequence: Int64(sequence), count: 4_096)))
            #expect(board.deliver(output(b, sequence: Int64(sequence), count: 4_096)))
        }
        for sequence in 1...9 {
            #expect(board.deliver(output(c, sequence: Int64(sequence), count: 4_096)))
        }
        #expect(board.deliver(output(c, sequence: 10, count: 4_096)))
        #expect(board.queuedTerminalBytes <= EventBoard.queueLimit)
        #expect(board.queuedTerminalBytes(for: c) == 0)
        #expect(board.hasOverflowNotice(for: c))
        #expect(board.hasOverflowNotice(for: a) == false)
        #expect(board.hasOverflowNotice(for: b) == false)

        let tiny = EventBoard()
        for sequence in 1...(EventBoard.outputFrameLimit + 1) {
            #expect(tiny.deliver(output(a, sequence: Int64(sequence), count: 1)))
        }
        #expect(tiny.queuedTerminalFrames <= EventBoard.frameLimit)
        #expect(tiny.hasOverflowNotice(for: a))
    }

    @Test func fourHundredShortOutputFramesStayInOrderWithoutOverflow() throws {
        let board = EventBoard()
        let runtime = UUID()
        for sequence in 1...400 {
            #expect(board.deliver(output(runtime, sequence: Int64(sequence), count: 1)))
        }
        #expect(board.hasOverflowNotice(for: runtime) == false)
        for sequence in 1...400 {
            let frame = try next(board)
            #expect(frame.runtime == runtime)
            #expect(frame.sequence == Int64(sequence))
            #expect(frame.op == WorkspaceControlOp.terminalOutput.rawValue)
        }
        #expect(try board.next(timeout: 0).get() == nil)
    }

    @Test func replayBatchBoundariesPreserveOrderAndRuntimeAttribution() throws {
        let board = EventBoard()
        let runtime = UUID()
        let other = UUID()
        let batch = UUID()
        #expect(board.deliver(replayBegin(runtime, batch: batch, truncated: true, byteCount: 3)))
        #expect(board.deliver(replay(runtime, sequence: 55, count: 3)))
        #expect(board.deliver(replayEnd(runtime, batch: batch)))
        #expect(board.deliver(output(runtime, sequence: 56, count: 1)))
        #expect(board.deliver(output(other, sequence: 1, count: 1)))

        let begin = try next(board)
        #expect(begin.runtime == runtime)
        #expect(begin.batch == batch)
        #expect(begin.truncated == true)
        #expect(begin.replayLength == 3)
        #expect(try next(board).runtime == other)
        #expect(try next(board).op == WorkspaceControlOp.terminalReplay.rawValue)
        let end = try next(board)
        #expect(end.op == WorkspaceControlOp.terminalReplayEnd.rawValue)
        #expect(end.batch == batch)
        #expect(try next(board).op == WorkspaceControlOp.terminalOutput.rawValue)
    }

    @Test func overflowDiscardsQueuedReplayMetadataUntilResubscribe() throws {
        let board = EventBoard()
        let runtime = UUID()
        let healthy = UUID()
        let oldBatch = UUID()
        #expect(board.deliver(replayBegin(runtime, batch: oldBatch, truncated: false, byteCount: 4_096)))
        #expect(board.deliver(replay(runtime, sequence: 1, count: 4_096)))
        #expect(board.deliver(replayEnd(runtime, batch: oldBatch)))
        #expect(board.deliver(output(healthy, sequence: 1, count: 1)))
        for sequence in 2...17 {
            #expect(board.deliver(output(runtime, sequence: Int64(sequence), count: 4_096)))
        }
        #expect(board.hasOverflowNotice(for: runtime))
        #expect(board.deliver(replayBegin(runtime, batch: UUID(), truncated: false, byteCount: 0)))
        #expect(board.deliver(replayEnd(runtime, batch: UUID())))
        let notices = [try next(board), try next(board)]
        #expect(notices.contains { $0.runtime == runtime && $0.op == WorkspaceControlOp.terminalOverflow.rawValue })
        #expect(notices.contains { $0.runtime == healthy && $0.op == WorkspaceControlOp.terminalOutput.rawValue })
        #expect(try board.next(timeout: 0).get() == nil)

        board.resetRuntime(runtime)
        let newBatch = UUID()
        #expect(board.deliver(replayBegin(runtime, batch: newBatch, truncated: true, byteCount: 0)))
        #expect(board.deliver(replayEnd(runtime, batch: newBatch)))
        #expect(try next(board).batch == newBatch)
        #expect(try next(board).batch == newBatch)
    }

    @Test func clearingOverflowedAdmitsOutputWithoutWipingBacklog() throws {
        let board = EventBoard()
        let runtime = UUID()
        let healthy = UUID()
        for sequence in 1...17 {
            #expect(board.deliver(output(runtime, sequence: Int64(sequence), count: 4_096)))
        }
        #expect(board.deliver(output(healthy, sequence: 1, count: 3)))
        #expect(board.hasOverflowNotice(for: runtime))
        // A resubscribe clears only the swallow-output mark: the healthy
        // backlog is untouched and fresh output is admitted again.
        board.clearOverflowed(runtime)
        #expect(board.deliver(output(runtime, sequence: 100, count: 3)))
        var ops: [String] = []
        while let message = try board.next(timeout: 0).get() {
            ops.append(message.op)
        }
        #expect(ops.contains(WorkspaceControlOp.terminalOverflow.rawValue))
        #expect(ops.filter { $0 == WorkspaceControlOp.terminalOutput.rawValue }.count == 2)
    }

    @Test func mismatchedReplayBoundaryFailsTheStream() {
        let board = EventBoard()
        let runtime = UUID()
        #expect(board.deliver(replayBegin(runtime, batch: UUID(), truncated: false, byteCount: 0)))
        #expect(board.deliver(replayEnd(runtime, batch: UUID())) == false)
        #expect(board.failure == .malformed)
        #expect(board.next(timeout: 0).isFailure(.malformed))
    }

    @Test func firstOutputFromAnotherRuntimeReclaimsTheFloodingRuntime() throws {
        let board = EventBoard()
        let flooding = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let newcomer = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        for sequence in 1...EventBoard.outputFrameLimit {
            #expect(board.deliver(output(flooding, sequence: Int64(sequence), count: 1)))
        }
        #expect(board.deliver(output(newcomer, sequence: 1, count: 1)))
        #expect(board.hasOverflowNotice(for: flooding))
        #expect(board.hasOverflowNotice(for: newcomer) == false)
        #expect(try next(board).runtime == flooding)
        let firstNew = try next(board)
        #expect(firstNew.runtime == newcomer)
        #expect(firstNew.op == WorkspaceControlOp.terminalOutput.rawValue)
    }

    @Test func firstOutputSurvivesAnAggregateByteCapFilledByOtherRuntimes() throws {
        let board = EventBoard()
        let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let newcomer = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        for sequence in 1...16 {
            #expect(board.deliver(output(a, sequence: Int64(sequence), count: 4_096)))
            #expect(board.deliver(output(b, sequence: Int64(sequence), count: 4_096)))
        }
        #expect(board.queuedTerminalBytes == EventBoard.queueLimit)
        #expect(board.deliver(output(newcomer, sequence: 1, count: 4_096)))
        #expect(board.hasOverflowNotice(for: a))
        #expect(board.hasOverflowNotice(for: newcomer) == false)
        #expect(board.queuedTerminalBytes(for: newcomer) == 4_096)
    }

    @Test func exitIsNotStarvedByAnotherRuntimeAndSurvivesDisconnect() throws {
        let board = EventBoard()
        let flooding = UUID()
        let exiting = UUID()
        for sequence in 1...12 {
            #expect(board.deliver(output(flooding, sequence: Int64(sequence), count: 4_096)))
        }
        #expect(board.deliver(output(exiting, sequence: 1, count: 2)))
        #expect(board.deliver(
            WorkspaceControlMessage(
                version: WorkspaceControlLimits.version,
                op: WorkspaceControlOp.runtimeExited.rawValue,
                runtime: exiting,
                exitStatus: 7
            )
        ))
        board.failAll(.disconnected)

        let finalOutput = try next(board)
        #expect(finalOutput.runtime == exiting)
        #expect(finalOutput.sequence == 1)
        let exit = try next(board)
        #expect(exit.runtime == exiting)
        #expect(exit.op == WorkspaceControlOp.runtimeExited.rawValue)
        #expect(exit.exitStatus == 7)
    }

    @Test func excessControlFramesFailTheStreamExplicitly() {
        let board = EventBoard()
        for _ in 1...EventBoard.frameLimit {
            #expect(board.deliver(owner(UUID())))
        }
        #expect(board.queuedTerminalFrames == EventBoard.frameLimit)
        #expect(board.deliver(owner(UUID())) == false)
        #expect(board.failure == .queueOverloaded)
        #expect(board.queuedTerminalFrames == EventBoard.frameLimit)
        #expect(board.next(timeout: 0).isFailure(.queueOverloaded))
        #expect(board.deliver(owner(UUID())) == false)
    }

    @Test func resettingOneSubscriptionPreservesAnotherRuntime() throws {
        let board = EventBoard()
        let old = UUID()
        let other = UUID()
        #expect(board.deliver(output(old, sequence: 1, count: 3)))
        #expect(board.deliver(output(other, sequence: 1, count: 4)))
        board.resetRuntime(old)
        #expect(board.queuedTerminalBytes(for: old) == 0)
        #expect(board.queuedTerminalBytes(for: other) == 4)
        #expect(try next(board).runtime == other)
    }

    private func output(_ runtime: UUID, sequence: Int64, count: Int) -> WorkspaceControlMessage {
        WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            op: WorkspaceControlOp.terminalOutput.rawValue,
            runtime: runtime,
            sequence: sequence,
            bytes: TerminalBytesCodec.encode(Data(repeating: 0x61, count: count))
        )
    }

    private func owner(_ runtime: UUID) -> WorkspaceControlMessage {
        WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            op: WorkspaceControlOp.terminalInputOwner.rawValue,
            runtime: runtime,
            inputOwner: true
        )
    }

    @Test func windowNoticesDeliverAndCoalesceToLatest() throws {
        let board = EventBoard()
        let runtime = UUID()
        #expect(board.deliver(window(runtime, rows: 24, columns: 80)))
        #expect(board.deliver(window(runtime, rows: 17, columns: 53)))
        let only = try next(board)
        #expect(only.op == WorkspaceControlOp.terminalWindow.rawValue)
        #expect(only.rows == 17)
        #expect(only.columns == 53)
        #expect(try board.next(timeout: 0).get() == nil)
    }

    private func window(_ runtime: UUID, rows: Int, columns: Int) -> WorkspaceControlMessage {
        WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            op: WorkspaceControlOp.terminalWindow.rawValue,
            runtime: runtime,
            rows: rows,
            columns: columns
        )
    }

    private func replayBegin(
        _ runtime: UUID,
        batch: UUID,
        truncated: Bool,
        byteCount: Int
    ) -> WorkspaceControlMessage {
        WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            op: WorkspaceControlOp.terminalReplayBegin.rawValue,
            runtime: runtime,
            batch: batch,
            truncated: truncated,
            replayLength: byteCount
        )
    }

    private func replay(_ runtime: UUID, sequence: Int64, count: Int) -> WorkspaceControlMessage {
        WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            op: WorkspaceControlOp.terminalReplay.rawValue,
            runtime: runtime,
            sequence: sequence,
            bytes: TerminalBytesCodec.encode(Data(repeating: 0x61, count: count))
        )
    }

    private func replayEnd(_ runtime: UUID, batch: UUID) -> WorkspaceControlMessage {
        WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            op: WorkspaceControlOp.terminalReplayEnd.rawValue,
            runtime: runtime,
            batch: batch
        )
    }

    private func next(_ board: EventBoard) throws -> WorkspaceControlMessage {
        let message = try board.next(timeout: 0).get()
        return try #require(message)
    }
}
#endif
