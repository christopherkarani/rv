import Foundation
import RVIsolation
import Synchronization
import Testing
@testable import RVCLI

/// L5, the review on the way home, end to end on real folders: the words
/// it shows, each answer, and that the box only closes once the choice is
/// applied. A closure stands in for the workspace host's close.
@Suite("rv box done brings changes home as a review")
struct BoxDoneFlowTests {
    /// The saved tree, the box, and what the flow wrote and closed.
    final class Run: Sendable {
        let root: URL
        let start: Date
        private let state = Mutex<(output: String, closed: Int)>(("", 0))

        var saved: String { root.appendingPathComponent("code/.rv-saved-0123456789ab").path }
        var box: String { root.appendingPathComponent("code/app").path }
        var output: String { state.withLock { $0.output } }
        var closed: Int { state.withLock { $0.closed } }

        init(original: [String: String], agent: [String: String?], you: [String: String?] = [:]) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("rv-box-done-flow-\(UUID().uuidString)", isDirectory: true)
            let saved = root.appendingPathComponent("code/.rv-saved-0123456789ab").path
            let box = root.appendingPathComponent("code/app").path
            for directory in [saved, box] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                for (path, text) in original { try Self.put(text, at: directory + "/" + path) }
            }
            Thread.sleep(forTimeInterval: 0.05)
            start = Date()
            Thread.sleep(forTimeInterval: 0.05)
            for (path, text) in agent { try Self.put(text, at: box + "/" + path) }
            for (path, text) in you { try Self.put(text, at: saved + "/" + path) }
        }

        static func put(_ text: String?, at path: String) throws {
            guard let text else {
                try FileManager.default.removeItem(atPath: path)
                return
            }
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        }

        func machine(
            answers: [String], terminal: Bool = true, running: Int = 0, refuseClose: String? = nil,
            agent: String? = "claude"
        ) -> BoxDoneMachine {
            let queue = Answers(answers)
            return BoxDoneMachine(
                source: BoxHomecomingSource(project: box, savedRoot: saved, startedAt: start),
                boxRoot: box,
                stillRunning: running,
                agent: agent,
                home: root.path,
                trash: BoxTrash(root: root.appendingPathComponent("box-trash")),
                // Four minutes after the box started.
                now: { self.start.addingTimeInterval(4 * 60 + 5) },
                isTerminal: terminal,
                ask: { prompt in
                    let answer = queue.next()
                    self.state.withLock { $0.output += prompt + (answer ?? "") + "\n" }
                    return answer
                },
                write: { text in self.state.withLock { $0.output += text } },
                close: {
                    self.state.withLock { $0.closed += 1 }
                    return refuseClose
                })
        }

        func text(_ path: String) -> String? {
            FileManager.default.contents(atPath: box + "/" + path).map { String(decoding: $0, as: UTF8.self) }
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    /// The person's typed lines, in order.
    final class Answers {
        private var left: [String]
        init(_ answers: [String]) { left = answers }
        func next() -> String? { left.isEmpty ? nil : left.removeFirst() }
    }

    static let original = [
        "src/checkout/clock.ts": (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n",
        "test/checkout.spec.ts": "it('ticks')\n",
        "notes.md": "mine\n",
        "README.md": "hello\n",
    ]

    static func agentWork() throws -> Run {
        try Run(
            original: original,
            agent: [
                "src/checkout/clock.ts": (1...10).map { $0 == 3 ? "line three" : "line \($0)" }.joined(separator: "\n")
                    + "\n" + (1...37).map { "new \($0)" }.joined(separator: "\n") + "\n",
                "test/checkout.spec.ts": "it('ticks')\nit('stops sharing a clock')\n",
                "README.md": nil,
            ],
            you: ["notes.md": "mine, edited while the box ran\n"])
    }

    @Test func yesBringsItAllHome_andYourNewerEditStays() throws {
        let run = try Self.agentWork()
        let outcome = BoxDoneFlow.run(run.machine(answers: ["y"]))
        #expect(run.output == """
            ◆ rv claude changed 3 files · 4 min in the box
              src/checkout/clock.ts   +38 −1
              README.md               removed · −1
              test/checkout.spec.ts   +1 −0
              ◐ notes.md · you changed it outside the box · yours stays
              Bring it home? y yes  p pick  d drop  n keep in box y
              ✓ Home. 3 files · nothing left behind

            """)
        guard case .home(let plan) = outcome else {
            Issue.record("yes must bring it home")
            return
        }
        #expect(plan.keptFiles == 3)
        #expect(run.closed == 1)
        #expect(run.text("notes.md") == "mine, edited while the box ran\n")
        #expect(run.text("README.md") == nil)
    }

    @Test func pickKeepsWhatYouPick_theRestGoesToTheTrash() throws {
        let run = try Self.agentWork()
        let outcome = BoxDoneFlow.run(run.machine(answers: ["p", "y", "n", "n"]))
        #expect(run.output.hasSuffix("""
              Bring it home? y yes  p pick  d drop  n keep in box p
              keep src/checkout/clock.ts  +38 −1? y/n y
              keep README.md  removed · −1? y/n n
              keep test/checkout.spec.ts  +1 −0? y/n n
              ✓ Home. 1 file · 2 in the trash for 7 days

            """))
        #expect(outcome != .keptInBox)
        #expect(run.text("test/checkout.spec.ts") == "it('ticks')\n")
        #expect(run.text("README.md") == "hello\n")
        #expect(run.text("src/checkout/clock.ts")?.contains("new 37") == true)
    }

    @Test func dropPutsTheProjectBack() throws {
        let run = try Self.agentWork()
        _ = BoxDoneFlow.run(run.machine(answers: ["d"]))
        #expect(run.output.hasSuffix("  ✓ Dropped. 3 files in the trash for 7 days · nothing came home\n"))
        #expect(run.text("src/checkout/clock.ts") == Self.original["src/checkout/clock.ts"])
        #expect(run.text("README.md") == "hello\n")
        #expect(run.closed == 1)
    }

    /// Unsaved work is never lost: no, an empty line, or the end of input
    /// leave everything in the box, and nothing closes.
    @Test(arguments: [["n"], [""], []])
    func anythingButAYesKeepsItInTheBox(answers: [String]) throws {
        let run = try Self.agentWork()
        #expect(BoxDoneFlow.run(run.machine(answers: answers)) == .keptInBox)
        #expect(run.output.hasSuffix("  Kept in the box.\n  → bring it home later: rv box done\n"))
        #expect(run.closed == 0)
        #expect(run.text("README.md") == nil)
    }

    @Test func withoutATerminalItOnlyShows() throws {
        let run = try Self.agentWork()
        #expect(BoxDoneFlow.run(run.machine(answers: ["y"], terminal: false, agent: nil)) == .keptInBox)
        #expect(run.output.hasPrefix("◆ rv 3 files changed in the box · 4 min\n"))
        #expect(run.output.hasSuffix("  → bring it home at your terminal: rv box done\n"))
        #expect(run.closed == 0)
    }

    @Test func anAgentStillRunningKeepsTheBoxOpen() throws {
        let run = try Self.agentWork()
        #expect(BoxDoneFlow.run(run.machine(answers: ["y"], running: 1)) == .keptInBox)
        #expect(run.output == """
            ◐ An agent is still running in this box.
              → bring it home once it's done: rv box done

            """)
        #expect(run.closed == 0)
    }

    @Test func bothChangedIt_bothAreKept() throws {
        let run = try Run(
            original: ["src/app.ts": "app\n"],
            agent: ["src/app.ts": "app from the box\n"],
            you: ["src/app.ts": "app edited outside\n"])
        _ = BoxDoneFlow.run(run.machine(answers: []))
        #expect(run.output == """
            ◆ rv nothing to bring home · 4 min in the box
              ◐ src/app.ts · changed in the box and outside it · both kept, the box's is src/app.ts.from-box
              ✓ Closed · yours stayed, and 1 file from the box is beside it

            """)
        #expect(run.text("src/app.ts") == "app edited outside\n")
        #expect(run.text("src/app.ts.from-box") == "app from the box\n")
    }

    @Test func aRefusedCloseSaysWhyAndTheWorkStaysInTheBox() throws {
        let run = try Self.agentWork()
        let outcome = BoxDoneFlow.run(run.machine(
            answers: ["y"], refuseClose: "workspace close refused: nothing was published and the project directory is unchanged"))
        #expect(outcome == .failed)
        #expect(run.output.hasSuffix("""
              ✕ Nothing came home: workspace close refused: nothing was published and the project directory is unchanged
              → rv box done

            """))
    }

    @Test func theNumbersRead() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(BoxDoneRender.duration(from: start, to: start.addingTimeInterval(20)) == "under a minute")
        #expect(BoxDoneRender.duration(from: start, to: start.addingTimeInterval(125 * 60)) == "2 h 5 min")
        #expect(BoxDoneRender.duration(from: start, to: start.addingTimeInterval(3 * 86_400)) == "3 days")
        #expect(BoxDoneRender.grouped(1_204) == "1,204")
        #expect(BoxDoneRender.grouped(31_204_000) == "31,204,000")
        #expect(BoxDoneRender.count(1, "file") == "1 file")
    }
}
