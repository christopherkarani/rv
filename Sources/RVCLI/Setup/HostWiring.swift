import Foundation
import RVDomain
import RVPresentation

/// File-tool door derived from Host adapter bytes and optional companion JSON.
enum HostWiring {
    static func fileTools(
        host: HookHost,
        adapterBytes: Data?,
        companionJSON: Data?
    ) -> DoctorFileToolsState {
        switch host {
        case .pi, .opencode, .openclaw, .hermes, .codex:
            return .notApplicable
        case .claude:
            guard let adapterBytes else {
                return .notApplicable
            }
            guard let root = jsonObject(adapterBytes),
                  ClaudeSettingsMerge.hasFileToolMatchers(in: root)
            else {
                return .shellOnly
            }
            return .wired
        case .grok:
            guard let adapterBytes else {
                return .notApplicable
            }
            return GrokHookInspect.hasFileToolDoor(in: adapterBytes) ? .wired : .shellOnly
        case .cursor:
            guard adapterBytes != nil else {
                return .notApplicable
            }
            guard let companionJSON,
                  let root = jsonObject(companionJSON),
                  CursorHooksMerge.hasFileToolEntry(in: root)
            else {
                return .shellOnly
            }
            return .wired
        }
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
