import Foundation

/// One name in a tree, as the box review reads it: the saved tree (the
/// project as it was when the box started, which rv hides beside the
/// project while the box is open) or the box (the workspace volume).
public struct BoxTreeEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case file
        case symlink(target: String)
        case directory
        /// A FIFO, socket or device node: publish copies none of them.
        case special
    }

    public var kind: Kind
    public var size: UInt64
    /// Permission bits (`st_mode & 0o7777`).
    public var mode: UInt16
    /// The later of its content change (mtime) and status change (ctime).
    public var changedAt: Date

    public init(kind: Kind, size: UInt64 = 0, mode: UInt16 = 0o644, changedAt: Date) {
        self.kind = kind
        self.size = size
        self.mode = mode
        self.changedAt = changedAt
    }

    var isDirectory: Bool { kind == .directory }

    /// File, link, folder or special: a change between two of them is a
    /// change of kind, which publish refuses.
    var shape: Int {
        switch kind {
        case .file: 0
        case .symlink: 1
        case .directory: 2
        case .special: 3
        }
    }
}

/// What happened to one path between the saved tree and the box.
public struct BoxPathChange: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case added
        case changed
        case removed
        /// Changed outside the box after it started, and the box left it
        /// alone: your version stays.
        case yoursKept
        /// Changed in the box and outside it: your version stays, and the
        /// box's version goes beside it under `beside`.
        case bothKept
        /// Publish can't copy it: it is dropped, to the trash when it has
        /// content.
        case cannotComeHome(Refusal)
        /// It turned from a file into a folder (or a link), which publish
        /// refuses: nothing can come home until it turns back.
        case kindChanged
    }

    public enum Refusal: Equatable, Sendable {
        /// A FIFO, socket or device file.
        case special
        /// A link that points outside the project.
        case linkLeavesProject
        /// A copy an earlier `rv box done` started and never finished
        /// (`BoxHomecomingApply.unfinishedPrefix`).
        case unfinishedCopy
    }

    public var relative: String
    public var kind: Kind
    public var saved: BoxTreeEntry?
    public var box: BoxTreeEntry?
    /// Lines added and removed, for text files; nil for binary, large or
    /// folder changes.
    public var lines: BoxLineCount?
    /// For `bothKept`: the name the box's version takes beside yours.
    public var beside: String?

    public init(
        relative: String, kind: Kind, saved: BoxTreeEntry?, box: BoxTreeEntry?,
        lines: BoxLineCount? = nil, beside: String? = nil
    ) {
        self.relative = relative
        self.kind = kind
        self.saved = saved
        self.box = box
        self.lines = lines
        self.beside = beside
    }

    var isFolder: Bool { (box ?? saved)?.isDirectory == true }

    /// A change you choose to keep or drop; the rest are always applied.
    var isChoosable: Bool {
        switch kind {
        case .added, .changed, .removed: true
        case .yoursKept, .bothKept, .cannotComeHome, .kindChanged: false
        }
    }
}

/// One line of the review: a file, or a folder that came or went whole,
/// or the project's git data. Kept or dropped as one.
public struct BoxReviewItem: Equatable, Sendable, Identifiable {
    public enum Shape: Equatable, Sendable {
        case file
        /// A folder the box made; everything in it comes or goes together.
        case newFolder
        /// A folder the box removed.
        case removedFolder
        /// `.git`: commits, the index and refs only make sense together.
        case git
        /// A folder whose permissions changed; its files are their own items.
        case folderMode
    }

    /// The path shown; a folder's ends with `/`.
    public var id: String
    public var shape: Shape
    public var changes: [BoxPathChange]

    /// Files and links in it (folders are not counted).
    public var fileCount: Int { changes.filter { $0.isFolder == false }.count }

    /// The lines it adds and removes, when every file in it was counted.
    public var lines: BoxLineCount? {
        var total = BoxLineCount.zero
        for change in changes where change.isFolder == false {
            guard let lines = change.lines else { return nil }
            total = total + lines
        }
        return total
    }

    /// For a lone file: what happened to it.
    public var kind: BoxPathChange.Kind? { shape == .file ? changes.first?.kind : nil }
}

