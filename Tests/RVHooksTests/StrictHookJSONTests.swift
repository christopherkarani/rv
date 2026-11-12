import Foundation
import RVDomain
import Testing
@testable import RVHooks

/// Duplicate keys: `JSONDecoder` keeps the first value, Node and Python the
/// last, so a payload with a repeated key means different things to rv and
/// to everything else. Every hook door refuses such a document.
struct StrictHookJSONTests {
    @Test func acceptsOrdinaryDocuments() {
        for text in [
            #"{}"#, #"[]"#, #"{"a":1}"#, #" {"a":[1,2,{"b":null}],"c":"x"} "#,
            #"{"a":{"a":{"a":1}}}"#, #"[{"a":1},{"a":2}]"#, #""s""#, "true", "-0.5e+3",
            #"{"a":"\"\\\/\b\f\n\r\té"}"#, "\u{FEFF}{\"a\":1}",
            #"{"x":"a","X":"b"}"#, #"{"command":1,"commands":2}"#,
        ] {
            #expect(StrictHookJSON.rejection(text) == nil, "\(text)")
        }
    }

    @Test func refusesDuplicateKeysAnywhere() {
        for text in [
            #"{"a":1,"a":2}"#,
            #"{"tool_input":{"command":"ls","command":"rm -rf /"}}"#,
            #"{"tool_name":"Foo","tool_name":"Bash"}"#,
            #"[1,{"x":[{"k":1,"k":1}]}]"#,
            // Escapes decode before comparison.
            #"{"command":"ls","command":"rm -rf /"}"#,
            #"{"a\/b":1,"a/b":2}"#,
            // Canonically equivalent spellings count as one key.
            "{\"caf\u{00E9}\":1,\"cafe\u{0301}\":2}",
            // Two lone surrogates both decode to U+FFFD: refused.
            #"{"\ud800":1,"\udbff":2}"#,
        ] {
            #expect(StrictHookJSON.rejection(text) == .duplicateKey, "\(text)")
        }
    }

    @Test func refusesMalformedAndDeepDocuments() {
        for text in [
            "", "{", #"{"a":1,}"#, #"{"a" 1}"#, #"{'a':1}"#, "[1,]", "01", "1.", "-",
            #"{"a":"\x"}"#, #"{"a":"\u12"}"#, "{\"a\":\"\u{01}\"}", "{} {}", "nul", "NaN",
            #"{"a":1}x"#,
        ] {
            #expect(StrictHookJSON.rejection(text) == .syntax, "\(text)")
        }
        let deep = String(repeating: "[", count: StrictHookJSON.maxDepth + 1)
            + String(repeating: "]", count: StrictHookJSON.maxDepth + 1)
        #expect(StrictHookJSON.rejection(deep) == .tooDeep)
        let ok = String(repeating: "[", count: StrictHookJSON.maxDepth)
            + String(repeating: "]", count: StrictHookJSON.maxDepth)
        #expect(StrictHookJSON.rejection(ok) == nil)
        // Far past the cap the scan is still iterative: no stack overflow.
        #expect(StrictHookJSON.rejection(String(repeating: "{\"a\":", count: 200_000)) == .tooDeep)
    }

