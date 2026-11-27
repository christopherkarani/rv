import ArgumentParser
import Foundation
import RVDomain
import RVHistory
import RVPolicy

/// `rv news`: what is new in the installed rv, measured on your last
/// seven days (Everyday Magic, "Release notes, measured on your week").
///
/// Read-only and local: it reads the decision log and the audit log and
/// never writes them, never talks to rvd, and never reaches the network.
struct NewsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "news",
        abstract: "What's new in this rv, measured on your week."
    )

    @OptionGroup
    var format: FormatFlags

    func run() throws {
        let ctx = CommandContext.current(command: "news", format: format)
        let home = try ctx.requireHome()
        let report = NewsReport(
            version: ProductVersion.semver,
            week: NewsWeek.read(configDirectory: RVPolicyPaths.configDirectory(home: home), now: Date()),
            notes: ReleaseNotes.notes(for: ProductVersion.semver)
        )
        if ctx.explicitRobot {
            ctx.writeStdout(try RobotJSON.encode(report.robot) + "\n")
            return
        }
        let palette = BoxInk.palette(isTerminal: CLIProcess.stdoutIsTTY(), environment: CLIProcess.environment())
        ctx.writeStdout(BoxInk.paint(report.text, palette: palette))
    }
}

/// Your last seven days, counted from what rvd already wrote.
struct NewsWeek: Equatable, Sendable {
    static let window: TimeInterval = 7 * 24 * 60 * 60

    /// Commands the hook door decided (decision log), nil when this Mac
    /// keeps no decision log (`decisions.enabled: false`, or an older rvd).
    var checked: Int?
    /// rv could not finish deciding and refused (decision log).
    var refused: Int
    /// Guarding stopped it (`command.denied`, audit log).
    var stopped: Int
    /// Watch mode would have stopped it and let it run (`command.observed`).
    var watched: Int
    /// The host that asked rv the most, and its share of `checked`.
    var busiest: Busiest?

    struct Busiest: Equatable, Sendable {
        var host: String
        var percent: Int
    }

    static func read(configDirectory: URL, now: Date) -> NewsWeek {
        let since = now.addingTimeInterval(-window)
        let log = DecisionLog(configDirectory: configDirectory)
        let decisions = log.records(since: since, now: now)
        let keepsLog = decisions.isEmpty == false || FileManager.default.fileExists(atPath: log.directory.path)
        let marks = AuditLedger(configDirectory: configDirectory).events(
            AuditFilter(since: since, kinds: [AuditEventKind.commandDenied.rawValue, AuditEventKind.commandObserved.rawValue])
        )
        return NewsWeek(
            decisions: keepsLog ? decisions : nil,
            stopped: marks.filter { $0.kind == .commandDenied }.count,
            watched: marks.filter { $0.kind == .commandObserved }.count
        )
    }

    init(checked: Int?, refused: Int, stopped: Int, watched: Int, busiest: Busiest? = nil) {
        self.checked = checked
        self.refused = refused
        self.stopped = stopped
        self.watched = watched
        self.busiest = busiest
    }

    init(decisions: [DecisionRecord]?, stopped: Int, watched: Int) {
        let counts = Dictionary(grouping: decisions ?? [], by: \.host.rawValue).mapValues(\.count)
        let top = counts.max { ($0.value, $1.key) < ($1.value, $0.key) }
        let total = decisions?.count ?? 0
        self.init(
            checked: decisions.map(\.count),
            refused: decisions?.filter { $0.verdict == .refused }.count ?? 0,
            stopped: stopped,
            watched: watched,
            busiest: top.flatMap { total > 0 ? Busiest(host: $0.key, percent: $0.value * 100 / total) : nil }
        )
    }
}

/// One line of release notes. A note about something rv counts shows
/// this week's number beside it.
struct ReleaseNote: Equatable, Sendable {
    enum Measure: Equatable, Sendable {
        case watched
        case stopped
        case refused
    }

    var text: String
    var measure: Measure?

    init(_ text: String, measure: Measure? = nil) {
        self.text = text
        self.measure = measure
    }
}

struct NewsReport: Equatable, Sendable {
    var version: String
    var week: NewsWeek
    var notes: [ReleaseNote]

