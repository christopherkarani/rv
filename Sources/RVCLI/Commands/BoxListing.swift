import Foundation
import RVDomain
import RVIsolation

/// One box `rv box list` shows: a project whose workspace never closed.
struct BoxListing: Equatable, Sendable {
    /// Where the box stands now, from the workspace host's own records.
    enum State: String, Equatable, Sendable, Encodable {
        /// A live workspace host holds it.
        case open
        /// Its host is still mounting.
        case starting
        /// Its host died before closing; starting the project recovers it.
        case unfinished
        /// Recovery is running now.
        case recovering
        /// Recovery stopped without destroying either copy of the work.
        case blocked
    }

    var project: String
    /// The workspace session, to match runtime records.
    var workspace: UUID
    var state: State
    /// The newest lifecycle event's time.
    var lastActive: Date
    /// `cage` and/or `vm`, from the runtimes started in this workspace.
    var walls: [String] = []
}

/// `rv box list`: every box, any strength. Pure; `BoxListCommand` reads
/// the workspace and runtime logs.
enum BoxListRender {
    /// The wall words of the runtimes started in `workspace`, cage first.
    /// A macOS VM records as `microvm` too, so both VMs read `vm`.
    static func walls(for workspace: UUID, runtimes: [(workspace: UUID?, backend: String)]) -> [String] {
        let backends = Set(runtimes.filter { $0.workspace == workspace }.map(\.backend))
        var words: [String] = []
        if backends.contains(RuntimeIsolationBackend.seatbelt.rawValue)
            || backends.contains(RuntimeIsolationBackend.landlock.rawValue)
        {
            words.append("cage")
        }
        if backends.contains(RuntimeIsolationBackend.microvm.rawValue) { words.append("vm") }
        return words
    }

    /// `platformNote` replaces the next step when boxes cannot start here.
    static func text(
        _ boxes: [BoxListing], home: String?, platformNote: String? = nil, timeZone: TimeZone = .current
    ) -> String {
        guard boxes.isEmpty == false else {
            if let platformNote { return "◆ rv · no boxes · \(platformNote)\n" }
            return "◆ rv · no boxes\n  → rv box claude\n"
        }
        let sorted = boxes.sorted { $0.lastActive > $1.lastActive }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d"
        let places = sorted.map { DisplayedText.field(BoxPlan.displayPath($0.project, home: home)) }
        let width = min(places.map(\.count).max() ?? 0, 40)
        var lines = ["◆ rv · \(boxes.count) \(boxes.count == 1 ? "box" : "boxes")"]
        for (box, place) in zip(sorted, places) {
            let padded = place.count < width ? place + String(repeating: " ", count: width - place.count) : place
            var facts = [word(box.state)]
            facts += box.walls
            facts.append(formatter.string(from: box.lastActive))
            if let next = next(box, home: home) { facts.append(next) }
            lines.append("  \(mark(box.state)) \(padded)   \(facts.joined(separator: " · "))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func mark(_ state: BoxListing.State) -> String {
        switch state {
        case .open: "✓"
        case .starting: "·"
        case .unfinished, .recovering: "◐"
        case .blocked: "✕"
        }
    }

    static func word(_ state: BoxListing.State) -> String {
        switch state {
        case .open: "open"
        case .starting: "starting"
        case .unfinished: "never finished"
        case .recovering: "recovering"
        case .blocked: "blocked"
        }
    }

    /// The one command for a box that needs one. Starting the project
    /// recovers an unfinished box; status explains the others.
    static func next(_ box: BoxListing, home: String?) -> String? {
        let place = BoxPlan.shellPath(box.project, home: home)
        switch box.state {
        case .open, .starting: return nil
        case .unfinished: return "rv workspace start --workspace \(place)"
        case .recovering, .blocked: return "rv workspace status --workspace \(place)"
        }
    }

    struct Row: Encodable, Equatable {
        let project: String
        let state: BoxListing.State
        let walls: [String]
        let lastActive: Date

        enum CodingKeys: String, CodingKey {
            case project, state, walls
            case lastActive = "last_active"
        }
    }

    struct Document: Encodable, Equatable {
        let schema = "rv.boxes.v1"
        let boxes: [Row]
    }

    static func document(_ boxes: [BoxListing]) -> Document {
        Document(boxes: boxes.sorted { $0.lastActive > $1.lastActive }.map {
            Row(project: $0.project, state: $0.state, walls: $0.walls, lastActive: $0.lastActive)
        })
    }
}
