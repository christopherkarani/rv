import Foundation
import Testing
@testable import RVIsolation

/// L5 on real folders: the scan reads a saved tree and a box, and the
/// apply step undoes dropped work in the box after copying it to the
/// trash. Plain directories stand in for the saved tree and the volume,
/// so this runs on Linux.
@Suite("rv box done reads and edits real folders")
struct BoxHomecomingScanTests {
    /// A project, its box copy, a trash, and the moment the box started.
    struct Fixture {
        let root: URL
        var saved: String { root.appendingPathComponent(".rv-saved-test").path }
        var box: String { root.appendingPathComponent("app").path }
        var trash: BoxTrash { BoxTrash(root: root.appendingPathComponent("box-trash")) }
        let start: Date

        /// `original` in both trees, then the box starts, then `agent`
        /// writes in the box and `you` write in the saved tree.
        init(original: [String: String], agent: [String: String?] = [:], you: [String: String?] = [:]) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("rv-box-done-\(UUID().uuidString)", isDirectory: true)
            for (path, text) in original {
                try Self.put(text, at: root.path + "/.rv-saved-test/" + path)
                try Self.put(text, at: root.path + "/app/" + path)
            }
            try FileManager.default.createDirectory(atPath: root.path + "/.rv-saved-test", withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: root.path + "/app", withIntermediateDirectories: true)
            Thread.sleep(forTimeInterval: 0.05)
            start = Date()
            Thread.sleep(forTimeInterval: 0.05)
            for (path, text) in agent { try Self.apply(text, at: root.path + "/app/" + path) }
            for (path, text) in you { try Self.apply(text, at: root.path + "/.rv-saved-test/" + path) }
        }

        static func put(_ text: String, at path: String) throws {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        }

        static func apply(_ text: String?, at path: String) throws {
            if let text { try put(text, at: path) } else { try FileManager.default.removeItem(atPath: path) }
        }

        func review() throws -> BoxReview {
            try BoxHomecomingScan.review(savedRoot: saved, boxRoot: box, startedAt: start).get()
        }

        func apply(_ choice: BoxHomeChoice) throws -> BoxHomecomingApply.Outcome {
            let plan = BoxHomecoming.plan(try review(), choice: choice)
            return BoxHomecomingApply.apply(plan, savedRoot: saved, boxRoot: box, project: box, trash: trash, now: start)
        }