    var text: String {
        let rv = CommandVocabulary.Glyph.rv.rawValue
        var lines = ["\(rv) rv \(version) · your last 7 days", ""]
        if let checked = week.checked {
            lines.append("  checked   \(Self.number(checked)) \(checked == 1 ? "command" : "commands") · \(Self.number(week.stopped)) stopped · \(Self.number(week.watched)) watched")
        } else {
            lines.append("  stopped   \(Self.number(week.stopped)) · \(Self.number(week.watched)) watched")
            lines.append("            no decision log here, so no count of commands checked")
        }
        if week.refused > 0 {
            lines.append("  refused   \(Self.number(week.refused)) rv could not finish checking")
        }
        if let busiest = week.busiest {
            lines.append("  busiest   \(DisplayedText.field(busiest.host)) \(busiest.percent)%")
        }
        lines.append("")
        if notes.isEmpty {
            lines.append("  No notes for \(version) in this build.")
        } else {
            lines.append("  new in \(version)")
            for note in notes {
                var line = "  \(rv) \(note.text)"
                if let measure = note.measure {
                    line += " · \(Self.number(count(measure))) this week"
                }
                lines.append(line)
            }
        }
        lines.append("")
        lines.append("\(CommandVocabulary.Glyph.next.rawValue) \(CommandVocabulary.Command.blocks.invocation)   every stop and would-stop this week")
        return lines.joined(separator: "\n") + "\n"
    }

    var robot: Robot {
        Robot(
            version: version, checked: week.checked, refused: week.refused, stopped: week.stopped,
            watched: week.watched, busiest: week.busiest.map { Robot.Busiest(host: $0.host, percent: $0.percent) },
            notes: notes.map(\.text)
        )
    }

    struct Robot: Encodable, Equatable {
        let schema = "rv.news.v1"
        let windowDays = 7
        var version: String
        var checked: Int?
        var refused: Int
        var stopped: Int
        var watched: Int
        /// The host that asked rv the most this week; null with no decisions.
        var busiest: Busiest?
        var notes: [String]

        struct Busiest: Encodable, Equatable {
            var host: String
            var percent: Int
        }

        enum CodingKeys: String, CodingKey {
            case schema, version, checked, refused, stopped, watched, busiest, notes
            case windowDays = "window_days"
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schema, forKey: .schema)
            try container.encode(windowDays, forKey: .windowDays)
            try container.encode(version, forKey: .version)
            try container.encode(checked, forKey: .checked)
            try container.encode(refused, forKey: .refused)
            try container.encode(stopped, forKey: .stopped)
            try container.encode(watched, forKey: .watched)
            try container.encode(busiest, forKey: .busiest)
            try container.encode(notes, forKey: .notes)
        }
    }

    private func count(_ measure: ReleaseNote.Measure) -> Int {
        switch measure {
        case .watched: week.watched
        case .stopped: week.stopped
        case .refused: week.refused
        }
    }

    /// `1,204`, the same on every locale.
    static func number(_ value: Int) -> String {
        let digits = String(value.magnitude)
        var grouped = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { grouped.append(",") }
            grouped.append(digit)
        }
        return value < 0 ? "-" + grouped : grouped
    }
}

/// The highlights of each release, in rv's words. The CHANGELOG has the
/// full list; this is what a person notices.
enum ReleaseNotes {
    static func notes(for version: String) -> [ReleaseNote] {
        byVersion[version] ?? []
    }

    static let byVersion: [String: [ReleaseNote]] = [
        "0.2.2": [
            ReleaseNote("Watch mode keeps a record of what guarding would stop (rv blocks)", measure: .watched),
            ReleaseNote("Each agent gets its own guard mode (rv host list)"),
            ReleaseNote("rv run --secret NAME -- cmd hands a command placeholders, not your keys"),
            ReleaseNote("rv setup teaches Claude Code, Codex and OpenCode about rv with a skill"),
            ReleaseNote("Hooks that cannot reach rvd say why, and rvd outages no longer stall agents"),
            ReleaseNote("rv policy rollback restores an earlier policy from its verified history"),
        ],
    ]
}
