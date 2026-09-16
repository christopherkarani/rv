import Foundation
import Testing
import RVDomain
@testable import RVHooks

/// Host stdin shapes agents actually emit. Canonical rows must extract the
/// command. Alias / type-mismatch rows document where decode breaks
/// (fail-closed malformed or fail-open foreign).
@Suite("Host decode stress")
struct HostDecodeStressTests {
    @Test func canonicalEnvelopes_extractGitStatus() {
        let command = "git status"
        let cases: [(String, any HostCodec)] = [
            (
                #"{"hookEventName":"pre_tool_use","toolName":"run_terminal_command","toolInput":{"command":"git status"}}"#,
                GrokHostCodec()
            ),
            (
                #"{"toolName":"bash","input":{"command":"git status"}}"#,
                PiHostCodec()
            ),
            (
                #"{"tool":"bash","args":{"command":"git status"}}"#,
                OpenCodeHostCodec()
            ),
            (
                #"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"}}"#,
                ClaudeHostCodec()
            ),
            (
                #"{"hook_event_name":"beforeShellExecution","command":"git status"}"#,
                CursorHostCodec()
            ),
            (
                #"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"}}"#,
                CodexHostCodec()
            ),
            (
                #"{"toolName":"terminal","args":{"command":"git status"}}"#,
                HermesHostCodec()
            ),
            (
                #"{"toolName":"exec","params":{"command":"git status"}}"#,
                OpenClawHostCodec()
            ),
        ]
        for (stdin, codec) in cases {
            guard case .request(let request) = codec.decode(stdin),
                  case .shell(_, let shell, _, _) = request
            else {
                Issue.record("\(codec.host) failed to extract canonical git status")
                continue
            }
            #expect(shell.rawValue == command, "\(codec.host)")
        }
    }

    @Test func multilineAndUnicodeCommands_extract() {
        let multiline = "git status\necho done"
        let unicode = "echo café && git status"
        let cursor = CursorHostCodec()
        let wrapped = wrapCursor(multiline)
        guard case .request(let request) = cursor.decode(wrapped),
              case .shell(_, let command, _, _) = request
        else {
            Issue.record("cursor multiline failed")
            return
        }
        #expect(command.rawValue == multiline)

        guard case .request(let unicodeRequest) = cursor.decode(wrapCursor(unicode)),
              case .shell(_, let unicodeCommand, _, _) = unicodeRequest
        else {
            Issue.record("cursor unicode failed")
            return
        }
        #expect(unicodeCommand.rawValue == unicode)
    }

    @Test func extraKeys_doNotBreakCanonicalDecode() {
        let stdin = """
        {"hook_event_name":"beforeShellExecution","command":"git status","cwd":"/tmp/ws","sandbox":true,"extra":{"nested":1}}
        """
        guard case .request(let request) = CursorHostCodec().decode(stdin),
              case .shell(_, let command, let cwd, _) = request
        else {
            Issue.record("extra keys should still decode")
            return
        }
        #expect(command.rawValue == "git status")
        #expect(cwd?.rawValue == "/tmp/ws")
    }

    /// Agents sometimes send argv arrays. JSONDecoder rejects String? and
    /// the whole envelope becomes unreadable — fail-closed deny of quiet work.
    @Test func commandAsArray_isUnreadable() {
        let stdin = #"{"hook_event_name":"beforeShellExecution","command":["git","status"]}"#
        #expect(CursorHostCodec().decode(stdin) == .malformed(.unreadable))
        let claude = #"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":["git","status"]}}"#
        #expect(ClaudeHostCodec().decode(claude) == .malformed(.unreadable))
    }

    /// `cmd` is not a contract field. Missing `command` fail-closes.
    @Test func cmdAlias_isMissingCommand() {
        #expect(
            CursorHostCodec().decode(#"{"hook_event_name":"beforeShellExecution","cmd":"git status"}"#)
                == .malformed(.missingCommand)
        )
        #expect(
            ClaudeHostCodec().decode(
                #"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"cmd":"git status"}}"#
            ) == .malformed(.missingCommand)
        )
    }

    /// Grok / Pi contracts are camelCase. Snake_case looks like another host
    /// and fails *open* (foreign allow).
    @Test func grokAndPiSnakeCase_areForeign() {
        #expect(
            GrokHostCodec().decode(
                #"{"hook_event_name":"pre_tool_use","tool_name":"run_terminal_command","tool_input":{"command":"git reset --hard"}}"#
            ) == .foreign
        )
        #expect(
            PiHostCodec().decode(
                #"{"tool_name":"bash","input":{"command":"git reset --hard"}}"#
            ) == .foreign
        )
    }

    /// Decode treats any non-empty string as a command. Trim-to-empty is an
    /// evaluate allow, not a missing-command malformation.
    @Test func whitespaceOnlyCommand_isExtracted() {
        guard case .request(let request) = CursorHostCodec().decode(
            #"{"hook_event_name":"beforeShellExecution","command":"   "}"#
        ),
              case .shell(_, let command, _, _) = request
        else {
            Issue.record("whitespace command should extract")
            return
        }
        #expect(command.rawValue == "   ")
        #expect(
            CursorHostCodec().decode(#"{"hook_event_name":"beforeShellExecution","command":""}"#)
                == .malformed(.missingCommand)
        )
    }

    @Test func notJSON_isUnreadable() {
        let codecs: [any HostCodec] = [
            GrokHostCodec(), PiHostCodec(), OpenCodeHostCodec(), ClaudeHostCodec(),
            CursorHostCodec(), CodexHostCodec(), HermesHostCodec(), OpenClawHostCodec(),
        ]
        for codec in codecs {
            #expect(codec.decode("not-json") == .malformed(.unreadable), "\(codec.host)")
            #expect(codec.decode("") == .malformed(.unreadable), "\(codec.host) empty")
        }
    }

    /// UTF-8 BOM is accepted by JSONDecoder. Not a decode break.
    @Test func bomPrefix_stillExtractsCommand() {
        let body = #"{"hook_event_name":"beforeShellExecution","command":"git status"}"#
        let bom = "\u{FEFF}" + body
        guard case .request(let request) = CursorHostCodec().decode(bom),
              case .shell(_, let command, _, _) = request
        else {
            Issue.record("BOM prefix should still decode")
            return
        }
        #expect(command.rawValue == "git status")
    }
}

private func wrapCursor(_ command: String) -> String {
    guard
        let data = try? JSONSerialization.data(
            withJSONObject: [
                "hook_event_name": "beforeShellExecution",
                "command": command,
            ]
        ),
        let text = String(data: data, encoding: .utf8)
    else {
        return ""
    }
    return text
}