        func boxText(_ path: String) -> String? {
            FileManager.default.contents(atPath: box + "/" + path).map { String(decoding: $0, as: UTF8.self) }
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    static let original = [
        "src/old.ts": "a\nb\nc\n",
        "src/app.ts": "app\n",
        "docs/gone.md": "one\ntwo\n",
        "notes.md": "mine\n",
        "README.md": "hello\n",
    ]

    static func everyKind() throws -> Fixture {
        try Fixture(
            original: original,
            agent: [
                "src/new.ts": "x\ny\nz\n",
                "src/old.ts": "a\nB\nc\n",
                "docs/gone.md": nil,
                "build/out.js": "built\n",
                "src/app.ts": "app from the box\n",
            ],
            you: [
                "notes.md": "mine, edited outside\n",
                "src/app.ts": "app edited outside\n",
            ])
    }

    @Test func theReviewCountsEveryKindOfChange() throws {
        let fixture = try Self.everyKind()
        defer { fixture.cleanUp() }
        let review = try fixture.review()
        #expect(review.items.map(\.id) == ["src/new.ts", "docs/gone.md", "src/old.ts", "build/"])
        #expect(review.items.map(\.lines) == [
            BoxLineCount(added: 3, removed: 0), BoxLineCount(added: 0, removed: 2),
            BoxLineCount(added: 1, removed: 1), BoxLineCount(added: 1, removed: 0),
        ])
        #expect(review.yours.map(\.relative) == ["notes.md", "src/app.ts"])
        #expect(review.yours.map(\.kind) == [.yoursKept, .bothKept])
        #expect(review.yours.last?.beside == "src/app.ts.from-box")
        #expect(review.refused.isEmpty)
        #expect(review.blocked.isEmpty)
    }

    @Test func keepingAllNeverOverwritesYourNewerEdits() throws {
        let fixture = try Self.everyKind()
        defer { fixture.cleanUp() }
        #expect(try fixture.apply(.keepAll) == .applied(trash: nil))
        #expect(fixture.boxText("src/new.ts") == "x\ny\nz\n")
        #expect(fixture.boxText("src/old.ts") == "a\nB\nc\n")
        #expect(fixture.boxText("docs/gone.md") == nil)
        // Yours stays; when both changed it, the box's version sits beside it.
        #expect(fixture.boxText("notes.md") == "mine, edited outside\n")
        #expect(fixture.boxText("src/app.ts") == "app edited outside\n")
        #expect(fixture.boxText("src/app.ts.from-box") == "app from the box\n")
        // What publish copies home now holds no conflict at all.
        let again = try fixture.review()
        #expect(again.yours.isEmpty)
        #expect(Set(again.items.map(\.id)) == ["src/new.ts", "src/old.ts", "docs/gone.md", "build/", "src/app.ts.from-box"])
    }

    @Test func droppingPutsTheProjectBackAndKeepsTheBoxsWorkInTheTrash() throws {
        let fixture = try Self.everyKind()
        defer { fixture.cleanUp() }
        guard case .applied(let entry?) = try fixture.apply(.dropAll) else {
            Issue.record("drop must apply and make a trash entry")
            return
        }
        #expect(fixture.boxText("src/new.ts") == nil)
        #expect(fixture.boxText("src/old.ts") == "a\nb\nc\n")
        #expect(fixture.boxText("docs/gone.md") == "one\ntwo\n")
        #expect(FileManager.default.fileExists(atPath: fixture.box + "/build") == false)
        let copies = entry.path + "/" + BoxTrash.copiesFolder
        #expect(FileManager.default.contents(atPath: copies + "/src/new.ts") == Data("x\ny\nz\n".utf8))
        #expect(FileManager.default.contents(atPath: copies + "/src/old.ts") == Data("a\nB\nc\n".utf8))
        #expect(FileManager.default.contents(atPath: copies + "/build/out.js") == Data("built\n".utf8))
        #expect(fixture.trash.origin(of: entry) == fixture.box)
        #expect(fixture.trash.entries().map(\.path) == [entry.path])
    }

    @Test func pickingKeepsOnlyThePickedFiles() throws {
        let fixture = try Self.everyKind()
        defer { fixture.cleanUp() }
        guard case .applied = try fixture.apply(.keep(["src/old.ts"])) else {
            Issue.record("pick must apply")
            return
        }
        #expect(fixture.boxText("src/old.ts") == "a\nB\nc\n")
        #expect(fixture.boxText("src/new.ts") == nil)
        #expect(fixture.boxText("docs/gone.md") == "one\ntwo\n")
    }

    @Test func aFolderTurnedIntoALinkStopsTheApplyAndNothingOutsideIsTouched() throws {
        let fixture = try Fixture(original: ["src/old.ts": "a\n"], agent: ["src/old.ts": "b\n"])
        defer { fixture.cleanUp() }
        let outside = fixture.root.appendingPathComponent("outside").path
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try FileManager.default.removeItem(atPath: fixture.box + "/src")
        try FileManager.default.createSymbolicLink(atPath: fixture.box + "/src", withDestinationPath: outside)
        // The review sees the kind change and blocks bringing anything home.
        #expect(try fixture.review().blocked == ["src"])
        // A plan run anyway never writes through the link.
        let plan = BoxHomePlan(steps: [.restore("src/old.ts")], keptFiles: 0, droppedFiles: 1)
        let outcome = BoxHomecomingApply.apply(
            plan, savedRoot: fixture.saved, boxRoot: fixture.box, project: fixture.box,
            trash: fixture.trash, now: fixture.start)
        #expect(outcome == .failed(path: "src/old.ts", trash: nil))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside).isEmpty)
    }

    @Test func theVolumesBookkeepingIsNotProjectContent() throws {
        let fixture = try Fixture(original: ["README.md": "hi\n"])
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(atPath: fixture.box + "/.fseventsd", withIntermediateDirectories: true)
        try Fixture.put("log", at: fixture.box + "/.fseventsd/0001")
        #expect(try fixture.review().isEmpty)
    }

    @Test func untouchedFilesAreUnchanged() throws {
        // Same size, and neither side changed since the start.
        let fixture = try Fixture(original: ["big.bin": "1234"])
        defer { fixture.cleanUp() }
        #expect(try fixture.review().isEmpty)
    }
}
