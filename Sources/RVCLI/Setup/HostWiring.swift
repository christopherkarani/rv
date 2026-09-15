import Foundation
import RVDomain
import RVPresentation

/// File-tool door derived from Host adapter bytes and optional companion JSON.
/// Setup writes Claude / Cursor / Grok host JSON only through `apply*`.
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

    /// Merges the Claude settings.json RV slice. `fileTools` is inspect of `data`.
    static func applyClaude(
        existing existingData: Data?,
        rvPath: String,
        adapterPath: String,
        force: Bool = false
    ) throws -> (data: Data, wrote: Bool, fileTools: DoctorFileToolsState) {
        let merged = try ClaudeSettingsMerge.merge(
            existingData: existingData,
            rvPath: rvPath,
            adapterPath: adapterPath,
            force: force
        )
        return (
            data: merged.data,
            wrote: merged.wrote,
            fileTools: fileTools(host: .claude, adapterBytes: merged.data, companionJSON: nil)
        )
    }

    /// Merges the Cursor hooks.json file-tool slice. `fileTools` is inspect of
    /// the returned companion bytes with the adapter treated as present.
    static func applyCursor(
        existing existingData: Data?,
        adapterPath: String
    ) throws -> (data: Data, wrote: Bool, fileTools: DoctorFileToolsState) {
        let merged = try CursorHooksMerge.merge(
            existingData: existingData,
            adapterPath: adapterPath
        )
        return (
            data: merged.data,
            wrote: merged.wrote,
            fileTools: fileTools(
                host: .cursor,
                adapterBytes: merged.data,
                companionJSON: merged.data
            )
        )
    }

    /// Exclusive Grok `rv.json` document. `fileTools` is inspect of `data`.
    static func applyGrok(
        existing existingData: Data?,
        rendered: Data
    ) -> (data: Data, wrote: Bool, fileTools: DoctorFileToolsState) {
        let merged = GrokHookInspect.merge(existingData: existingData, rendered: rendered)
        return (
            data: merged.data,
            wrote: merged.wrote,
            fileTools: fileTools(host: .grok, adapterBytes: merged.data, companionJSON: nil)
        )
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