/// The review of one box: everything that would come home, in the words
/// rv shows and the numbers it counts. Pure; `BoxHomecomingScan` reads
/// the two trees into it.
public struct BoxReview: Equatable, Sendable {
    /// What you choose to keep or drop, biggest change first.
    public var items: [BoxReviewItem]
    /// Where your newer edits win: `yoursKept` and `bothKept`.
    public var yours: [BoxPathChange]
    /// What can't come home and is dropped.
    public var refused: [BoxPathChange]
    /// Paths that changed kind: while there are any, nothing comes home.
    public var blocked: [String]
    /// When the box started; edits outside it after this are yours.
    public var startedAt: Date
    /// Names outside the box that are now a different file than the one
    /// the box started from (an app that saves by writing a new file and
    /// renaming it over the old one). Publish refuses to write over them,
    /// so while there are any, nothing comes home.
    public var replaced: [String] = []

    public var isEmpty: Bool {
        items.isEmpty && yours.isEmpty && refused.isEmpty && blocked.isEmpty && replaced.isEmpty
    }
    public var fileCount: Int { items.reduce(0) { $0 + $1.fileCount } }

    /// The lines every counted file adds and removes.
    public var lines: BoxLineCount {
        items.flatMap(\.changes).compactMap(\.lines).reduce(.zero, +)
    }
}

/// What the person chose for the review's items.
public enum BoxHomeChoice: Equatable, Sendable {
    case keepAll
    /// Keep the items with these ids; drop the rest.
    case keep(Set<String>)
    case dropAll
}

/// One edit to the box before it closes. Close then publishes the box as
/// it stands, so a dropped change is undone in the box first.
public enum BoxHomeStep: Equatable, Sendable {
    /// Copy the box's version of this file or link into the trash.
    case trash(String)
    /// Copy the box's version to a new name beside it (`bothKept`).
    case placeBeside(String, as: String)
    /// Put the saved version back in the box: a file, a link, or a folder
    /// (made with the saved mode).
    case restore(String)
    /// Remove a file, link or special file from the box.
    case remove(String)
    /// Remove a folder from the box once it is empty.
    case removeFolder(String)
}

/// The edits a choice makes, in the order they run: every copy into the
/// trash first, so nothing is undone before its copy is kept.
public struct BoxHomePlan: Equatable, Sendable {
    public var steps: [BoxHomeStep]
    public var keptFiles: Int
    public var droppedFiles: Int

    /// Files whose box version goes to the trash.
    public var trashed: Int {
        steps.filter { if case .trash = $0 { true } else { false } }.count
    }
}

/// The functional core of `rv box done`: what changed, how it groups, and
/// which edits a choice makes. No I/O.
public enum BoxHomecoming {
    /// The suffix a box's version takes beside your newer one.
    public static let besideSuffix = ".from-box"

    /// What happened to `relative`. `sameContent` compares the two files'
    /// bytes or the two links' targets; `linkStaysInside` is publish's
    /// symlink rule (`workspaceSymlinkTargetStaysInside`). Nil when
    /// nothing changed.
    public static func classify(
        _ relative: String, saved: BoxTreeEntry?, box: BoxTreeEntry?, sameContent: Bool,
        lines: BoxLineCount?, startedAt: Date, linkStaysInside: (String, String) -> Bool
    ) -> BoxPathChange? {
        func change(_ kind: BoxPathChange.Kind, lines: BoxLineCount? = lines) -> BoxPathChange {
            BoxPathChange(relative: relative, kind: kind, saved: saved, box: box, lines: lines)
        }
        func leaves(_ entry: BoxTreeEntry) -> Bool {
            if case .symlink(let target) = entry.kind { return linkStaysInside(relative, target) == false }
            return false
        }
        switch (saved, box) {
        case (nil, nil):
            return nil
        case (let saved?, let box?):
            if saved.isDirectory, box.isDirectory {
                // Publish sets each folder's mode from the box, so a mode
                // change comes home like any other. A folder touched outside
                // the box keeps your mode: rv can't tell your chmod from a
                // file you added, and never writes over your edits.
                guard saved.mode != box.mode else { return nil }
                if saved.changedAt > startedAt { return change(.yoursKept, lines: nil) }
                return change(.changed, lines: nil)
            }
            if saved.shape != box.shape { return change(.kindChanged, lines: nil) }
            if box.kind == .special { return change(.cannotComeHome(.special), lines: nil) }
            if sameContent, saved.mode == box.mode { return nil }
            let yoursNewer = saved.changedAt > startedAt
            let boxNewer = box.changedAt > startedAt
            // A link the box pointed out of the project never comes home,
            // not even beside yours.
            if boxNewer, leaves(box) { return change(.cannotComeHome(.linkLeavesProject), lines: nil) }
            if yoursNewer, boxNewer, sameContent == false { return change(.bothKept) }
            if yoursNewer, boxNewer == false { return change(.yoursKept) }
            if leaves(box) { return change(.cannotComeHome(.linkLeavesProject), lines: nil) }
            return change(.changed, lines: sameContent ? .zero : lines)
        case (let saved?, nil):
            // Changed outside the box after it started (a folder you made,
            // or a file you edited): yours, whatever the box did.
            if saved.changedAt > startedAt { return change(.yoursKept) }
            return change(.removed, lines: saved.isDirectory ? nil : lines)
        case (nil, let box?):
            if box.kind == .special { return change(.cannotComeHome(.special), lines: nil) }
            if box.isDirectory == false, BoxHomecomingApply.isUnfinishedCopy(relative) {
                return change(.cannotComeHome(.unfinishedCopy), lines: nil)
            }
            // An untouched copy with no saved name: you removed it outside
            // the box after it started, and it stays removed. (`review`
            // hands a folder back to the box when the box put work in it.)
            if box.changedAt <= startedAt { return change(.yoursKept, lines: nil) }
            if leaves(box) { return change(.cannotComeHome(.linkLeavesProject), lines: nil) }
            return change(.added, lines: box.isDirectory ? nil : lines)
        }
    }

