import Foundation
import RVDomain
import RVPresentation

/// Inspect-time File tool door. Installation and doctor classify through here.
enum HostWiring {
    static func fileTools(
        host: HookHost,
        adapterData: Data?,
        companionJSON: Data?
    ) -> DoctorFileToolsState {
        switch host {
        case .pi, .opencode, .openclaw, .hermes, .codex:
            return .notApplicable
        case .claude:
            guard let adapterData,
                  let slice = ClaudeRVSlice.decode(from: adapterData),
                  slice.hasFileToolMatchers
            else {
                return .shellOnly
            }
            return .wired
        case .grok:
            guard let adapterData, hasFileToolDoor(in: adapterData) else {
                return .shellOnly
            }
            return .wired
        case .cursor:
            guard let companionJSON,
                  let slice = CursorRVSlice.decode(from: companionJSON),
                  slice.registersPreToolUse
            else {
                return .shellOnly
            }
            return .wired
        }
    }

    /// Open PreToolUse (no matcher) is wired for Read / Edit / Write; a matcher is shell-only.
    static func hasFileToolDoor(in data: Data) -> Bool {
        guard let root = jsonObject(data),
              let hooks = root["hooks"] as? [String: Any],
              let pre = hooks["PreToolUse"] as? [[String: Any]],
              let first = pre.first
        else {
            return false
        }
        return first["matcher"] == nil
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
