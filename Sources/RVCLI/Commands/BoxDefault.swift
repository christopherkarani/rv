import ArgumentParser
import Foundation
import RVDomain
import RVHistory
import RVPolicy

private typealias Glyph = CommandVocabulary.Glyph

/// Boxed by default (L5, Q6: opt-in now, the default only after a
/// release of real use). Once the owner turns it on, an agent rv starts
/// (`rv opencode`) runs in a box without `rv box`, and every boxed
/// session ends with the review on the way home (`rv box done`).
///
/// Stored as `~/.config/rv/box.json`. A missing or unreadable file is
/// off, which is how rv behaved before: never weaker than today.
struct BoxDefaultSetting: Codable, Equatable, Sendable {
    var version = 1
    var boxedByDefault: Bool

    static let fileName = "box.json"
    /// The name the change has in the audit log.
    static let auditName = "box.default"

    static func url(home: HomeDirectory) -> URL {
        RVPolicyPaths.configDirectory(home: home).appendingPathComponent(fileName, isDirectory: false)
    }

    /// Whether boxed by default is on for `home`; off when unset.
    static func isOn(home: HomeDirectory?) -> Bool {
        guard let home, let data = try? Data(contentsOf: url(home: home)),
            let setting = try? JSONDecoder().decode(BoxDefaultSetting.self, from: data)
        else { return false }
        return setting.boxedByDefault
    }

    static func write(_ on: Bool, home: HomeDirectory) throws {
        let directory = RVPolicyPaths.configDirectory(home: home)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(BoxDefaultSetting(boxedByDefault: on))
        data.append(UInt8(ascii: "\n"))
        try data.write(to: url(home: home), options: .atomic)
    }
}

/// `rv box default [on | off]`, as parsed from the words after `default`.
enum BoxDefaultRequest: Equatable, Sendable {
    case show
    case turn(on: Bool)

    static func parse(_ rest: [String]) -> Result<BoxDefaultRequest, BoxRefusal> {
        switch rest {
        case []: .success(.show)
        case ["on"]: .success(.turn(on: true))
        case ["off"]: .success(.turn(on: false))
        default:
            .failure(BoxRefusal(
                why: "rv box default takes on or off.", fix: "rv box default on", exitCode: 64))
        }
    }
}

/// Which agents boxed by default reaches, and why the rest don't, in one
/// honest line each. Only `rv opencode` is a launcher rv owns; every
/// other host is wired through a hook rv hears per tool call, after the
/// agent has already started on the host, so there is nothing to box.
enum BoxDefaultCoverage {
    struct Line: Equatable, Sendable {
        var agent: String
        var boxed: Bool
        var why: String
    }

    static let lines: [Line] = [
        Line(agent: "opencode", boxed: true, why: "rv opencode starts in a box"),
        Line(agent: "claude", boxed: false, why: "rv hears its tool calls, not its start · rv box claude boxes it"),
        Line(agent: "codex", boxed: false, why: "rv hears its tool calls, not its start · rv box codex boxes it"),
        Line(agent: "cursor", boxed: false, why: "it's an app, and rv can't start an app in a box"),
    ]

    static func text(_ line: Line) -> String {
        line.boxed
            ? "  \(Glyph.done.rawValue) \(line.agent) · \(line.why)"
            : "  \(Glyph.watched.rawValue) \(line.agent) isn't boxed yet: \(line.why)"
    }
}

/// The words of `rv box default`. One idea per line; the next command last.
enum BoxDefaultText {
    static func status(on: Bool) -> String {
        guard on else {
            return "\(Glyph.rv.rawValue) rv · boxed by default is off · agents start on your Mac\n"
                + "  \(Glyph.next.rawValue) turn it on: rv box default on\n"
        }
        return (["\(Glyph.rv.rawValue) rv · boxed by default is on · changes come home as a review"]
            + BoxDefaultCoverage.lines.map(BoxDefaultCoverage.text)
            + ["  \(Glyph.next.rawValue) turn it off: rv box default off"]).joined(separator: "\n") + "\n"
    }

    static let turnedOn = (
        ["  \(Glyph.done.rawValue) Boxed by default. rv opencode starts in a box, and its changes come home as a review."]
            + BoxDefaultCoverage.lines.filter { $0.boxed == false }.map(BoxDefaultCoverage.text)
            + ["  \(Glyph.next.rawValue) Undo: rv box default off"]
    ).joined(separator: "\n") + "\n"

    static let turnedOff = "  \(Glyph.done.rawValue) Agents start on your Mac again, outside a box.\n"
        + "  \(Glyph.next.rawValue) Turn it back on: rv box default on\n"