    /// Groups `changes` into the review. `names` is every name in either
    /// tree, so a box version kept beside yours never takes one.
    public static func review(_ changes: [BoxPathChange], names: Set<String>, startedAt: Date) -> BoxReview {
        var taken = names
        var yours: [BoxPathChange] = []
        var refused: [BoxPathChange] = []
        var blocked: [String] = []
        var choosable: [BoxPathChange] = []
        for change in settled(changes).sorted(by: { $0.relative < $1.relative }) {
            switch change.kind {
            case .added, .changed, .removed:
                choosable.append(change)
            case .bothKept:
                var kept = change
                let name = besideName(change.relative, taken: taken)
                taken.insert(name)
                kept.beside = name
                yours.append(kept)
            case .yoursKept:
                yours.append(change)
            case .cannotComeHome:
                refused.append(change)
            case .kindChanged:
                blocked.append(change.relative)
            }
        }
        let newFolders = Set(choosable.filter { $0.kind == .added && $0.isFolder }.map(\.relative))
        let removedFolders = Set(choosable.filter { $0.kind == .removed && $0.isFolder }.map(\.relative))
        var groups: [String: BoxReviewItem] = [:]
        for change in choosable {
            let (id, shape) = change.kind == .changed && change.isFolder
                ? (change.relative + "/", .folderMode)
                : group(change.relative, newFolders: newFolders, removedFolders: removedFolders)
            groups[id, default: BoxReviewItem(id: id, shape: shape, changes: [])].changes.append(change)
        }
        let items = groups.values.sorted { lhs, rhs in
            // Uncounted items (binary files, git data) come after counted ones.
            let left = lhs.lines?.weight ?? -1
            let right = rhs.lines?.weight ?? -1
            return left != right ? left > right : lhs.id < rhs.id
        }
        return BoxReview(items: items, yours: yours, refused: refused, blocked: blocked, startedAt: startedAt)
    }

    /// Folder changes settled against what is inside them, so a folder is
    /// never shown as gone while something in it stays:
    /// - a folder the box removed that holds your newer edits comes back
    ///   with them, so its removal is not a choice (its other files are);
    /// - a folder you removed outside the box that the box put work in is
    ///   the box's new folder, not yours.
    static func settled(_ changes: [BoxPathChange]) -> [BoxPathChange] {
        func isYours(_ change: BoxPathChange) -> Bool { change.kind == .yoursKept || change.kind == .bothKept }
        func ancestors(_ relative: String) -> [String] {
            var found: [String] = []
            var parent = BoxPath.parent(relative)
            while parent.isEmpty == false {
                found.append(parent)
                parent = BoxPath.parent(parent)
            }
            return found
        }
        let underYours = Set(changes.filter(isYours).flatMap { ancestors($0.relative) })
        let underBox = Set(changes.filter { isYours($0) == false }.flatMap { ancestors($0.relative) })
        return changes.compactMap { change in
            guard change.isFolder else { return change }
            if change.kind == .removed, underYours.contains(change.relative) { return nil }
            if change.kind == .yoursKept, change.saved == nil, underBox.contains(change.relative) {
                var added = change
                added.kind = .added
                return added
            }
            return change
        }
    }

