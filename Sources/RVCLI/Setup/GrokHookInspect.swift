import Foundation

/// File-tool door on a Grok Host adapter (`rv.json`). Open PreToolUse (no matcher)
/// is wired for Read / Edit / Write; a matcher is shell-only.
enum GrokHookInspect {
    static func hasFileToolDoor(in data: Data) -> Bool {
        HostWiring.hasFileToolDoor(in: data)
    }
}
