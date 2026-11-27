import Foundation
import Testing
@testable import RVIsolation

/// `rv box tidy`'s rules: leftovers go to a 7-day trash, and a box that
/// may hold unsaved work, or any image it names, is never touched.
@Suite("rv box tidy decides what may move")
struct BoxTidyTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let day: TimeInterval = 24 * 60 * 60
    static let tmp = "/var/folders/xx/T"

    static func image(_ id: String) -> String { "\(tmp)/rv-inode-\(id).sparseimage" }
    static func file(_ id: String, age: TimeInterval = day) -> BoxTidyImageFile {
        BoxTidyImageFile(path: image(id), modified: now.addingTimeInterval(-age))
    }

    @Test func oldImagesNothingNamesGoToTheTrash() {
        let scan = BoxTidyScan(
            boxes: [], imageFiles: [Self.file("b"), Self.file("a")],
            attachedImages: [BoxTidyAttachedImage(imagePath: Self.image("c"), device: "/dev/disk9", retained: false)])
        let plan = BoxTidy.plan(scan, now: Self.now)
        #expect(plan.hold == nil)
        #expect(plan.moves == [
            .attachedImage(path: Self.image("c"), device: "/dev/disk9"),
            .imageFile(path: Self.image("a")), .imageFile(path: Self.image("b")),
        ])
    }

    /// The acceptance rule. Every unfinished or open box is kept, and so
    /// is every image it names, attached or not, under any spelling.
    @Test func aBoxWithUnsavedWorkIsNeverTouched() {
        let unsaved = BoxTidyBox(
            project: "/Users/chris/code/app", lastActive: Self.now.addingTimeInterval(-8 * Self.day),
            state: .unfinished, images: ["/private\(Self.image("app"))", Self.image("app2")])
        let open = BoxTidyBox(project: "/Users/chris/code/site", lastActive: Self.now, state: .open,
                              images: [Self.image("site")])
        let scan = BoxTidyScan(
            boxes: [open, unsaved],
            imageFiles: [Self.file("app"), Self.file("site"), Self.file("old", age: 30 * Self.day)],
            attachedImages: [BoxTidyAttachedImage(imagePath: Self.image("app2"), device: "/dev/disk4", retained: false)],
            alsoKept: [Self.image("gone")])
        let plan = BoxTidy.plan(scan, now: Self.now)
        #expect(plan.kept == [unsaved, open])
        #expect(plan.moves == [.imageFile(path: Self.image("old"))])
        let moved = Set(plan.moves.map { BoxTidy.fileName($0.path) })
        for box in scan.boxes { for named in box.images { #expect(moved.contains(BoxTidy.fileName(named)) == false) } }

        let alsoKept = BoxTidy.plan(BoxTidyScan(boxes: [], imageFiles: [Self.file("gone")], attachedImages: [],
                                                alsoKept: [Self.image("gone")]), now: Self.now)
        #expect(alsoKept.moves.isEmpty)
    }

    @Test func imagesRecoveryNeedsOrWithoutADeviceStay() {
        let scan = BoxTidyScan(boxes: [], imageFiles: [], attachedImages: [
            BoxTidyAttachedImage(imagePath: Self.image("r"), device: "/dev/disk5", retained: true),
            BoxTidyAttachedImage(imagePath: Self.image("n"), device: nil, retained: false),
        ])
        #expect(BoxTidy.plan(scan, now: Self.now).moves.isEmpty)
    }

    /// A file that still has an attachment is not a loose file, and a file
    /// this new may belong to a box that is starting right now.
    @Test func attachedOrNewFilesStay() {
        let scan = BoxTidyScan(
            boxes: [], imageFiles: [Self.file("n", age: 60), Self.file("r")],
            attachedImages: [BoxTidyAttachedImage(imagePath: Self.image("r"), device: "/dev/disk5", retained: true)])
        #expect(BoxTidy.plan(scan, now: Self.now).moves.isEmpty)
    }

    @Test func aStartingBoxHoldsEverything() {
        let busy = BoxTidyBox(project: "/p", lastActive: Self.now, state: .busy)
        let expired = BoxTrashEntry(path: "/t/1-x", trashedAt: Self.now.addingTimeInterval(-8 * Self.day))
        let scan = BoxTidyScan(boxes: [busy], imageFiles: [Self.file("a")], attachedImages: [], trash: [expired])
        let plan = BoxTidy.plan(scan, now: Self.now)
        #expect(plan.hold == .boxBusy(project: "/p"))
        #expect(plan.moves.isEmpty)
        #expect(plan.expired == [expired])
    }

    @Test func unknownAttachmentsHoldEverything() {
        let scan = BoxTidyScan(boxes: [], imageFiles: [Self.file("a")], attachedImages: [], attachedKnown: false)
        let plan = BoxTidy.plan(scan, now: Self.now)
        #expect(plan.hold == .attachedUnknown)
        #expect(plan.moves.isEmpty)
    }

    @Test func onlyEntriesPastSevenDaysExpire() {
        let fresh = BoxTrashEntry(path: "/t/2-a", trashedAt: Self.now.addingTimeInterval(-6.9 * Self.day))
        let old = BoxTrashEntry(path: "/t/1-b", trashedAt: Self.now.addingTimeInterval(-7 * Self.day))
        let plan = BoxTidy.plan(BoxTidyScan(boxes: [], imageFiles: [], attachedImages: [], trash: [fresh, old]),
                                now: Self.now)
        #expect(plan.expired == [old])
    }
}

/// The trash on a real file system: moves are renames, entries date
/// themselves, and emptying never reaches outside the trash.
@Suite("rv box tidy's trash")
struct BoxTrashTests {
    let scratch: URL

    init() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-box-trash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    private func leftover(_ name: String, contents: String = "work") throws -> String {
        let path = scratch.appendingPathComponent(name).path
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test func aMovedFileKeepsItsBytesAndItsOrigin() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let trash = BoxTrash(root: scratch.appendingPathComponent("trash"))
        let path = try leftover("rv-inode-1.sparseimage", contents: "unsaved")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = try trash.move(path, now: now).get()
        #expect(FileManager.default.fileExists(atPath: path) == false)
        let kept = URL(fileURLWithPath: entry.path).appendingPathComponent("rv-inode-1.sparseimage")
        #expect(try String(contentsOf: kept, encoding: .utf8) == "unsaved")
        #expect(trash.entries() == [entry])
        #expect(trash.origin(of: entry) == path)
    }

    @Test func foldersLinksAndMissingFilesAreNotMoved() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let trash = BoxTrash(root: scratch.appendingPathComponent("trash"))
        let folder = scratch.appendingPathComponent("rv-inode-d.sparseimage").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        let target = try leftover("real")
        let link = scratch.appendingPathComponent("rv-inode-l.sparseimage").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        let now = Date()
        #expect(trash.move(folder, now: now) == .failure(.notAFile))
        #expect(trash.move(link, now: now) == .failure(.notAFile))
        #expect(trash.move(scratch.appendingPathComponent("gone").path, now: now) == .failure(.notAFile))
        #expect(FileManager.default.fileExists(atPath: target))
        #expect(trash.entries().isEmpty)
    }

    @Test func emptyingRemovesOnlyTrashEntries() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appendingPathComponent("trash")
        let trash = BoxTrash(root: root)
        let entry = try trash.move(try leftover("rv-inode-e.sparseimage"), now: Date()).get()
        // A folder in the trash that is not an entry, and one outside it
        // named like one, are never emptied.
        let stranger = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: false)
        let outside = scratch.appendingPathComponent("1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        #expect(trash.empty(BoxTrashEntry(path: stranger.path, trashedAt: .distantPast)) == false)
        #expect(trash.empty(BoxTrashEntry(path: outside.path, trashedAt: .distantPast)) == false)
        #expect(trash.entries() == [entry])
        #expect(trash.empty(entry))
        #expect(trash.entries().isEmpty)
        #expect(FileManager.default.fileExists(atPath: stranger.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    /// The whole run: what moves goes to the trash, a box's image stays
    /// put, an image that will not detach stays attached, and only the
    /// expired trash is emptied.
    @Test func applyMovesLeftoversAndNeverTheBox() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let trash = BoxTrash(root: scratch.appendingPathComponent("trash"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-BoxTidy.trashLifetime - 1)
        let expired = try trash.move(try leftover("rv-inode-x.sparseimage"), now: old).get()
        let fresh = try trash.move(try leftover("rv-inode-y.sparseimage"), now: now).get()
        let loose = try leftover("rv-inode-a.sparseimage")
        let boxImage = try leftover("rv-inode-box.sparseimage", contents: "unsaved")
        let stuck = try leftover("rv-inode-s.sparseimage")
        let detachable = try leftover("rv-inode-d.sparseimage")
        let day: TimeInterval = 24 * 60 * 60
        let scan = BoxTidyScan(
            boxes: [BoxTidyBox(project: "/p", lastActive: now, state: .unfinished, images: [boxImage])],
            imageFiles: [loose, boxImage].map { BoxTidyImageFile(path: $0, modified: now.addingTimeInterval(-day)) },
            attachedImages: [
                BoxTidyAttachedImage(imagePath: stuck, device: "/dev/disk7", retained: false),
                BoxTidyAttachedImage(imagePath: detachable, device: "/dev/disk8", retained: false),
            ],
            trash: trash.entries())
        let plan = BoxTidy.plan(scan, now: now)
        var detached: [String] = []
        let outcome = BoxTidy.apply(plan, moving: true, trash: trash, now: now) { device in
            detached.append(device)
            return device == "/dev/disk8"
        }
        #expect(outcome == BoxTidyOutcome(moved: 2, stayed: 1, emptied: 1))
        #expect(detached == ["/dev/disk8", "/dev/disk7"])
        #expect(try String(contentsOfFile: boxImage, encoding: .utf8) == "unsaved")
        #expect(FileManager.default.fileExists(atPath: stuck))
        #expect(FileManager.default.fileExists(atPath: loose) == false)
        #expect(FileManager.default.fileExists(atPath: detachable) == false)
        let entries = trash.entries()
        #expect(entries.contains(fresh))
        #expect(entries.contains(expired) == false)
        #expect(entries.count == 3)
    }

    @Test func declinedRunsOnlyEmptyTheExpiredTrash() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let trash = BoxTrash(root: scratch.appendingPathComponent("trash"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let loose = try leftover("rv-inode-a.sparseimage")
        let plan = BoxTidy.plan(BoxTidyScan(
            boxes: [], imageFiles: [BoxTidyImageFile(path: loose, modified: .distantPast)], attachedImages: []),
            now: now)
        let outcome = BoxTidy.apply(plan, moving: false, trash: trash, now: now) { _ in true }
        #expect(outcome == BoxTidyOutcome())
        #expect(FileManager.default.fileExists(atPath: loose))
    }
}