    /// The item a change belongs to: `.git`, the shallowest folder the box
    /// made or removed around it, or the file itself.
    static func group(
        _ relative: String, newFolders: Set<String>, removedFolders: Set<String>
    ) -> (String, BoxReviewItem.Shape) {
        if relative == ".git" || relative.hasPrefix(".git/") { return (".git/", .git) }
        var prefix = ""
        for part in relative.split(separator: "/") {
            prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
            if newFolders.contains(prefix) { return (prefix + "/", .newFolder) }
            if removedFolders.contains(prefix) { return (prefix + "/", .removedFolder) }
        }
        return (relative, .file)
    }

    /// `name.from-box`, or `name.from-box-2`… when that is taken.
    static func besideName(_ relative: String, taken: Set<String>) -> String {
        let base = relative + besideSuffix
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base)-\(number)") { number += 1 }
        return "\(base)-\(number)"
    }

    /// The edits `choice` makes. Your newer edits and the refusals are
    /// applied whatever the choice; a dropped change is undone in the box
    /// after its box version is copied to the trash.
    public static func plan(_ review: BoxReview, choice: BoxHomeChoice) -> BoxHomePlan {
        var trash: [String] = []
        var beside: [BoxHomeStep] = []
        var folders: [String] = []
        var files: [BoxHomeStep] = []
        var emptied: [String] = []
        // Folder modes go last, once everything inside is in place.
        var modes: [String] = []
        var kept = 0
        var dropped = 0
        func drop(_ change: BoxPathChange) {
            switch change.kind {
            case .added:
                if change.isFolder {
                    emptied.append(change.relative)
                } else {
                    trash.append(change.relative)
                    files.append(.remove(change.relative))
                }
            case .changed:
                if change.isFolder {
                    modes.append(change.relative)
                } else {
                    trash.append(change.relative)
                    files.append(.restore(change.relative))
                }
            case .removed:
                if change.isFolder {
                    folders.append(change.relative)
                } else {
                    files.append(.restore(change.relative))
                }
            case .yoursKept, .bothKept, .cannotComeHome, .kindChanged:
                break
            }
        }
        for item in review.items {
            if keeps(item, choice) {
                kept += item.fileCount
            } else {
                dropped += item.fileCount
                item.changes.forEach(drop)
            }
        }
        for change in review.yours {
            switch change.kind {
            case .bothKept:
                if let name = change.beside { beside.append(.placeBeside(change.relative, as: name)) }
                files.append(.restore(change.relative))
            default:
                switch (change.saved?.isDirectory, change.box?.isDirectory) {
                case (true?, _):
                    modes.append(change.relative)
                case (_?, _):
                    files.append(.restore(change.relative))
                case (nil, true?):
                    emptied.append(change.relative)
                case (nil, _):
                    trash.append(change.relative)
                    files.append(.remove(change.relative))
                }
            }
        }
        for change in review.refused {
            if change.box?.kind != .special { trash.append(change.relative) }
            files.append(change.saved != nil ? .restore(change.relative) : .remove(change.relative))
        }
        let depth: (String) -> Int = { $0.split(separator: "/").count }
        let steps = trash.map(BoxHomeStep.trash) + beside
            + folders.sorted { depth($0) < depth($1) }.map(BoxHomeStep.restore)
            + files
            + emptied.sorted { depth($0) > depth($1) }.map(BoxHomeStep.removeFolder)
            + modes.sorted { depth($0) > depth($1) }.map(BoxHomeStep.restore)
        return BoxHomePlan(steps: steps, keptFiles: kept, droppedFiles: dropped)
    }

    static func keeps(_ item: BoxReviewItem, _ choice: BoxHomeChoice) -> Bool {
        switch choice {
        case .keepAll: true
        case .keep(let ids): ids.contains(item.id)
        case .dropAll: false
        }
    }
}