    /// Every codec decodes a duplicate-key payload as malformed (deny), for
    /// the duplicated command, the duplicated tool name, and a duplicate in
    /// a key the codec ignores.
    @Test func everyCodecRefusesDuplicateKeys() {
        let cases: [(any HostCodec, [String])] = [
            (ClaudeHostCodec(), [
                #"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls","command":"rm -rf /"}}"#,
                #"{"hook_event_name":"PreToolUse","tool_name":"Foo","tool_name":"Bash","tool_input":{"command":"rm -rf /"}}"#,
                #"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"x":{"y":1,"y":2}}"#,
            ]),
            (GrokHostCodec(), [
                #"{"hookEventName":"pre_tool_use","toolName":"Bash","toolInput":{"command":"ls","command":"rm -rf /"}}"#,
            ]),
            (CodexHostCodec(), [
                #"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls","command":"rm -rf /"}}"#,
            ]),
            (MuseHostCodec(), [
                #"{"hook_event_name":"PreToolUse","tool_name":"bash","tool_input":{"command":"ls","command":"rm -rf /"}}"#,
            ]),
            (CursorHostCodec(), [
                #"{"hook_event_name":"beforeShellExecution","command":"ls","command":"rm -rf /"}"#,
            ]),
            (PiHostCodec(), [#"{"toolName":"bash","input":{"command":"ls","command":"rm -rf /"}}"#]),
            (OpenCodeHostCodec(), [#"{"tool":"bash","args":{"command":"ls","command":"rm -rf /"}}"#]),
            (OpenClawHostCodec(), [#"{"toolName":"exec","params":{"command":"ls","command":"rm -rf /"}}"#]),
            (HermesHostCodec(), [#"{"toolName":"terminal","args":{"command":"ls","command":"rm -rf /"}}"#]),
            (AntigravityHostCodec(), [
                #"{"toolCall":{"name":"run_command","args":{"CommandLine":"ls","CommandLine":"rm -rf /"}}}"#,
            ]),
        ]
        for (codec, payloads) in cases {
            for payload in payloads {
                #expect(codec.decode(payload) == .malformed(.unreadable), "\(codec.host) \(payload)")
                // Without the duplicate the same envelope still decodes.
                let single = payload.replacingOccurrences(of: #""command":"ls","#, with: "")
                    .replacingOccurrences(of: #""CommandLine":"ls","#, with: "")
                if single != payload {
                    if case .request = codec.decode(single) {} else {
                        Issue.record("\(codec.host) lost the plain decode: \(single)")
                    }
                }
            }
        }
    }

    /// End to end through the hook door: the reported Claude ALLOW for
    /// `{"command":"ls","command":"rm -rf /"}` is now a deny, and nothing is
    /// evaluated.
    @Test func claudeDuplicateCommandDeniesWithoutEvaluating() async {
        let payload = #"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls","command":"rm -rf /"}}"#
        let world = hookWorld(evaluate: { command, _ in
            Issue.record("evaluated \(command.rawValue)")
            return EvaluationResult(outcome: .plain)
        })
        let wire = await hookWire(host: .claude, stdin: payload, world: world)
        #expect(wire.stdout.contains("\"permissionDecision\":\"deny\""))
        #expect(wire.stdout.contains("could not read"))
    }

    /// A missing event no longer reads as foreign on the event-gated hosts:
    /// the Claude `rm -rf /` with no `hook_event_name` reaches evaluation.
    @Test func missingEventIsEvaluated() async {
        let payloads: [(HookHost, String)] = [
            (.claude, #"{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}"#),
            (.codex, #"{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}"#),
            (.muse, #"{"tool_name":"bash","tool_input":{"command":"rm -rf /"}}"#),
            (.grok, #"{"toolName":"Bash","toolInput":{"command":"rm -rf /"}}"#),
            (.cursor, #"{"command":"rm -rf /"}"#),
            (.claude, #"{"hook_event_name":"PreToolUse","tool_name":"bash","tool_input":{"command":"rm -rf /"}}"#),
            (.claude, #"{"hook_event_name":"PreToolUse","tool_name":"Bash ","tool_input":{"command":"rm -rf /"}}"#),
        ]
        for (host, payload) in payloads {
            let world = hookWorld(evaluate: { command, _ in
                #expect(command.rawValue == "rm -rf /")
                return EvaluationResult(outcome: .indeterminate(.corePacksUnavailable))
            })
            let wire = await hookWire(host: host, stdin: payload, world: world)
            #expect(wire != productionHostCodec(host).encodeAllow(), "\(host) \(payload)")
        }
    }

    @Test func wireNameKeyAndCanonical() {
        #expect(HookWireName.key(" Bash\t") == "bash")
        #expect(HookWireName.key("pre_tool_use") == HookWireName.key("PreToolUse"))
        #expect(HookWireName.key("Ba\u{200B}sh") == "bash")
        #expect(HookWireName.canonical("bash", among: ["Bash"]) == "Bash")
        #expect(HookWireName.canonical("BashOutput", among: ["Bash"]) == "BashOutput")
        #expect(HookWireName.canonical("KillShell", among: ["Bash"]) == "KillShell")
        #expect(HookWireName.canonical("   ", among: ["Bash"]) == "   ")
        #expect(HookWireName.canonical(nil, among: ["Bash"]) == nil)
        #expect(HookWireName.isPreToolEvent(nil, preToolEvent: "PreToolUse"))
        #expect(HookWireName.isPreToolEvent(" ", preToolEvent: "PreToolUse"))
        #expect(HookWireName.isPreToolEvent("pretooluse", preToolEvent: "PreToolUse"))
        #expect(HookWireName.isPreToolEvent("PostToolUse", preToolEvent: "PreToolUse") == false)
    }
}
