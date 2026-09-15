import Foundation

/// File-tool door on a Grok Host adapter (`rv.json`). Open PreToolUse (no matcher)
/// is wired for Read / Edit / Write; a matcher is shell-only.
/// Exclusive adapter bytes are not merged into a foreign remainder — setup writes
/// the rendered template through `HostWiring.applyGrok`.
enum GrokHookInspect {
    static func merge(existingData: Data?, rendered: Data) -> (data: Data, wrote: Bool) {
        (rendered, existingData != rendered)
    }

    static func hasFileToolDoor(in data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any],
              let pre = hooks["PreToolUse"] as? [[String: Any]],
              let first = pre.first
        else {
            return false
        }
        return first["matcher"] == nil
    }
}
