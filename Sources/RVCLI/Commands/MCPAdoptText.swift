import Foundation
import RVDomain
import RVIsolation
import RVMCP

/// The words of `rv mcp add` and `rv mcp remove`, from the MCP gateway page
/// (v6): `◆` rv speaking, `✓` through rv, `◐` needs you, `✕` stays out, `→`
/// the one next command. Plain text; the command paints the glyphs on a
/// terminal (`BoxInk`). Names, commands and paths only: an environment or
/// header value never reaches this text.
enum MCPAdoptText {
    typealias Glyph = CommandVocabulary.Glyph

    /// `rv mcp add cursor`, as the person typed the host.
    static func command(_ verb: String, typed: String?) -> String {
        ["\(CommandVocabulary.Command.mcp.invocation) \(verb)", typed].compactMap { $0 }.joined(separator: " ")
    }

    /// `Cursor`, `Cursor and Claude Code`, `3 hosts`.
    static func hostList(_ hosts: [MCPHost]) -> String {
        switch hosts.count {
        case 0: "your agents' configs"
        case 1, 2: hosts.map(\.displayName).joined(separator: " and ")
        default: "\(hosts.count) hosts"
        }
    }

    static func servers(_ count: Int) -> String { count == 1 ? "1 MCP server" : "\(count) MCP servers" }

    /// The heading, every server with what rv will do with it, the keys
    /// that move, and any host file rv could not read.
    static func survey(
        _ survey: MCPAdoptionSurvey, asked: [MCPHost], problems: [MCPInventoryProblem], home: URL
    ) -> [String] {
        let hosts = survey.hosts.isEmpty ? asked : survey.hosts
        guard survey.found > 0 else {
            return ["\(Glyph.rv.rawValue) rv found no MCP servers in \(hostList(hosts))"]
                + problems.map { problemLine($0, home: home) }
        }
        var lines = [
            "\(Glyph.rv.rawValue) rv found \(servers(survey.found)) in \(hostList(hosts)), \(survey.notGoverned) not governed",
        ]
        let width = survey.rows.map { MCPDisplayedText.field($0.name).count }.max() ?? 0
        for host in survey.hosts {
            let indent = survey.hosts.count > 1 ? "    " : "  "
            if survey.hosts.count > 1 { lines.append("  \(host.displayName)") }
            for row in survey.rows where row.host == host {
                lines.append(indent + rowLine(row, width: width))
            }
        }
        let keys = survey.keys
        if keys.isEmpty == false {
            let noun = keys.count == 1 ? "1 key moves" : "\(keys.count) keys move"
            lines.append("  \(noun) to \(SecretKeychain.storeName): " + keys.map(MCPDisplayedText.field).joined(separator: ", "))
        }
        lines += survey.imports.notes.map { "  note: " + MCPDisplayedText.field($0) }
        lines += problems.map { problemLine($0, home: home) }
        return lines
    }

    static func rowLine(_ row: MCPAdoptionRow, width: Int) -> String {
        let name = MCPDisplayedText.field(row.name)
        let padded = name + String(repeating: " ", count: max(0, width - name.count))
        switch row.verdict {
        case .governed:
            return "\(Glyph.done.rawValue) \(padded)  through rv"
        case .leave(let reason):
            return "\(Glyph.stopped.rawValue) \(padded)  \(MCPDisplayedText.field(reason))"
        case .adopt(let taking):
            var detail = [MCPDisplayedText.field(row.shown), takingNote(taking)]
            if row.host == .codex { detail.append("one Codex command, below") }
            return "\(Glyph.watched.rawValue) \(padded)  " + detail.joined(separator: " · ")
        }
    }

    /// What rv makes of a server it takes, in the gateway page's words.
    static func takingNote(_ taking: MCPAdoptionTaking) -> String {
        switch taking {
        case .remote: "remote"
        case .reviewed: "rv already has it"
        case .local(let sandbox?) where sandbox.network == false && sandbox.hosts.isEmpty: "sealed · no network"
        case .local(let sandbox?) where sandbox.hosts.isEmpty == false:
            "sealed · " + sandbox.hosts.map(MCPDisplayedText.field).joined(separator: ", ") + " only"
        case .local(.some(_)): "sandboxed"
        case .local(nil): "local · no sandbox yet"
        }
    }

