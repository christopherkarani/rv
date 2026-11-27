import Foundation

// `rv box tidy` (workstream L, chunk L2): what may go to the 7-day trash
// and what must stay. Pure: the macOS shell reads the machine into a
// `BoxTidyScan`, this decides, and `BoxTrash` moves files. Cross-platform
// so the rules are tested everywhere.
//
// The one rule that matters: a box that never finished may hold unsaved
// work, so tidy never touches it, nor any image it names. Everything tidy
// moves goes to the trash, not away: it can be put back for 7 days.

/// A box (workspace) that never closed. Tidy only lists it.
public struct BoxTidyBox: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// A host is running it now.
        case open
        /// It is starting or recovering: tidy waits until it settles.
        case busy
        /// Its host is gone; its writes are still in its volume.
        case unfinished
    }

    public var project: String
    public var lastActive: Date
    public var state: State
    /// Disk images this box's records name. Never moved.
    public var images: [String]

    public init(project: String, lastActive: Date, state: State, images: [String] = []) {
        self.project = project
        self.lastActive = lastActive
        self.state = state
        self.images = images
    }
}

/// An `rv-inode-*.sparseimage` file nothing has attached.
public struct BoxTidyImageFile: Sendable, Equatable {
    public var path: String
    public var modified: Date

    public init(path: String, modified: Date) {
        self.path = path
        self.modified = modified
    }
}

/// An attached rv image no live box owns.
public struct BoxTidyAttachedImage: Sendable, Equatable {
    public var imagePath: String
    public var device: String?
    /// Recovery still needs it (`WorkspaceDiskLeftovers.retained`).
    public var retained: Bool

    public init(imagePath: String, device: String?, retained: Bool) {
        self.imagePath = imagePath
        self.device = device
        self.retained = retained
    }
}

/// One thing already in the trash.
public struct BoxTrashEntry: Sendable, Equatable {
    /// The entry's folder inside the trash.
    public var path: String
    public var trashedAt: Date

    public init(path: String, trashedAt: Date) {
        self.path = path
        self.trashedAt = trashedAt
    }
}

/// What the machine holds, as tidy reads it.
public struct BoxTidyScan: Sendable, Equatable {
    public var boxes: [BoxTidyBox]
    public var imageFiles: [BoxTidyImageFile]
    public var attachedImages: [BoxTidyAttachedImage]
    /// False when the attached-image list could not be read: tidy then
    /// moves nothing, since it cannot tell what is in use.
    public var attachedKnown: Bool
    public var trash: [BoxTrashEntry]
    /// Images named by unclosed workspaces that are not in `boxes` (their
    /// project folder is gone, or a newer box replaced them). Kept too.
    public var alsoKept: [String]

    public init(
        boxes: [BoxTidyBox], imageFiles: [BoxTidyImageFile], attachedImages: [BoxTidyAttachedImage],
        attachedKnown: Bool = true, trash: [BoxTrashEntry] = [], alsoKept: [String] = []
    ) {
        self.alsoKept = alsoKept
        self.boxes = boxes
        self.imageFiles = imageFiles
        self.attachedImages = attachedImages
        self.attachedKnown = attachedKnown
        self.trash = trash
    }
}

/// One leftover tidy moves to the trash.
public enum BoxTidyItem: Sendable, Equatable {
    /// An image file nothing has attached.
    case imageFile(path: String)
    /// An attached image: detached first (never forced), then trashed.
    case attachedImage(path: String, device: String)

    public var path: String {
        switch self {
        case .imageFile(let path), .attachedImage(let path, _): path
        }
    }
}

/// Why tidy moves nothing at all this time.
public enum BoxTidyHold: Sendable, Equatable {
    /// A box is starting or recovering; its images may not be recorded yet.
    case boxBusy(project: String)
    /// rv could not read which images are attached.
    case attachedUnknown
}

