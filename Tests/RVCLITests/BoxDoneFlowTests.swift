#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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

        /// What the host recorded about the saved tree when the box started.
        let snapshot: BoxSnapshot

        init(original: [String: String], agent: [String: String?], you: [String: String?] = [:]) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("rv-box-done-flow-\(UUID().uuidString)", isDirectory: true)
            let saved = root.appendingPathComponent("code/.rv-saved-0123456789ab").path
            let box = root.appendingPathComponent("code/app").path
            for directory in [saved, box] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                for (path, text) in original { try Self.put(text, at: directory + "/" + path) }
            }
            snapshot = Self.snapshot(of: saved)
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

        /// Every saved name's identity, as the host's snapshot holds it.
        static func snapshot(of root: String) -> BoxSnapshot {
            var stamps: [String: BoxInodeStamp] = [:]
            for relative in FileManager.default.subpaths(atPath: root) ?? [] {
                var info = stat()
                guard lstat(root + "/" + relative, &info) == 0 else { continue }
                let kind: BoxInodeStamp.Kind = info.st_mode & S_IFMT == S_IFDIR ? .directory
                    : info.st_mode & S_IFMT == S_IFLNK ? .symlink : .regular
                stamps[relative] = BoxInodeStamp(
                    device: UInt64(info.st_dev), inode: UInt64(info.st_ino), links: UInt64(info.st_nlink), kind: kind)
            }
            return BoxSnapshot(stamps: stamps)
        }

        /// The source as the lifecycle log gives it: the recorded devices,
        /// inode and snapshot of this run's real folders.
        func recorded(volumeDevice: UInt64? = nil) -> BoxHomecomingSource {
            var savedInfo = stat()
            var boxInfo = stat()
            lstat(saved, &savedInfo)
            stat(box, &boxInfo)
            return BoxHomecomingSource(
                project: box, savedRoot: saved, startedAt: start,
                saved: (UInt64(savedInfo.st_dev), UInt64(savedInfo.st_ino)),
                volumeDevice: volumeDevice ?? UInt64(boxInfo.st_dev), snapshot: snapshot)
        }

        func machine(
            answers: [String], terminal: Bool = true, running: [Int] = [0], refuseClose: BoxCloseRefusal? = nil,
            agent: String? = "claude", source: BoxHomecomingSource? = nil, whileAsking: ((Int) -> Void)? = nil
        ) -> BoxDoneMachine {
            let queue = Answers(answers)
            let counts = Answers(running.map(String.init))
            let asked = Answers([])
            return BoxDoneMachine(
                source: source ?? recorded(),
                boxRoot: box,
                running: { counts.nextOrLast().flatMap { Int($0) } ?? 0 },
                agent: agent,
                home: root.path,
                trash: BoxTrash(root: root.appendingPathComponent("box-trash")),
                // Four minutes after the box started.
                now: { self.start.addingTimeInterval(4 * 60 + 5) },
                isTerminal: terminal,
                ask: { prompt in
                    whileAsking?(asked.count())
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
        private var last: String?
        private var calls = 0
        init(_ answers: [String]) { left = answers }
        func next() -> String? { left.isEmpty ? nil : left.removeFirst() }
        /// The next one, then the last one again once they run out.
        func nextOrLast() -> String? {
            if left.isEmpty == false { last = left.removeFirst() }
            return last
        }
        /// How many times it was called before.
        func count() -> Int {
            defer { calls += 1 }
            return calls
        }
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
        #expect(BoxDoneFlow.run(run.machine(answers: ["y"], running: [1])) == .keptInBox)
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

    /// A refused publish is the end of the box: the host restored your
    /// project and kept the box's volume as an image. The next step names
    /// that image, never a `rv box done` with no box left to review.
    @Test func aRefusedCloseNamesTheImageThatHoldsTheWork() throws {
        let run = try Self.agentWork()
        let image = "/Users/me/code/rv-rejected-0123456789ab-20261128T101500Z.sparseimage"
        let outcome = BoxDoneFlow.run(run.machine(
            answers: ["y"],
            refuseClose: BoxCloseRefusal(reason: "notes.md changed outside the box", retainedImage: image)))
        #expect(outcome == .failed)
        #expect(run.output.hasSuffix("""
              ✕ Nothing came home: notes.md changed outside the box
              The box is closed, and your project is as it was outside it. The box's work is in a disk image: \(image)
              → copy out what you need: hdiutil attach -readonly -nobrowse \(image)

            """))
        #expect(run.output.contains("→ rv box done") == false)
    }

    @Test func aRefusedCloseWithoutAnImageSaysWhereToLook() throws {
        let run = try Self.agentWork()
        let outcome = BoxDoneFlow.run(run.machine(
            answers: ["y"], refuseClose: BoxCloseRefusal(reason: "workspace host is not reachable", retainedImage: nil)))
        #expect(outcome == .failed)
        #expect(run.output.hasSuffix("""
              ✕ Nothing came home: workspace host is not reachable
              → see where the box stands: rv workspace status

            """))
    }

    /// An app that saves by writing a new file and renaming it over the
    /// old one gives the name a new inode, and publish refuses the whole
    /// close for it. rv says so before asking, and nothing is touched.
    @Test func aNameReplacedOutsideTheBoxBlocksBeforeAsking() throws {
        let run = try Self.agentWork()
        try Data("mine, saved by an app\n".utf8).write(to: URL(fileURLWithPath: run.saved + "/notes.md"), options: .atomic)
        let outcome = BoxDoneFlow.run(run.machine(answers: ["y"]))
        #expect(outcome == .keptInBox)
        #expect(run.output.hasSuffix("""
              ✕ notes.md was saved outside the box as a new file, so the box can't come home over it.
              → keep yours and set the box's work aside in a disk image: rv workspace close

            """))
        #expect(run.output.contains("Bring it home?") == false)
        #expect(run.closed == 0)
        #expect(run.text("README.md") == nil)
    }

    /// An edit made while the question waits changes what the answer
    /// means: rv looks again, shows the new review and asks again, so the
    /// edit is never written over.
    @Test func anEditWhileThePromptWaitsIsShownAgain() throws {
        let run = try Self.agentWork()
        let outcome = BoxDoneFlow.run(run.machine(answers: ["y", "y"], whileAsking: { asked in
            guard asked == 0 else { return }
            try? Run.put("it('ticks')\nit('mine, typed while rv asked')\n", at: run.saved + "/test/checkout.spec.ts")
        }))
        guard case .home = outcome else {
            Issue.record("the second yes must bring it home")
            return
        }
        #expect(run.output.contains("""
              Bring it home? y yes  p pick  d drop  n keep in box y
              ◐ Something changed while you chose, so here it is again.
            ◆ rv claude changed 2 files · 4 min in the box
            """))
        #expect(run.output.contains(
            "◐ test/checkout.spec.ts · changed in the box and outside it · both kept, the box's is test/checkout.spec.ts.from-box"))
        #expect(run.text("test/checkout.spec.ts") == "it('ticks')\nit('mine, typed while rv asked')\n")
        #expect(run.text("test/checkout.spec.ts.from-box") == "it('ticks')\nit('stops sharing a clock')\n")
        #expect(run.closed == 1)
    }

    @Test func filesThatKeepChangingStayInTheBox() throws {
        let run = try Self.agentWork()
        let outcome = BoxDoneFlow.run(run.machine(answers: ["y", "y", "y", "y"], whileAsking: { asked in
            // A new size each time: two quick writes can share a timestamp.
            try? Run.put("edit" + String(repeating: "!", count: asked + 1) + "\n", at: run.saved + "/README.md")
        }))
        #expect(outcome == .keptInBox)
        #expect(run.output.hasSuffix("  ◐ Files keep changing, so it all stays in the box.\n  → bring it home once they settle: rv box done\n"))
        #expect(run.closed == 0)
    }

    /// The runtime count is read again right before close: an agent that
    /// started while the person chose keeps the box open.
    @Test func anAgentThatStartsBeforeCloseKeepsTheBoxOpen() throws {
        let run = try Self.agentWork()
        let outcome = BoxDoneFlow.run(run.machine(answers: ["d"], running: [0, 0, 1]))
        #expect(outcome == .keptInBox)
        #expect(run.output.contains("  ◐ An agent started in this box while you chose, so it stays open. Your choice is made in the box.\n"))
        #expect(run.output.hasSuffix("  → bring it home once it's done: rv box done\n"))
        #expect(run.closed == 0)
    }

    @Test func aBoxThatIsNotTheRecordedOneIsNotTouched() throws {
        let run = try Self.agentWork()
        let wrong = run.recorded(volumeDevice: 0xDEAD_BEEF)
        let outcome = BoxDoneFlow.run(run.machine(answers: ["d"], source: wrong))
        #expect(outcome == .failed)
        #expect(run.output.contains("isn't the box rv opened there, so rv changed nothing."))
        #expect(run.text("README.md") == nil)
        #expect(run.closed == 0)
    }

    /// A Ctrl-C partway through a drop leaves its copies in the trash; the
    /// next review says where they are.
    @Test func anEarlierStoppedTryIsNamed() throws {
        let run = try Self.agentWork()
        guard case .success(let earlier) = BoxTrash(root: run.root.appendingPathComponent("box-trash"))
            .makeEntry(from: run.box, now: run.start.addingTimeInterval(1))
        else {
            Issue.record("trash entry")
            return
        }
        _ = BoxDoneFlow.run(run.machine(answers: ["n"]))
        #expect(run.output.contains("  ◐ Work dropped by an earlier rv box done is in \(earlier.path)\n"))
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
