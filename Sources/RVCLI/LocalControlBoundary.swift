import ArgumentParser
import RVDomain
import RVHooks

/// Transitional fail-closed boundary until authenticated service mutation routes exist.
enum LocalControlBoundary {
    static let reason = "Authenticated RV service and operation-bound owner authorization required."

    static func requireOwnerAuthorization() throws {
        throw ValidationError(reason)
    }

    static func deniedHook(host: HookHost) -> HookWire {
        let codec: any HostCodec
        switch host {
        case .grok: codec = GrokHostCodec()
        case .pi: codec = PiHostCodec()
        case .opencode: codec = OpenCodeHostCodec()
        case .claude: codec = ClaudeHostCodec()
        case .openclaw: codec = OpenClawHostCodec()
        case .hermes: codec = HermesHostCodec()
        case .codex: codec = CodexHostCodec()
        case .cursor: codec = CursorHostCodec()
        case .antigravity: codec = AntigravityHostCodec()
        }
        return codec.encodeDeny(reason: reason, rule: nil, next: .none)
    }
}
