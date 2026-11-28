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
    /// Set when the banner is about exactly one stop the person can unlock
    /// (K2): its actions open the approval sheet and Touch ID for that
    /// code. Nil banners carry no actions.
    public var unlockCodeHash: String?

    public init(
        id: String, thread: String, title: String, body: String, level: GlanceNoticeLevel,
        unlockCodeHash: String? = nil
    ) {
        self.id = id
        self.thread = thread
        self.title = title
        self.body = body
        self.level = level
        self.unlockCodeHash = unlockCodeHash
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
    private var announced: Set<String> = []
    /// What each delivered ask banner shows, per agent.
    private var shown: [HookHost: Shown] = [:]

    private struct Shown: Equatable {
        var count: Int
        /// The one unlock the banner's actions answer, if any.
        var unlock: String?
    }
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
        actions += asks(Self.waiting(new), now: now)
        return actions
    }

    /// One waiting thing: a pending ask, or a stop the person can unlock.
    private struct Waiting {
        var host: HookHost
        var unlock: GlanceUnlockAsk?
    }

    /// Everything waiting, keyed so the two sources never collide.
    private static func waiting(_ state: GlanceState) -> [String: Waiting] {
        var waiting: [String: Waiting] = [:]
        for (id, host) in state.pending { waiting["ask:\(id.rawValue)"] = Waiting(host: host) }
        for (hash, ask) in state.unlocks { waiting["unlock:\(hash)"] = Waiting(host: ask.host, unlock: ask) }
        return waiting
    }

    private mutating func asks(_ waiting: [String: Waiting], now: Date) -> [GlanceNoticeAction] {
        var actions: [GlanceNoticeAction] = []
        let hosts = Set(waiting.values.map(\.host)).union(shown.keys).sorted { $0.rawValue < $1.rawValue }
        for host in hosts {
            let mine = waiting.filter { $0.value.host == host }
            guard !mine.isEmpty else {
                shown[host] = nil
                actions.append(.remove([Self.askID(host)]))
                continue
            }
            // Only a banner about exactly one stop answers it.
            let only = mine.count == 1 ? mine.first?.value.unlock : nil
            let current = Shown(count: mine.count, unlock: only?.codeHash)
            let fresh = mine.keys.filter { !announced.contains($0) }
            announced.formUnion(fresh)
            if !fresh.isEmpty {
                let loud = lastAskAlert[host].map { now.timeIntervalSince($0) >= Self.groupWindow } ?? true
                if loud { lastAskAlert[host] = now }
                actions.append(.post(Self.askNotice(
                    host, count: mine.count, level: loud ? .timeSensitive : .passive, unlock: only)))
            } else if shown[host] != current {
                actions.append(.post(Self.askNotice(host, count: mine.count, level: .passive, unlock: only)))
            }
            shown[host] = current
        }
        announced.formIntersection(waiting.keys)
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

    static func askNotice(
        _ host: HookHost, count: Int, level: GlanceNoticeLevel, unlock: GlanceUnlockAsk? = nil
    ) -> GlanceNotice {
        // A banner can reach the lock screen: it never carries the command.
        let body: String
        if let unlock {
            body = "A stopped command can run once with Touch ID · check the words: \(unlock.checkWords)"
        } else if count == 1 {
            body = "1 request is waiting in the menu bar"
        } else {
            body = "\(count) from \(host.rawValue) · answer in the menu bar"
        }
        return GlanceNotice(
            id: askID(host), thread: askID(host), title: "\(host.rawValue) needs you", body: body, level: level,
            unlockCodeHash: unlock?.codeHash)
    }
}

extension GlanceLink {
    var isDown: Bool {
        if case .down = self { return true }
        return false
    }
}