/// What tidy will do.
public struct BoxTidyPlan: Sendable, Equatable {
    /// Boxes that never finished, oldest first. All of them stay.
    public var kept: [BoxTidyBox]
    /// Leftovers to move to the trash.
    public var moves: [BoxTidyItem]
    /// Trash entries past their 7 days, emptied for good.
    public var expired: [BoxTrashEntry]
    /// Set when nothing may move this run.
    public var hold: BoxTidyHold?

    public init(kept: [BoxTidyBox], moves: [BoxTidyItem], expired: [BoxTrashEntry], hold: BoxTidyHold?) {
        self.kept = kept
        self.moves = moves
        self.expired = expired
        self.hold = hold
    }

    public var isEmpty: Bool { moves.isEmpty && expired.isEmpty }
}

public enum BoxTidy {
    /// How long a trashed leftover can be put back.
    public static let trashDays = 7
    public static let trashLifetime: TimeInterval = TimeInterval(trashDays) * 24 * 60 * 60
    /// An image file this new may belong to a box that is starting right
    /// now and has not recorded it yet.
    public static let settleTime: TimeInterval = 10 * 60

    public static func plan(_ scan: BoxTidyScan, now: Date) -> BoxTidyPlan {
        let kept = scan.boxes.sorted { $0.lastActive < $1.lastActive }
        let expired = scan.trash.filter { now.timeIntervalSince($0.trashedAt) >= trashLifetime }
            .sorted { $0.path < $1.path }
        if let busy = kept.first(where: { $0.state == .busy }) {
            return BoxTidyPlan(kept: kept, moves: [], expired: expired, hold: .boxBusy(project: busy.project))
        }
        guard scan.attachedKnown else {
            return BoxTidyPlan(kept: kept, moves: [], expired: expired, hold: .attachedUnknown)
        }
        let named = Set((kept.flatMap(\.images) + scan.alsoKept).map(fileName))
        func free(_ path: String) -> Bool { named.contains(fileName(path)) == false }

        var moves: [BoxTidyItem] = []
        for image in scan.attachedImages.sorted(by: { $0.imagePath < $1.imagePath }) {
            guard image.retained == false, let device = image.device, free(image.imagePath) else { continue }
            moves.append(.attachedImage(path: image.imagePath, device: device))
        }
        let attachedNames = Set(scan.attachedImages.map { fileName($0.imagePath) })
        for file in scan.imageFiles.sorted(by: { $0.path < $1.path }) {
            guard free(file.path), attachedNames.contains(fileName(file.path)) == false,
                now.timeIntervalSince(file.modified) >= settleTime
            else { continue }
            moves.append(.imageFile(path: file.path))
        }
        return BoxTidyPlan(kept: kept, moves: moves, expired: expired, hold: nil)
    }

    /// Images are matched by file name: rv names each `rv-inode-<id>`, and
    /// the same file can be spelled through different folders (`/var` and
    /// `/private/var`), so a name match keeps it whatever the spelling.
    static func fileName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

/// What applying a plan did.
public struct BoxTidyOutcome: Sendable, Equatable {
    public var moved = 0
    /// Leftovers that stayed where they were: busy, gone, or on another disk.
    public var stayed = 0
    public var emptied = 0

    public init(moved: Int = 0, stayed: Int = 0, emptied: Int = 0) {
        self.moved = moved
        self.stayed = stayed
        self.emptied = emptied
    }
}

extension BoxTidy {
    /// Carries out `plan`. An attached image is detached first (never
    /// forced); one that will not detach stays attached and is not moved.
    /// With `moving` false only the expired trash is emptied.
    public static func apply(
        _ plan: BoxTidyPlan, moving: Bool, trash: BoxTrash, now: Date,
        detach: (String) -> Bool
    ) -> BoxTidyOutcome {
        var outcome = BoxTidyOutcome()
        if moving, plan.hold == nil {
            for item in plan.moves {
                if case .attachedImage(_, let device) = item, detach(device) == false {
                    outcome.stayed += 1
                    continue
                }
                switch trash.move(item.path, now: now) {
                case .success: outcome.moved += 1
                case .failure: outcome.stayed += 1
                }
            }
        }
        for entry in plan.expired where trash.empty(entry) { outcome.emptied += 1 }
        return outcome
    }
}
