#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import RVDomain
import RVGlance
import SwiftUI

/// The Now section: each agent host and what it last ran.
struct GlanceAgentRows: View {
    let agents: [GlanceAgent]
    let now: Date
    /// rvd is down: whatever these agents run next is not checked.
    let unguarded: Bool

    var body: some View {
        if agents.isEmpty {
            Text("No agent has run a command yet today.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        } else {
            ForEach(agents, id: \.host) { agent in
                GlanceRow(
                    avatar: Text(agent.monogram).font(.system(size: 11, weight: .bold)).foregroundStyle(.black),
                    avatarFill: GlanceTheme.avatar(agent.host),
                    title: agent.name,
                    detail: unguarded ? "not guarded · last: \(agent.lastAction)" : agent.lastAction,
                    trailing: agent.idleLabel(at: now) ?? GlanceClock.ago(from: agent.lastAt, to: now),
                    trailingColor: unguarded ? GlanceTheme.stop : .secondary)
            }
        }
    }
}

/// The last command rv stopped, with the rule that stopped it.
struct GlanceStopRow: View {
    let stop: GlanceStop
    let now: Date
    let calendar: Calendar

    var body: some View {
        let who = GlanceAgent.displayName(stop.host)
        let rule = stop.rule.map { " · \($0)" } ?? ""
        GlanceRow(
            avatar: Text(CommandVocabulary.Glyph.stopped.rawValue)
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(GlanceTheme.stop),
            avatarFill: GlanceTheme.stop.opacity(0.18),
            title: stop.action,
            titleIsCode: true,
            detail: "\(who)\(rule) · \(GlanceClock.time(stop.at, calendar: calendar))",
            trailing: GlanceClock.ago(from: stop.at, to: now),
            trailingColor: .secondary)
        .accessibilityLabel(Text("\(CommandVocabulary.Glyph.stopped.word) \(stop.action), \(who)\(rule)"))
    }
}

struct GlanceRow<Avatar: View>: View {
    let avatar: Avatar
    let avatarFill: Color
    let title: String
    var titleIsCode = false
    let detail: String
    let trailing: String
    let trailingColor: Color

    var body: some View {
        HStack(spacing: 10) {
            avatar
                .frame(width: 28, height: 28)
                .background(avatarFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(titleIsCode ? .system(size: 12.5, design: .monospaced) : .system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Text(trailing)
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(trailingColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}

struct GlanceFooter: View {
    let onQuit: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Text("Read-only: this menu never changes rv")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            if let onQuit {
                Button(action: onQuit) {
                    Text("Quit")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q")
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 10)
    }
}
#endif