    static func already(on: Bool) -> String {
        "  \(Glyph.done.rawValue) Boxed by default is already \(on ? "on" : "off").\n"
    }

    /// Without a terminal nobody can have typed it: an agent's pipe.
    static func needsTerminal(on: Bool) -> BoxRefusal {
        BoxRefusal(
            why: "Only you can turn boxed by default \(on ? "on" : "off"), at your terminal.",
            fix: "type it in Terminal: rv box default \(on ? "on" : "off")",
            exitCode: OwnerConfirmation.refusalExitCode)
    }

    static func unwritable(_ path: String) -> BoxRefusal {
        BoxRefusal(why: "rv couldn't write \(DisplayedText.field(path)); nothing changed.", fix: "rv doctor")
    }

    /// The owner prompt's summary.
    static func summary(on: Bool) -> String {
        "turn boxed by default \(on ? "on" : "off")"
    }
}

/// `rv box default`: show, or turn it on or off. Turning it either way is
/// the owner's alone: a terminal, then the owner check (Touch ID or the
/// login password at rvd's prompt), and the hook guard refuses it from an
/// agent (`SelfProtectionGuard`).
enum BoxDefaultFlow {
    #if os(macOS)
    static let platformSupportsBoxes = true
    #else
    static let platformSupportsBoxes = false
    #endif

    static func run(_ request: BoxDefaultRequest, supportsBoxes: Bool = platformSupportsBoxes) async throws {
        let home = try CommandContext.requireHome(command: "box default")
        let current = BoxDefaultSetting.isOn(home: home)
        switch request {
        case .show:
            write(BoxDefaultText.status(on: current))
        case .turn(let on):
            if on, supportsBoxes == false { try refuse(BoxPlan.linuxHostRefusal) }
            if current == on {
                write(BoxDefaultText.already(on: on))
                return
            }
            guard CLIProcess.stdinIsTTY(), CLIProcess.stdoutIsTTY() else {
                try refuse(BoxDefaultText.needsTerminal(on: on))
            }
            let authorization = try await OwnerConfirmation.require(BoxDefaultText.summary(on: on))
            let configDirectory = RVPolicyPaths.configDirectory(home: home)
            do {
                try ConfigChangeAudit.$authorization.withValue(authorization) {
                    // Made inside the binding: the event takes `authorized_by` from it.
                    let event = ConfigChangeAudit.setting(
                        BoxDefaultSetting.auditName, from: current ? "on" : "off", to: on ? "on" : "off",
                        direction: on ? .tightening : .loosening)
                    try ConfigChangeAudit.commit(event, configDirectory: configDirectory) {
                        try BoxDefaultSetting.write(on, home: home)
                    }
                }
            } catch let unrecorded as ConfigChangeUnrecorded {
                try ConfigChangeRefusal.fail(command: "box default", unrecorded)
            } catch {
                try refuse(BoxDefaultText.unwritable(BoxDefaultSetting.url(home: home).path))
            }
            write(on ? BoxDefaultText.turnedOn : BoxDefaultText.turnedOff)
        }
    }

    private static func write(_ text: String) {
        CommandContext.writeStdout(BoxInk.paint(text, palette: BoxInk.palette(
            isTerminal: CLIProcess.stdoutIsTTY(), environment: CLIProcess.environment())))
    }

    private static func refuse(_ refusal: BoxRefusal) throws -> Never {
        CommandContext.writeStderr(BoxInk.paint(refusal.text, palette: BoxInk.palette(
            isTerminal: CLIProcess.stdoutIsTTY(), environment: CLIProcess.environment())))
        throw ExitCode(refusal.exitCode)
    }
}

/// How a boxed launch introduces itself.
enum BoxPresentation: Equatable, Sendable {
    /// `rv box <agent>`: the header, then each wall once the host launched it.
    case asked
    /// Boxed by default: one line, the only sign (v4b "You never type rv box").
    case byDefault
}

extension BoxLaunch {
    /// The agent the review speaks of: the hook host it was launched as.
    var agentName: String? { hook?.rawValue }
}

extension BoxPlan {
    /// `◆ boxed · ~/code/app · keys via rv · public HTTPS only`, and the
    /// step that stages keys when there are none.
    static func boxedLine(_ launch: BoxLaunch, home: String?) -> String {
        let place = DisplayedText.field(displayPath(launch.project, home: home))
        let keys: String
        var next: String?
        switch launch.keys {
        case .placeholders, .profile:
            keys = "keys via rv"
        case .none(let command):
            keys = "no keys staged"
            next = command
        }
        var text = "\(Glyph.rv.rawValue) boxed · \(place) · \(keys) · public HTTPS only\n"
        if let next { text += "  \(Glyph.next.rawValue) \(next)\n" }
        return text
    }
}