    static func problemLine(_ problem: MCPInventoryProblem, home: URL) -> String {
        "\(Glyph.stopped.rawValue) \(MCPDisplayedText.field(MCPRun.abbreviate(problem.path, home: home)))  "
            + MCPDisplayedText.field(problem.message) + "; rv left it alone"
    }

    /// Every host file rv rewrites, with each entry before (`-`) and after
    /// (`+`). Values are masked by `MCPAdoption.shownEntry`.
    static func diff(_ changes: [MCPRouteChange], relaid: [String] = [], home: URL) -> [String] {
        var lines: [String] = []
        var seen = Set<String>()
        for change in changes where seen.insert(change.path).inserted {
            let shown = MCPDisplayedText.field(MCPRun.abbreviate(change.path, home: home))
            lines.append("  " + shown + (relaid.contains(change.path) ? " (rv writes it back in its own layout)" : ""))
            for entry in changes where entry.path == change.path {
                lines.append("  - " + entry.before)
                lines.append("  + " + entry.after)
            }
        }
        return lines
    }

    static func manualSteps(_ steps: [String]) -> [String] {
        guard steps.isEmpty == false else { return [] }
        return ["  Codex keeps servers in TOML, which rv does not rewrite; after this, run:"]
            + steps.map { "    " + $0 }
    }

    /// The last line when there is nothing for rv to take.
    static func nothingToAdd(_ survey: MCPAdoptionSurvey) -> String {
        if survey.found > 0, survey.notGoverned == 0 {
            return "\(Glyph.done.rawValue) Every server already runs through rv."
        }
        return survey.found == 0 ? "  nothing to add" : "  nothing rv can add; each line says why"
    }

    /// `✓ Cursor is ready. Restart it once.` (the gateway page's line) when
    /// rv took every server of one host, else the count.
    static func done(_ survey: MCPAdoptionSurvey, taken: Int, undo: String) -> [String] {
        let hosts = MCPHost.allCases.filter { survey.routes[$0]?.isEmpty == false }
        let everything = taken == survey.notGoverned
        let headline = hosts.count == 1 && everything
            ? "\(Glyph.done.rawValue) \(hosts[0].displayName) is ready. Restart it once."
            : "\(Glyph.done.rawValue) \(taken == 1 ? "1 server" : "\(taken) servers") through rv. Restart \(hostList(hosts)) once."
        return [headline, "  undo: \(undo)"]
    }

    /// The one-line refusal, and its fix, when this process has no terminal.
    static func needsTerminal(_ command: String) -> String {
        "\(Glyph.stopped.rawValue) needs you at your own terminal, and this process has no terminal; nothing changed\n"
            + "\(Glyph.next.rawValue) \(command)"
    }

    /// `rv mcp remove`: what goes back, as a diff.
    static func removal(_ changes: [MCPRouteChange], hosts: [MCPHost], home: URL) -> [String] {
        guard changes.isEmpty == false else {
            return ["\(Glyph.rv.rawValue) rv has nothing to put back in \(hostList(hosts))"]
        }
        let changed = MCPHost.allCases.filter { host in changes.contains { $0.host == host } }
        let count = changes.count == 1 ? "1 server" : "\(changes.count) servers"
        return ["\(Glyph.rv.rawValue) rv puts back \(count) in \(hostList(changed))"] + diff(changes, home: home)
    }

    /// `✓ Cursor is back as it was.` and anything undo had to leave.
    static func removed(changed: [String], skipped: [String], hosts: [MCPHost]) -> [String] {
        let headline = skipped.isEmpty && hosts.count == 1
            ? "\(Glyph.done.rawValue) \(hosts[0].displayName) is back as it was."
            : "\(Glyph.done.rawValue) \(changed.count == 1 ? "1 server" : "\(changed.count) servers") back as they were."
        return [headline]
            + skipped.map { "\(Glyph.stopped.rawValue) \($0)" }
            + ["  rv's mcp.json and keys stay; these hosts no longer use them"]
    }
}
