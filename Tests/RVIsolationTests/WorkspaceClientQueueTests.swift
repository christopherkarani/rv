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
        #expect(board.deliver(Self.output(a, sequence: 1, count: 1)))
        #expect(board.deliver(Self.output(a, sequence: 2, count: 1)))
        #expect(board.deliver(Self.output(b, sequence: 1, count: 1)))

        #expect(try Self.next(board).runtime == a)
        #expect(try Self.next(board).runtime == b)
        let last = try Self.next(board)
        #expect(last.runtime == a)
        #expect(last.sequence == 2)
    }

    @Test func overflowIsAttributedToItsRuntimeAndDoesNotDropAnotherStream() throws {
        let board = EventBoard()
        let flooding = UUID()
        let alsoFlooding = UUID()
        let healthy = UUID()
        for sequence in 1...17 {
            #expect(board.deliver(Self.output(flooding, sequence: Int64(sequence), count: 4_096)))
            #expect(board.deliver(Self.output(alsoFlooding, sequence: Int64(sequence), count: 4_096)))
        }
        #expect(board.deliver(Self.output(healthy, sequence: 1, count: 3)))

        let first = try Self.next(board)
        #expect(first.runtime == flooding)
        #expect(first.operation == .terminalOverflow)
        let second = try Self.next(board)
        #expect(second.runtime == alsoFlooding)
        #expect(second.operation == .terminalOverflow)
        let third = try Self.next(board)
        #expect(third.runtime == healthy)
        #expect(third.operation == .terminalOutput)
        #expect(try board.next(timeout: 0).get() == nil)
    }

    @Test func aggregateAndFrameCapsKeepFloodsBounded() throws {
        let board = EventBoard()
        let a = UUID()
        let b = UUID()
        let c = UUID()
        for sequence in 1...12 {
            #expect(board.deliver(Self.output(a, sequence: Int64(sequence), count: 4_096)))
            #expect(board.deliver(Self.output(b, sequence: Int64(sequence), count: 4_096)))
        }
        for sequence in 1...9 {
            #expect(board.deliver(Self.output(c, sequence: Int64(sequence), count: 4_096)))
        }
        #expect(board.deliver(Self.output(c, sequence: 10, count: 4_096)))
        #expect(board.queuedTerminalBytes <= EventBoard.queueLimit)
        #expect(board.queuedTerminalBytes(for: c) == 0)
        #expect(board.hasOverflowNotice(for: c))
        #expect(board.hasOverflowNotice(for: a) == false)
        #expect(board.hasOverflowNotice(for: b) == false)

        let tiny = EventBoard()
        for sequence in 1...(EventBoard.outputFrameLimit + 1) {
            #expect(tiny.deliver(Self.output(a, sequence: Int64(sequence), count: 1)))
        }
        #expect(tiny.queuedTerminalFrames <= EventBoard.frameLimit)
        #expect(tiny.hasOverflowNotice(for: a))
    }

    @Test func fourHundredShortOutputFramesStayInOrderWithoutOverflow() throws {
        let board = EventBoard()
        let runtime = UUID()
        for sequence in 1...400 {
            #expect(board.deliver(Self.output(runtime, sequence: Int64(sequence), count: 1)))
        }
        #expect(board.hasOverflowNotice(for: runtime) == false)
        for sequence in 1...400 {
            let frame = try Self.next(board)
            #expect(frame.runtime == runtime)
            #expect(frame.sequence == Int64(sequence))
            #expect(frame.operation == .terminalOutput)
        }
        #expect(try board.next(timeout: 0).get() == nil)
    }

    @Test func replayBatchBoundariesPreserveOrderAndRuntimeAttribution() throws {
        let board = EventBoard()
        let runtime = UUID()
        let other = UUID()
        let batch = UUID()
        #expect(board.deliver(Self.replayBegin(runtime, batch: batch, truncated: true, byteCount: 3)))
        #expect(board.deliver(Self.replay(runtime, sequence: 55, count: 3)))
        #expect(board.deliver(Self.replayEnd(runtime, batch: batch)))
        #expect(board.deliver(Self.output(runtime, sequence: 56, count: 1)))
        #expect(board.deliver(Self.output(other, sequence: 1, count: 1)))

        let begin = try Self.next(board)
        #expect(begin.runtime == runtime)
        #expect(begin.batch == batch)
        #expect(begin.truncated == true)
        #expect(begin.replayLength == 3)
        #expect(try Self.next(board).runtime == other)
        #expect(try Self.next(board).operation == .terminalReplay)
        let end = try Self.next(board)
        #expect(end.operation == .terminalReplayEnd)
        #expect(end.batch == batch)
        #expect(try Self.next(board).operation == .terminalOutput)
    }

    @Test func overflowDiscardsQueuedReplayMetadataUntilResubscribe() throws {
        let board = EventBoard()
        let runtime = UUID()
        let healthy = UUID()
        let oldBatch = UUID()
        #expect(board.deliver(Self.replayBegin(runtime, batch: oldBatch, truncated: false, byteCount: 4_096)))
        #expect(board.deliver(Self.replay(runtime, sequence: 1, count: 4_096)))
        #expect(board.deliver(Self.replayEnd(runtime, batch: oldBatch)))
        #expect(board.deliver(Self.output(healthy, sequence: 1, count: 1)))
        for sequence in 2...17 {
            #expect(board.deliver(Self.output(runtime, sequence: Int64(sequence), count: 4_096)))
        }
        #expect(board.hasOverflowNotice(for: runtime))
        #expect(board.deliver(Self.replayBegin(runtime, batch: UUID(), truncated: false, byteCount: 0)))
        #expect(board.deliver(Self.replayEnd(runtime, batch: UUID())))
        let notices = [try Self.next(board), try Self.next(board)]
        #expect(notices.contains { $0.runtime == runtime && $0.operation == .terminalOverflow })
        #expect(notices.contains { $0.runtime == healthy && $0.operation == .terminalOutput })
        #expect(try board.next(timeout: 0).get() == nil)

        board.resetRuntime(runtime)
        let newBatch = UUID()
        #expect(board.deliver(Self.replayBegin(runtime, batch: newBatch, truncated: true, byteCount: 0)))
        #expect(board.deliver(Self.replayEnd(runtime, batch: newBatch)))
        #expect(try Self.next(board).batch == newBatch)
        #expect(try Self.next(board).batch == newBatch)
    }

    @Test func clearingOverflowedAdmitsOutputWithoutWipingBacklog() throws {
        let board = EventBoard()
        let runtime = UUID()
        let healthy = UUID()
        for sequence in 1...17 {
            #expect(board.deliver(Self.output(runtime, sequence: Int64(sequence), count: 4_096)))
        }
        #expect(board.deliver(Self.output(healthy, sequence: 1, count: 3)))
        #expect(board.hasOverflowNotice(for: runtime))
        // A resubscribe clears only the swallow-output mark: the healthy
        // backlog is untouched and fresh output is admitted again.
        board.clearOverflowed(runtime)
        #expect(board.deliver(Self.output(runtime, sequence: 100, count: 3)))
        var ops: [WorkspaceControlOp?] = []
        while let message = try board.next(timeout: 0).get() {
            ops.append(message.operation)
        }
        #expect(ops.contains(.terminalOverflow))
        #expect(ops.filter { $0 == .terminalOutput }.count == 2)
    }

    @Test func mismatchedReplayBoundaryOverflowsOnlyItsRuntime() throws {
        let board = EventBoard()
        let runtime = UUID()
        let healthy = UUID()
        #expect(board.deliver(Self.replayBegin(runtime, batch: UUID(), truncated: false, byteCount: 0)))
        #expect(board.deliver(Self.output(healthy, sequence: 1, count: 3)))
        // The out-of-order frame is consumed as its runtime's loss; the
        // board stays healthy and the other runtime's bytes survive.
        #expect(board.deliver(Self.replayEnd(runtime, batch: UUID())))
        #expect(board.failure == nil)
        #expect(board.hasOverflowNotice(for: runtime))
        #expect(board.queuedTerminalBytes(for: runtime) == 0)
        let notices = [try Self.next(board), try Self.next(board)]
        #expect(notices.contains { $0.runtime == runtime && $0.operation == .terminalOverflow })
        #expect(notices.contains { $0.runtime == healthy && $0.operation == .terminalOutput })
        #expect(try board.next(timeout: 0).get() == nil)
    }

    @Test func unframedReplayIsAdmittedForLegacyHosts() throws {
        let board = EventBoard()
        board.supportsReplayBatches = false
        let runtime = UUID()
        #expect(board.deliver(Self.replay(runtime, sequence: 1, count: 3)))
        let frame = try Self.next(board)
        #expect(frame.runtime == runtime)
        #expect(frame.operation == .terminalReplay)
        #expect(try board.next(timeout: 0).get() == nil)
    }

    @Test func concurrentDeliverAndNextKeepByteAccountingExact() {
        let board = EventBoard()
        let runtimes = (0..<4).map { _ in UUID() }
        let produced = DispatchGroup()
        for runtime in runtimes {
            produced.enter()
            DispatchQueue.global().async {
                for sequence in 1...200 {
                    _ = board.deliver(Self.output(runtime, sequence: Int64(sequence), count: 8))
                }
                produced.leave()
            }
        }
        // Drain on the test thread while producers run: eviction may drop
        // frames, but the budget must reconcile exactly once quiescent.
        var drained = 0
        while true {
            switch board.next(timeout: 0.05) {
            case .success(let message):
                if message != nil {
                    drained += 1
                    continue
                }
                guard produced.wait(timeout: .now()) == .success,
                    case .success(nil) = board.next(timeout: 0.05)
                else {
                    continue
                }
                #expect(board.failure == nil)
                #expect(board.queuedTerminalBytes == 0)
                #expect(board.queuedTerminalFrames == 0)
                #expect(drained > 0)
                return
            case .failure(let error):
                Issue.record("board failed under concurrent load: \(error)")
                return
            }
        }
    }

    @Test func firstOutputFromAnotherRuntimeReclaimsTheFloodingRuntime() throws {
        let board = EventBoard()
        let flooding = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let newcomer = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        for sequence in 1...EventBoard.outputFrameLimit {
            #expect(board.deliver(Self.output(flooding, sequence: Int64(sequence), count: 1)))
        }
        #expect(board.deliver(Self.output(newcomer, sequence: 1, count: 1)))
        #expect(board.hasOverflowNotice(for: flooding))
        #expect(board.hasOverflowNotice(for: newcomer) == false)
        #expect(try Self.next(board).runtime == flooding)
        let firstNew = try Self.next(board)
        #expect(firstNew.runtime == newcomer)
        #expect(firstNew.operation == .terminalOutput)
    }

    @Test func firstOutputSurvivesAnAggregateByteCapFilledByOtherRuntimes() throws {
        let board = EventBoard()
        let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let newcomer = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        for sequence in 1...16 {
            #expect(board.deliver(Self.output(a, sequence: Int64(sequence), count: 4_096)))
            #expect(board.deliver(Self.output(b, sequence: Int64(sequence), count: 4_096)))
        }
        #expect(board.queuedTerminalBytes == EventBoard.queueLimit)
        #expect(board.deliver(Self.output(newcomer, sequence: 1, count: 4_096)))
        #expect(board.hasOverflowNotice(for: a))
        #expect(board.hasOverflowNotice(for: newcomer) == false)
        #expect(board.queuedTerminalBytes(for: newcomer) == 4_096)
    }

    @Test func exitIsNotStarvedByAnotherRuntimeAndSurvivesDisconnect() throws {
        let board = EventBoard()
        let flooding = UUID()
        let exiting = UUID()
        for sequence in 1...12 {
            #expect(board.deliver(Self.output(flooding, sequence: Int64(sequence), count: 4_096)))
        }
        #expect(board.deliver(Self.output(exiting, sequence: 1, count: 2)))
        #expect(board.deliver(
            WorkspaceControlResponse(
                operation: .runtimeExited,
                runtime: exiting,
                exitStatus: 7
            )
        ))
        board.failAll(.disconnected)

        let finalOutput = try Self.next(board)
        #expect(finalOutput.runtime == exiting)
        #expect(finalOutput.sequence == 1)
        let exit = try Self.next(board)
        #expect(exit.runtime == exiting)
        #expect(exit.operation == .runtimeExited)
        #expect(exit.exitStatus == 7)
    }

    @Test func excessControlFramesFailTheStreamExplicitly() {
        let board = EventBoard()
        for _ in 1...EventBoard.frameLimit {
            #expect(board.deliver(Self.owner(UUID())))
        }
        #expect(board.queuedTerminalFrames == EventBoard.frameLimit)
        #expect(board.deliver(Self.owner(UUID())) == false)
        #expect(board.failure == .queueOverloaded)
        #expect(board.queuedTerminalFrames == EventBoard.frameLimit)
        #expect(board.next(timeout: 0).isFailure(.queueOverloaded))
        #expect(board.deliver(Self.owner(UUID())) == false)
    }

    @Test func resettingOneSubscriptionPreservesAnotherRuntime() throws {
        let board = EventBoard()
        let old = UUID()
        let other = UUID()
        #expect(board.deliver(Self.output(old, sequence: 1, count: 3)))
        #expect(board.deliver(Self.output(other, sequence: 1, count: 4)))
        board.resetRuntime(old)
        #expect(board.queuedTerminalBytes(for: old) == 0)
        #expect(board.queuedTerminalBytes(for: other) == 4)
        #expect(try Self.next(board).runtime == other)
    }

    private static func output(_ runtime: UUID, sequence: Int64, count: Int) -> WorkspaceControlResponse {
        WorkspaceControlResponse(
            operation: .terminalOutput,
            runtime: runtime,
            sequence: sequence,
            bytes: TerminalBytesCodec.encode(Data(repeating: 0x61, count: count))
        )
    }

    private static func owner(_ runtime: UUID) -> WorkspaceControlResponse {
        WorkspaceControlResponse(
            operation: .terminalInputOwner,
            runtime: runtime,
            inputOwner: true
        )
    }

    @Test func windowNoticesDeliverAndCoalesceToLatest() throws {
        let board = EventBoard()
        let runtime = UUID()
        #expect(board.deliver(Self.window(runtime, rows: 24, columns: 80)))
        #expect(board.deliver(Self.window(runtime, rows: 17, columns: 53)))
        let only = try Self.next(board)
        #expect(only.operation == .terminalWindow)
        #expect(only.rows == 17)
        #expect(only.columns == 53)
        #expect(try board.next(timeout: 0).get() == nil)
    }

    private static func window(_ runtime: UUID, rows: Int, columns: Int) -> WorkspaceControlResponse {
        WorkspaceControlResponse(
            operation: .terminalWindow,
            runtime: runtime,
            rows: rows,
            columns: columns
        )
    }

    private static func replayBegin(
        _ runtime: UUID,
        batch: UUID,
        truncated: Bool,
        byteCount: Int
    ) -> WorkspaceControlResponse {
        WorkspaceControlResponse(
            operation: .terminalReplayBegin,
            runtime: runtime,
            batch: batch,
            truncated: truncated,
            replayLength: byteCount
        )
    }

    private static func replay(_ runtime: UUID, sequence: Int64, count: Int) -> WorkspaceControlResponse {
        WorkspaceControlResponse(
            operation: .terminalReplay,
            runtime: runtime,
            sequence: sequence,
            bytes: TerminalBytesCodec.encode(Data(repeating: 0x61, count: count))
        )
    }

    private static func replayEnd(_ runtime: UUID, batch: UUID) -> WorkspaceControlResponse {
        WorkspaceControlResponse(
            operation: .terminalReplayEnd,
            runtime: runtime,
            batch: batch
        )
    }

    private static func next(_ board: EventBoard) throws -> WorkspaceControlResponse {
        let message = try board.next(timeout: 0).get()
        return try #require(message)
    }
}
#endif
