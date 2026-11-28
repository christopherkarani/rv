import Foundation
import RVDomain

/// The agent's own one-line description of the command it wants to run,
/// when its host sends one (Claude Code's Bash tool: `tool_input.description`,
/// "Force-push my rebased branch").
///
/// Display only, for the menu bar's approval sheet (K2), which labels it as
/// the agent's words. The agent wrote it, so nothing in rv decides on it:
/// it never reaches evaluation, a grant, the deny text or the audit log.
public enum HookAgentSays {
    /// Longest stdin this reads, in bytes. A hook envelope past it has no
    /// line worth showing.
    static let maxStdinBytes = 256 * 1024

    /// The line, or nil when the host sends none or the envelope does not
    /// decode. Never throws: a missing line costs the sheet one row.
    public static func line(host: HookHost, stdin: String) -> String? {
        guard host == .claude, stdin.utf8.count <= maxStdinBytes else { return nil }
        guard let envelope = try? JSONDecoder().decode(ClaudeDescribed.self, from: Data(stdin.utf8)),
            envelope.toolName == "Bash"
        else { return nil }
        let line = envelope.toolInput?.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return line.isEmpty ? nil : line
    }

    private struct ClaudeDescribed: Decodable {
        var toolName: String?
        var toolInput: Input?

        struct Input: Decodable {
            var description: String?
        }

        enum CodingKeys: String, CodingKey {
            case toolName = "tool_name"
            case toolInput = "tool_input"
        }
    }
}
