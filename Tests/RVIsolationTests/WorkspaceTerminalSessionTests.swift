#if os(macOS)
import Foundation
import Testing
@testable import RVIsolation

@Suite("Workspace terminal session")
struct WorkspaceTerminalSessionTests {
    private static let runtime = UUID()
    private static let foreign = UUID()
    private static let batch = UUID()

    private static func event(
        _ body: WorkspaceTerminalEvent.Body,
        runtime: UUID = runtime
    ) -> Result<WorkspaceTerminalRead, WorkspaceClientFailure> {
        .success(.event(WorkspaceTerminalEvent(runtime: runtime, body: body)))
    }

    struct StepCase: Sendable, CustomTestStringConvertible {
        var name: String
        var read: Result<WorkspaceTerminalRead, WorkspaceClientFailure>
        var expected: WorkspaceTerminalSession.Step
        var testDescription: String { name }
    }

    static let stepCases: [StepCase] = [
        StepCase(name: "wait expired", read: .success(.waiting), expected: .idle),
        StepCase(
            name: "foreign output",
            read: event(.output(sequence: 1, bytes: Data("x".utf8)), runtime: foreign),
            expected: .idle
        ),
        StepCase(name: "foreign exit", read: event(.exited(4), runtime: foreign), expected: .idle),
        StepCase(name: "foreign overflow", read: event(.overflow, runtime: foreign), expected: .idle),
        StepCase(
            name: "replay bytes",
            read: event(.replay(sequence: 1, bytes: Data("old".utf8))),
            expected: .write(Data("old".utf8))
        ),
        StepCase(
            name: "output bytes",
            read: event(.output(sequence: 2, bytes: Data("new".utf8))),
            expected: .write(Data("new".utf8))
        ),
        StepCase(
            name: "replay begin",
            read: event(.replayBegin(batch: batch, truncated: true, byteCount: 3)),
            expected: .idle
        ),
        StepCase(name: "replay end", read: event(.replayEnd(batch: batch)), expected: .idle),
        StepCase(name: "input owner", read: event(.inputOwner(false)), expected: .idle),
        StepCase(name: "window notice", read: event(.window(rows: 30, columns: 100)), expected: .idle),
        StepCase(name: "exit status", read: event(.exited(7)), expected: .exited(7)),
        StepCase(name: "overflow", read: event(.overflow), expected: .failed(.fellBehind)),
        StepCase(name: "workspace closed", read: .failure(.workspaceClosed), expected: .failed(.client(.workspaceClosed))),
        StepCase(name: "disconnect", read: .failure(.disconnected), expected: .failed(.client(.disconnected))),
        StepCase(name: "bad frame", read: .failure(.malformed), expected: .failed(.client(.malformed))),
    ]

    @Test(arguments: stepCases)
    func stepMapsEachTerminalRead(_ row: StepCase) {
        #expect(WorkspaceTerminalSession.step(row.read, runtime: Self.runtime) == row.expected)
    }

    struct InputEndCase: Sendable, CustomTestStringConvertible {
        var ownsInput: Bool
        var abandonOnInputEnd: Bool
        var inputEnded: Bool
        var ends: Bool
        var testDescription: String {
            "owns=\(ownsInput) abandon=\(abandonOnInputEnd) ended=\(inputEnded)"
        }
    }

    /// Only an owned, interactive input that ended abandons the run. A pipe
    /// or /dev/null EOFs at once and must not cut a slow command short.
    static let inputEndCases: [InputEndCase] = [false, true].flatMap { owns in
        [false, true].flatMap { abandon in
            [false, true].map { ended in
                InputEndCase(
                    ownsInput: owns, abandonOnInputEnd: abandon, inputEnded: ended,
                    ends: owns && abandon && ended
                )
            }
        }
    }

    @Test(arguments: inputEndCases)
    func endsOnInputOnlyForOwnedInteractiveEOF(_ row: InputEndCase) {
        #expect(
            WorkspaceTerminalSession.endsOnInput(
                ownsInput: row.ownsInput,
                abandonOnInputEnd: row.abandonOnInputEnd,
                inputEnded: row.inputEnded
            ) == row.ends
        )
    }

    @Test func endsOnInputTruthTableHasOneTrueRow() {
        #expect(Self.inputEndCases.count == 8)
        #expect(Self.inputEndCases.filter(\.ends).count == 1)
    }
}
#endif
