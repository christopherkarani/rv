import Foundation
import RVDomain

/// How loudly a notice may arrive (UserNotifications' interruption levels).
public enum GlanceNoticeLevel: String, Sendable, Equatable {
    /// Into Notification Center without a sound or banner pressure.
    case passive
    case active
    /// Breaks through a Focus that allows Time Sensitive notifications.
    case timeSensitive
}

/// One notification. Posting a notice whose `id` is already delivered
/// replaces it, which is how an agent keeps one banner.
public struct GlanceNotice: Sendable, Equatable {
    public var id: String
    public var thread: String
    public var title: String
    public var body: String
    public var level: GlanceNoticeLevel

    public init(id: String, thread: String, title: String, body: String, level: GlanceNoticeLevel) {
        self.id = id
        self.thread = thread
        self.title = title
        self.body = body
        self.level = level
    }
}

public enum GlanceNoticeAction: Sendable, Equatable {
    case post(GlanceNotice)
    case remove([String])
}

/// Where notices go. The macOS app hands them to UserNotifications.
public protocol GlanceNoticeSink: Sendable {
    func deliver(_ actions: [GlanceNoticeAction]) async
}

/// Notification etiquette (Menu bar v5, "Polite by default. Loud only for
/// a question"). Fed each new `GlanceState`, it decides what to notify:
/// - only a question interrupts: an agent's first new ask is Time
///   Sensitive; more asks from it within `groupWindow` update its one
///   banner quietly ("3 from claude");
/// - nothing that already happened notifies: stops, would-blocks in watch
///   mode and allows only move the glyph and the popover;
/// - rvd going down is Time Sensitive, at most once per `downQuietPeriod`;
/// - an answered ask takes its banner away.
public struct GlanceEtiquette: Sendable {
    public static let groupWindow: TimeInterval = 60
    public static let downQuietPeriod: TimeInterval = 300
    public static let downID = "rv.rvd-down"

    /// Asks already announced, so an rvd that blips never re-alerts them.
    private var announced: Set<ApprovalID> = []
    /// The count each delivered ask banner shows, per agent.
    private var shown: [HookHost: Int] = [:]
    private var lastAskAlert: [HookHost: Date] = [:]
    private var lastDownAlert: Date?

    public init() {}

    public static func askID(_ host: HookHost) -> String {
        "rv.ask.\(host.rawValue)"
    }

    /// What changed between two states, as notices to post or take away.
    public mutating func plan(from old: GlanceState, to new: GlanceState, now: Date) -> [GlanceNoticeAction] {
        let wasDown = old.link.isDown
        if new.link.isDown {
            return wasDown ? [] : wentDown(now: now)
        }
        var actions: [GlanceNoticeAction] = wasDown ? [.remove([Self.downID])] : []
        actions += asks(new.pending, now: now)
        return actions
    }

    private mutating func asks(_ pending: [ApprovalID: HookHost], now: Date) -> [GlanceNoticeAction] {
        var actions: [GlanceNoticeAction] = []
        let hosts = Set(pending.values).union(shown.keys).sorted { $0.rawValue < $1.rawValue }
        for host in hosts {
            let ids = pending.filter { $0.value == host }.map(\.key)
            guard !ids.isEmpty else {
                shown[host] = nil
                actions.append(.remove([Self.askID(host)]))
                continue
            }
            let fresh = ids.filter { !announced.contains($0) }
            announced.formUnion(fresh)
            if !fresh.isEmpty {
                let loud = lastAskAlert[host].map { now.timeIntervalSince($0) >= Self.groupWindow } ?? true
                if loud { lastAskAlert[host] = now }
                actions.append(.post(Self.askNotice(host, count: ids.count, level: loud ? .timeSensitive : .passive)))
            } else if shown[host] != ids.count {
                actions.append(.post(Self.askNotice(host, count: ids.count, level: .passive)))
            }
            shown[host] = ids.count
        }
        announced.formIntersection(pending.keys)
        return actions
    }

    private mutating func wentDown(now: Date) -> [GlanceNoticeAction] {
        var actions: [GlanceNoticeAction] = []
        if !shown.isEmpty {
            actions.append(.remove(shown.keys.sorted { $0.rawValue < $1.rawValue }.map(Self.askID)))
            shown = [:]
        }
        let loud = lastDownAlert.map { now.timeIntervalSince($0) >= Self.downQuietPeriod } ?? true
        if loud { lastDownAlert = now }
        actions.append(.post(GlanceNotice(
            id: Self.downID, thread: "rv.rvd", title: "rv isn't running",
            body: "Agents are unguarded · run \(GlanceHeadline.downFix)",
            level: loud ? .timeSensitive : .passive)))
        return actions
    }

    static func askNotice(_ host: HookHost, count: Int, level: GlanceNoticeLevel) -> GlanceNotice {
        let body = count == 1
            ? "1 request is waiting in the menu bar"
            : "\(count) from \(host.rawValue) · answer in the menu bar"
        return GlanceNotice(
            id: askID(host), thread: askID(host), title: "\(host.rawValue) needs you", body: body, level: level)
    }
}

extension GlanceLink {
    var isDown: Bool {
        if case .down = self { return true }
        return false
    }
}
