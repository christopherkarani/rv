#if DEBUG
import Foundation
import RVDomain
import RVIPC

/// One state per glyph, for tests and snapshots. Debug builds only. The
/// agents, commands and times are examples.
public enum GlanceSamples {
    /// Sat 21 Nov 2026, 19:32 UTC.
    public static let now = Date(timeIntervalSince1970: 1_795_289_520)

    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    public static func state(_ glyph: GlanceGlyph) -> GlanceState {
        var state = busyDay()
        switch glyph {
        case .guarding:
            break
        case .watching:
            state.posture = .watching([.codex])
        case .needsYou:
            state.pending = [ApprovalID(rawValue: "ask-1"): .claude]
        case .justStopped:
            state.lastStop = GlanceStop(
                host: .claude, action: "git push --force origin main", rule: "core.git:force-push", at: now)
            state.today.stopped += 1
        case .boxed:
            state.boxesRunning = 1
        case .paused:
            state.pausedUntil = now.addingTimeInterval(3600)
        case .notRunning:
            state.markDown("rvd isn't answering", at: now.addingTimeInterval(-2 * 60))
        case .connecting:
            state = GlanceState(now: now, calendar: calendar)
        }
        return state
    }

    /// Three agents and a stop at 12:41, all live.
    static func busyDay() -> GlanceState {
        var state = GlanceState(now: now, calendar: calendar)
        state.link = .live
        state.agents = [
            .claude: GlanceAgent(
                host: .claude, lastAction: "swift test --filter Hook", lastAt: now.addingTimeInterval(-4),
                checkedToday: 301),
            .codex: GlanceAgent(
                host: .codex, lastAction: "pnpm lint", lastAt: now.addingTimeInterval(-20), checkedToday: 104),
            .cursor: GlanceAgent(
                host: .cursor, lastAction: "git status", lastAt: now.addingTimeInterval(-14 * 60), checkedToday: 7),
        ]
        state.today.checked = 412
        state.today.stopped = 3
        state.today.asked = 1
        state.lastStop = GlanceStop(
            host: .claude, action: "git reset --hard", rule: "core.git:reset-hard",
            at: now.addingTimeInterval(-(6 * 3600 + 51 * 60)))
        return state
    }
}
#endif
