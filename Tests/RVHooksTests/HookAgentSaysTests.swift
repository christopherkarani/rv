import Testing
import RVDomain
import RVHooks

/// K2: the agent's own one-line description of a command, read for the
/// menu bar's sheet only. Absent, undecodable or from another tool, it is
/// simply not there.
struct HookAgentSaysTests {
    @Test func claudesBashDescriptionIsTheLine() {
        let stdin = #"""
            {"hook_event_name":"PreToolUse","tool_name":"Bash",\#
            "tool_input":{"command":"git push --force","description":"  Force-push my branch \n"}}
            """#
        #expect(HookAgentSays.line(host: .claude, stdin: stdin) == "Force-push my branch")
    }

    @Test func noLineFromOtherHostsToolsOrBrokenEnvelopes() {
        let bash = #"{"tool_name":"Bash","tool_input":{"command":"ls","description":"List"}}"#
        #expect(HookAgentSays.line(host: .codex, stdin: bash) == nil)
        #expect(HookAgentSays.line(
            host: .claude, stdin: #"{"tool_name":"Write","tool_input":{"description":"x"}}"#) == nil)
        #expect(HookAgentSays.line(host: .claude, stdin: #"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#) == nil)
        #expect(HookAgentSays.line(host: .claude, stdin: "not json") == nil)
        #expect(HookAgentSays.line(
            host: .claude, stdin: #"{"tool_name":"Bash","tool_input":{"description":"   "}}"#) == nil)
    }
}
