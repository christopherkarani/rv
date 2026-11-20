import Foundation
import RVDomain
import RVHooks
import Synchronization
import Testing

/// `hookWire` binds the host's session id while the shell and file ports
/// run, so the denial rows they write can name the agent session.
@Suite struct HookSessionAttributionTests {
    private final class Seen: Sendable {
        let sessions = Mutex<[String?]>([])
        func record() { sessions.withLock { $0.append(HookSessionAttribution.current?.rawValue) } }
    }

    @Test func shellAndFilePortsSeeTheRequestSession() async {
        let seen = Seen()
        let world = hookWorld(
            evaluate: { _, _ in seen.record(); return EvaluationResult(outcome: .plain) },
            evaluateFile: { _, _ in seen.record(); return EvaluationResult(outcome: .plain) }
        )
        _ = await hookWire(host: .claude, stdin: """
            {"hook_event_name":"PreToolUse","session_id":"sess-1","tool_name":"Bash","tool_input":{"command":"ls"}}
            """, world: world)
        _ = await hookWire(host: .claude, stdin: """
            {"hook_event_name":"PreToolUse","session_id":"sess-2","tool_name":"Read","tool_input":{"file_path":"/tmp/a"}}
            """, world: world)
        _ = await hookWire(host: .claude, stdin: """
            {"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}
            """, world: world)
        #expect(seen.sessions.withLock { $0 } == ["sess-1", "sess-2", nil])
        #expect(HookSessionAttribution.current == nil, "unbound once the request is answered")
    }
}
