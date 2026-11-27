import Foundation
import RVDomain

/// One agent host as the Glance popover lists it: what it last ran and when.
public struct GlanceAgent: Sendable, Equatable {
    /// A host with no decision for this long reads as idle.
    public static let idleAfter: TimeInterval = 120

    public var host: HookHost
    /// Redacted command or path from rvd's last decision for this host.
    public var lastAction: String
    public var lastAt: Date
    /// Decisions seen today for this host.
    public var checkedToday: Int

    public init(host: HookHost, lastAction: String, lastAt: Date, checkedToday: Int) {
        self.host = host
        self.lastAction = lastAction
        self.lastAt = lastAt
        self.checkedToday = checkedToday
    }

    public var name: String { Self.displayName(host) }

    /// Two-letter avatar text.
    public var monogram: String {
        switch host {
        case .claude: "CC"
        case .codex: "CX"
        case .cursor: "Cu"
        case .opencode: "OC"
        case .openclaw: "OW"
        default: String(name.prefix(2))
        }
    }

    public func isIdle(at now: Date) -> Bool {
        now.timeIntervalSince(lastAt) >= Self.idleAfter
    }

    /// "idle 14m" when idle, else nil.
    public func idleLabel(at now: Date) -> String? {
        guard isIdle(at: now) else { return nil }
        return "idle \(GlanceClock.ago(from: lastAt, to: now))"
    }

    public static func displayName(_ host: HookHost) -> String {
        switch host {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .opencode: "OpenCode"
        case .openclaw: "OpenClaw"
        case .grok: "Grok"
        case .pi: "Pi"
        case .hermes: "Hermes"
        case .antigravity: "Antigravity"
        case .muse: "Muse"
        }
    }
}

/// Short relative and wall-clock times for popover rows.
public enum GlanceClock {
    /// "now", "4m", "2h", "3d".
    public static func ago(from then: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(then)))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86_400)d"
        }
    }

    /// "12:41" in the given calendar's time zone.
    public static func time(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        return String(format: "%02d:%02d", hour, minute)
    }
}
