import Foundation
import Testing
import RVDomain
@testable import RVHooks

/// HostDecode-style net for file tools. Grep / MCP stay foreign at the product
/// door. Argv-shaped paths fail closed. Missing path is an empty file path
/// (evaluateFileTool denies), not a shell command.
///
/// Run: `tools/gate.sh --quiet RVHooksTests --filter FileToolDecodeStress`
@Suite("File-tool decode stress")
struct FileToolDecodeStressTests {
    @Test func canonicalRead_extractsPathOnFileHosts() {
        let path = "/tmp/rv-oracle/src/main.swift"
        let cases: [(String, any HostCodec)] = [
            (
                #"{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/tmp/rv-oracle/src/main.swift"}}"#,
                ClaudeHostCodec()
            ),
            (
                #"{"hookEventName":"pre_tool_use","toolName":"read_file","toolInput":{"path":"/tmp/rv-oracle/src/main.swift"}}"#,
                GrokHostCodec()
            ),
            (
                #"{"hookEventName":"pre_tool_use","toolName":"Read","toolInput":{"file_path":"/tmp/rv-oracle/src/main.swift"}}"#,
                GrokHostCodec()
            ),
            (
                #"{"hook_event_name":"preToolUse","tool_name":"Read","tool_input":{"file_path":"/tmp/rv-oracle/src/main.swift"}}"#,
                CursorHostCodec()
            ),
        ]
        for (stdin, codec) in cases {
            guard case .request(let request) = codec.decode(stdin),
                  case .file(_, let file, _, _) = request
            else {
                Issue.record("\(codec.host) failed to extract canonical Read")
                continue
            }
            #expect(file.kind == .read, "\(codec.host)")
            #expect(file.path.rawValue == path, "\(codec.host)")
        }
    }

    @Test func extraKeys_doNotBreakFileDecode() {
        let stdin = """
        {"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/tmp/a.md","offset":1},"cwd":"/tmp/ws","extra":{"nested":1}}
        """
        guard case .request(let request) = ClaudeHostCodec().decode(stdin),
              case .file(_, let file, let cwd, _) = request
        else {
            Issue.record("extra keys should still decode a file tool")
            return
        }
        #expect(file.path.rawValue == "/tmp/a.md")
        #expect(cwd?.rawValue == "/tmp/ws")
    }

    @Test func pathAsArray_isUnreadable() {
        let claude =
            #"{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":["/tmp/.env"]}}"#
        #expect(ClaudeHostCodec().decode(claude) == .malformed(.unreadable))
        let grok =
            #"{"hookEventName":"pre_tool_use","toolName":"read_file","toolInput":{"path":["/tmp/.env"]}}"#
        #expect(GrokHostCodec().decode(grok) == .malformed(.unreadable))
        let grokFilePath =
            #"{"hookEventName":"pre_tool_use","toolName":"Read","toolInput":{"file_path":["/tmp/.env"]}}"#
        #expect(GrokHostCodec().decode(grokFilePath) == .malformed(.unreadable))
        let cursor =
            #"{"hook_event_name":"preToolUse","tool_name":"Read","tool_input":{"file_path":["/tmp/.env"]}}"#
        #expect(CursorHostCodec().decode(cursor) == .malformed(.unreadable))
    }

    @Test func missingPath_isEmptyFileNotShell() {
        let stdin =
            #"{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{}}"#
        guard case .request(let request) = ClaudeHostCodec().decode(stdin),
              case .file(_, let file, _, _) = request
        else {
            Issue.record("missing path must still be a file request")
            return
        }
        #expect(file.path.isEmpty)
        #expect(file.kind == .read)
    }

    @Test func grepAndMCP_areForeignOnEveryHost() {
        let codecs: [any HostCodec] = [
            GrokHostCodec(), PiHostCodec(), OpenCodeHostCodec(), ClaudeHostCodec(),
            CursorHostCodec(), CodexHostCodec(), HermesHostCodec(), OpenClawHostCodec(),
            AntigravityHostCodec(),
        ]
        for codec in codecs {
            #expect(
                codec.decode(grepEnvelope(for: codec.host)) == .foreign,
                "Grep must stay foreign on \(codec.host)"
            )
            #expect(
                codec.decode(mcpEnvelope(for: codec.host)) == .foreign,
                "MCP must stay foreign on \(codec.host)"
            )
        }
    }

    @Test func fileToolKind_neverMapsGrepOrMCP() {
        #expect(FileToolKind(toolName: "Grep") == nil)
        #expect(FileToolKind(toolName: "Glob") == nil)
        #expect(FileToolKind(toolName: "MCP") == nil)
        #expect(FileToolAction.make(toolName: "Grep", filePath: "/tmp/.env") == nil)
        #expect(FileToolAction.make(toolName: "MCP", path: "/tmp/.env") == nil)
    }
}

private func grepEnvelope(for host: HookHost) -> String {
    switch host {
    case .claude, .codex:
        return #"{"hook_event_name":"PreToolUse","tool_name":"Grep","tool_input":{"pattern":"secret"}}"#
    case .grok:
        return #"{"hookEventName":"pre_tool_use","toolName":"Grep","toolInput":{"pattern":"secret"}}"#
    case .cursor:
        return #"{"hook_event_name":"preToolUse","tool_name":"Grep","tool_input":{"pattern":"secret"}}"#
    case .pi:
        return #"{"toolName":"Grep","input":{"pattern":"secret"}}"#
    case .opencode:
        return #"{"tool":"Grep","args":{"pattern":"secret"}}"#
    case .hermes:
        return #"{"toolName":"Grep","args":{"pattern":"secret"}}"#
    case .openclaw:
        return #"{"toolName":"Grep","params":{"pattern":"secret"}}"#
    case .antigravity:
        return #"{"conversationId":"sess","toolCall":{"name":"Grep","args":{}},"workspacePaths":[]}"#
    }
}

private func mcpEnvelope(for host: HookHost) -> String {
    switch host {
    case .claude, .codex:
        return #"{"hook_event_name":"PreToolUse","tool_name":"MCP","tool_input":{"name":"x"}}"#
    case .grok:
        return #"{"hookEventName":"pre_tool_use","toolName":"MCP","toolInput":{"name":"x"}}"#
    case .cursor:
        return #"{"hook_event_name":"preToolUse","tool_name":"MCP","tool_input":{"name":"x"}}"#
    case .pi:
        return #"{"toolName":"MCP","input":{"name":"x"}}"#
    case .opencode:
        return #"{"tool":"MCP","args":{"name":"x"}}"#
    case .hermes:
        return #"{"toolName":"MCP","args":{"name":"x"}}"#
    case .openclaw:
        return #"{"toolName":"MCP","params":{"name":"x"}}"#
    case .antigravity:
        return #"{"conversationId":"sess","toolCall":{"name":"MCP","args":{}},"workspacePaths":[]}"#
    }
}
