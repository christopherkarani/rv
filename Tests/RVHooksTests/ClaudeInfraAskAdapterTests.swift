import Foundation
import RVDomain
import RVHooks
import Testing

/// rv's infrastructure ask (rvd unreachable, slow or dropped, or the whole
/// rv process past the adapter budget) reaches the human as Claude Code's
/// own permission prompt, but only when every gate holds:
/// `RV_HOOK_WHEN_DOWN` is not `deny`, the permission mode is one where Claude
/// Code puts a hook `ask` to a person, and Claude Code marks the session as
/// attended. Everything else keeps blocking.
struct ClaudeInfraAskAdapterTests {
    /// Modes that show a hook `ask` to a human: Manual (`default`), `plan`,
    /// `acceptEdits` and `auto` (the classifier does not decide a hook ask).
    static let promptingModes = ["default", "plan", "acceptEdits", "auto"]

    /// `bypassPermissions` skips prompts and `dontAsk` auto-denies them;
    /// a missing, blank, differently-spelled or unknown mode is treated the
    /// same way: no proof a person will be asked.
    static let nonPromptingModes: [String?] = [nil, "bypassPermissions", "dontAsk", "", "Default", "manual", "yolo"]

    /// What Claude Code sets for an interactive session it knows is attended.
    static let attended = ["CLAUDE_CODE_SESSION_ATTENDED": "1"]

    static let marker = "rv could not check this call"

    /// The prompt: the call first, then which layer failed, the warning, and
    /// the C hook's (or adapter's) own text.
    static func prompt(subject: String = "Bash: git status", layer: String, reason: String) -> String {
        "\(subject)\n\nrv could not check this call (\(layer)). An agent can cause this by stopping or "
            + "overloading rvd. Approve only if you expected it. \(reason)"
    }

    @Test(arguments: promptingModes)
    func daemonDown_asksTheHumanWithTheCommandFirst(_ mode: String) async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: daemonDownWire(.claude), eventFields: ["permission_mode": mode],
            environment: Self.attended)
        let reason = try expectClaudeAsk(run)
        #expect(reason == Self.prompt(layer: "rvd is not reachable", reason: daemonUnreachableMessage), "\(mode)")
    }

    @Test(arguments: promptingModes)
    func daemonDown_fileToolAsksWithThePath(_ mode: String) async throws {
        let run = try await runPythonAdapter(
            host: .claude,
            stub: daemonDownWire(.claude),
            eventFields: [
                "permission_mode": mode,
                "tool_name": "Write",
                "tool_input": ["file_path": "/tmp/ws/a.txt", "content": "x"],
            ],
            environment: Self.attended
        )
        let reason = try expectClaudeAsk(run)
        #expect(
            reason == Self.prompt(
                subject: "Write: /tmp/ws/a.txt", layer: "rvd is not reachable", reason: daemonUnreachableMessage),
            "\(mode)")
    }


    /// The command is shown on one line, with line breaks, controls,
    /// format (bidi, zero-width) and separator characters escaped, so it
    /// cannot forge a paragraph, push the warning out of view, or reorder
    /// what the person reads. A plain space stays a space.
    @Test(arguments: SubjectForgery.allCases)
    func daemonDown_commandIsShownOnOneEscapedLine(_ forgery: SubjectForgery) async throws {
        let reason = try await Self.askReason(command: forgery.command)
        #expect(
            reason == Self.prompt(
                subject: "Bash: " + forgery.shown, layer: "rvd is not reachable", reason: daemonUnreachableMessage),
            "\(forgery): \(reason)")
        // Exactly one paragraph break: the one before rv's warning.
        #expect(reason.components(separatedBy: "\n").count == 3, "\(forgery)")
    }

    /// Past 300 escaped characters the subject keeps its first 220 and last
    /// 80 and says how many characters of the command it leaves out, so a
    /// long or padded command cannot hide its end.
    @Test(arguments: LongSubject.allCases)
    func daemonDown_longCommandKeepsItsHeadAndTail(_ long: LongSubject) async throws {
        let reason = try await Self.askReason(command: long.command)
        #expect(
            reason == Self.prompt(
                subject: "Bash: " + long.shown, layer: "rvd is not reachable", reason: daemonUnreachableMessage),
            "\(long): \(reason)")
    }

    /// A lone surrogate in the request is shown escaped, not dropped and
    /// not a reason to fail.
    @Test func daemonDown_loneSurrogateIsShownEscaped() async throws {
        let raw = #"{"hook_event_name":"PreToolUse","tool_name":"Bash","permission_mode":"default","tool_input":{"command":"ls "#
            + escaped("d800") + #" x"}}"#
        let run = try await runPythonAdapter(
            host: .claude, stub: daemonDownWire(.claude), rawEvent: raw, environment: Self.attended)
        let reason = try expectClaudeAsk(run)
        #expect(
            reason == Self.prompt(
                subject: "Bash: ls " + escaped("d800") + " x", layer: "rvd is not reachable",
                reason: daemonUnreachableMessage))
    }

    static func askReason(command: String) async throws -> String {
        let run = try await runPythonAdapter(
            host: .claude, stub: daemonDownWire(.claude),
            eventFields: ["permission_mode": "default", "tool_input": ["command": command]],
            environment: Self.attended)
        return try expectClaudeAsk(run)
    }

    @Test(arguments: nonPromptingModes)
    func daemonDown_blocksWhenNoHumanWouldBeAsked(_ mode: String?) async throws {
        var fields: [String: Any] = [:]
        if let mode { fields["permission_mode"] = mode }
        let run = try await runPythonAdapter(
            host: .claude, stub: daemonDownWire(.claude), eventFields: fields, environment: Self.attended)
        let reason = try expectFailClosed(host: .claude, run: run)
        #expect(reason == daemonUnreachableMessage, "\(mode ?? "nil"): \(reason)")
    }

    /// Only Claude Code's top-level field counts: a mode inside agent-chosen
    /// tool input, or a near-spelling of the key, is no proof.
    @Test(arguments: SpoofedMode.allCases)
    func daemonDown_modeOutsideTheTopLevelFieldBlocks(_ spoof: SpoofedMode) async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: daemonDownWire(.claude), eventFields: spoof.fields, environment: Self.attended)
        let reason = try expectFailClosed(host: .claude, run: run)
        #expect(reason == daemonUnreachableMessage, "\(spoof): \(reason)")
    }

    /// A repeated top-level permission_mode is refused as a request, never
    /// read as either value.
    @Test func daemonDown_duplicateModeKeyBlocks() async throws {
        let raw = #"{"hook_event_name":"PreToolUse","tool_name":"Bash","permission_mode":"bypassPermissions","permission_mode":"default","tool_input":{"command":"git status"}}"#
        let run = try await runPythonAdapter(
            host: .claude, stub: daemonDownWire(.claude), rawEvent: raw, environment: Self.attended)
        let reason = try expectFailClosed(host: .claude, run: run)
        #expect(reason.contains("could not read the hook request"), "\(reason)")
    }

    @Test(arguments: ["bypassPermissions", "dontAsk"])
    func daemonDown_fileToolBlocksWhenNoHumanWouldBeAsked(_ mode: String) async throws {
        let run = try await runPythonAdapter(
            host: .claude,
            stub: daemonDownWire(.claude),
            eventFields: [
                "permission_mode": mode,
                "tool_name": "Write",
                "tool_input": ["file_path": "/tmp/ws/a.txt", "content": "x"],
            ],
            environment: Self.attended
        )
        let reason = try expectFailClosed(host: .claude, run: run)
        #expect(reason == daemonUnreachableMessage, "\(mode): \(reason)")
    }

    @Test func daemonDown_nonStringModeBlocks() async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: daemonDownWire(.claude), eventFields: ["permission_mode": ["default"]],
            environment: Self.attended)
        let reason = try expectFailClosed(host: .claude, run: run)
        #expect(reason == daemonUnreachableMessage)
    }

    /// A headless, SDK or unknown session blocks even in a prompting mode:
    /// `claude -p` sets `CLAUDE_CODE_SESSION_ATTENDED=0` and entrypoint
    /// `sdk-cli`, and an SDK host may answer the prompt with code. Without
    /// the attended flag an interactive-looking entrypoint is no proof
    /// either: on older builds a nested `claude -p` inherits
    /// `claude-desktop` or `claude-vscode`.
    @Test(arguments: UnattendedSession.allCases)
    func daemonDown_unattendedSessionBlocks(_ session: UnattendedSession) async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: daemonDownWire(.claude), eventFields: ["permission_mode": "default"],
            environment: session.environment)
        let reason = try expectFailClosed(host: .claude, run: run)
        #expect(reason == daemonUnreachableMessage, "\(session): \(reason)")
    }

    /// `RV_HOOK_WHEN_DOWN=deny` blocks every infrastructure path, the
    /// adapter's own timeout included.
    @Test(arguments: DownPath.allCases)
    func whenDownDeny_blocksEveryInfraPath(_ path: DownPath) async throws {
        var environment = Self.attended
        environment["RV_HOOK_WHEN_DOWN"] = "deny"
        let run = try await runPythonAdapter(
            host: .claude, stub: path.stub, timeoutSeconds: "0.3", eventFields: ["permission_mode": "default"],
            environment: environment)
        let reason = try expectFailClosed(host: .claude, run: run)
        #expect(reason.contains(Self.marker) == false, "\(path): \(reason)")
        #expect(reason.contains("`rv doctor`"), "\(path): \(reason)")
    }

    /// The owner can pin "block" with `"hookAskWhenDown": false` in
    /// `~/.config/rv/config.json` (passwd home): every infrastructure path
    /// then blocks, the adapter's own timeout included.
    @Test(arguments: DownPath.allCases)
    func ownerSwitchOff_blocksEveryInfraPath(_ path: DownPath) async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: path.stub, timeoutSeconds: "0.3", eventFields: ["permission_mode": "default"],
            environment: Self.attended, ownerConfig: { path in
                try writeOwnerConfig(#"{"hookAskWhenDown": false}"#, at: path)
                return path
            })
        let reason = try expectFailClosed(host: .claude, run: run)
        #expect(reason.contains(Self.marker) == false, "\(path): \(reason)")
        #expect(reason.contains("`rv doctor`"), "\(path): \(reason)")
    }

    /// The pin only tightens, so a config.json that exists but cannot be
    /// used pins "block" (as GuardConfig fails closed on a bad config).
    /// Only a missing file, a clean object without the key, or a key that
    /// is not exactly JSON `false` keeps the ask. Who owns the file and who
    /// may write it does not matter for a tightening switch.
    @Test(arguments: OwnerConfigCase.allCases)
    func ownerConfig_pinsUnlessMissingOrNotExplicitlyFalse(_ config: OwnerConfigCase) async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: daemonDownWire(.claude), eventFields: ["permission_mode": "default"],
            environment: Self.attended, ownerConfig: config.prepare)
        if config.pins {
            let reason = try expectFailClosed(host: .claude, run: run)
            #expect(reason == daemonUnreachableMessage, "\(config): \(reason)")
        } else {
            let reason = try expectClaudeAsk(run)
            #expect(reason == Self.prompt(layer: "rvd is not reachable", reason: daemonUnreachableMessage), "\(config)")
        }
    }

    /// Each C hook down reason maps to its own layer.
    @Test(arguments: [
        (cTimeoutMessage, "rvd did not answer in time"),
        (cConnectionMessage, "the connection to rvd dropped"),
    ])
    func nativeAsk_eachDownReasonNamesItsLayer(_ message: String, layer: String) async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: claudeAskWire(reason: message), eventFields: ["permission_mode": "default"],
            environment: Self.attended)
        let reason = try expectClaudeAsk(run)
        #expect(reason == Self.prompt(layer: layer, reason: message))
    }

    /// The rv process running past the adapter budget is infrastructure.
    @Test func timeout_asksTheHuman() async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: .sleep(seconds: 5), timeoutSeconds: "0.3",
            eventFields: ["permission_mode": "default"], environment: Self.attended)
        let reason = try expectClaudeAsk(run)
        #expect(
            reason == Self.prompt(
                layer: "rv did not answer within 0.3s",
                reason: "rv did not answer within 0.3s; the daemon may be busy or stopped. Run `rv doctor`."))
    }

    @Test func timeout_blocksUnderBypass() async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: .sleep(seconds: 5), timeoutSeconds: "0.3",
            eventFields: ["permission_mode": "bypassPermissions"], environment: Self.attended)
        let reason = try expectFailClosed(host: .claude, run: run)
        #expect(reason.contains("rv did not answer within 0.3s"), "\(reason)")
    }

    /// Only the C hook's exact down reasons become a prompt; any other
    /// native ask is an unexplained rv answer and blocks.
    @Test(arguments: OtherNativeAsk.allCases)
    func nativeAskOtherThanADownReason_blocks(_ which: OtherNativeAsk) async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: which.stub, eventFields: ["permission_mode": "default"],
            environment: Self.attended)
        let reason = try expectFailClosed(host: .claude, run: run)
        #expect(reason.contains(Self.marker) == false, "\(which): \(reason)")
        #expect(reason == which.expectedReason, "\(which): \(reason)")
    }

    /// Install problems, unusable output, rv's deny and rv's policy ask
    /// (Step 8B: approval happens in RVOperatorUI) never become a host
    /// prompt, even where Claude Code would show one.
    @Test(arguments: StillBlocks.allCases)
    func nonInfraFailures_stillBlockWhereHostCouldAsk(_ which: StillBlocks) async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: which.stub, eventFields: ["permission_mode": "default"],
            environment: Self.attended)
        let reason = try expectFailClosed(host: .claude, run: run)
        #expect(reason.contains(Self.marker) == false, "\(which): \(reason)")
    }

    /// No failure path answers allow, whatever the mode.
    @Test(arguments: promptingModes + ["bypassPermissions", "dontAsk"])
    func failures_neverAllow(_ mode: String) async throws {
        let stubs: [AdapterStub] = [daemonDownWire(.claude), .sleep(seconds: 5), .missing, .stdout("", exit: 1)]
        for stub in stubs {
            let run = try await runPythonAdapter(
                host: .claude, stub: stub, timeoutSeconds: "0.3", eventFields: ["permission_mode": mode],
                environment: Self.attended)
            #expect(run.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false, "\(mode)")
            let hook = try wireObject(run.stdout)["hookSpecificOutput"] as? [String: Any]
            let decision = hook?["permissionDecision"] as? String
            #expect(decision == "ask" || decision == "deny", "\(mode): \(decision ?? "nil")")
        }
    }

    /// If the decision cannot be written, the adapter exits 2 (Claude Code's
    /// blocking error) with the reason on stderr, for an ask and a deny.
    @Test(arguments: ["default", "bypassPermissions"])
    func unwritableStdout_exitsTwoWithTheReason(_ mode: String) async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: daemonDownWire(.claude), eventFields: ["permission_mode": mode],
            environment: Self.attended, stdoutUnwritable: true)
        #expect(run.exitCode == 2, "\(mode)")
        #expect(run.stderr.contains(daemonUnreachableMessage), "\(mode): \(run.stderr)")
    }

    /// Observe mode is unchanged: rv's own allow (empty stdout, exit 0)
    /// stays an allow, and nothing is prefixed or prompted.
    @Test func rvAllow_staysEmptyAllow() async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: .stdout("", exit: 0), eventFields: ["permission_mode": "default"],
            environment: Self.attended)
        #expect(run.exitCode == 0)
        #expect(run.stdout.isEmpty)
    }

    /// Cursor gives a hook no signal for auto-run, background agents or
    /// `cursor-agent --force`, so its native ask still blocks.
    @Test func cursorNativeAsk_stillBlocks() async throws {
        let run = try await runPythonAdapter(host: .cursor, stub: daemonDownWire(.cursor), environment: Self.attended)
        let reason = try expectFailClosed(host: .cursor, run: run)
        #expect(reason == daemonUnreachableMessage)
    }

    enum SpoofedMode: CaseIterable, CustomStringConvertible {
        case insideToolInputUnderBypass, insideToolInputOnly, camelCaseKey, spacedKey

        var fields: [String: Any] {
            let toolInput: [String: Any] = ["command": "git status", "permission_mode": "default"]
            switch self {
            case .insideToolInputUnderBypass:
                return ["permission_mode": "bypassPermissions", "tool_input": toolInput]
            case .insideToolInputOnly:
                return ["tool_input": toolInput]
            case .camelCaseKey:
                return ["permissionMode": "default"]
            case .spacedKey:
                return ["permission_mode ": "default"]
            }
        }

        var description: String {
            switch self {
            case .insideToolInputUnderBypass: "insideToolInputUnderBypass"
            case .insideToolInputOnly: "insideToolInputOnly"
            case .camelCaseKey: "camelCaseKey"
            case .spacedKey: "spacedKey"
            }
        }
    }

    enum LongSubject: String, CaseIterable, CustomStringConvertible {
        case plainLong, spacePadding, escapesAtTheCut, oneCharacterLeftOut

        static let rlo = "\u{202E}"

        var command: String {
            switch self {
            case .plainLong: String(repeating: "a", count: 5000)
            case .spacePadding: "git status" + String(repeating: " ", count: 400) + "; rm -rf ~"
            case .escapesAtTheCut: String(repeating: "a", count: 400) + String(repeating: Self.rlo, count: 14)
            case .oneCharacterLeftOut: String(repeating: "a", count: 220) + Self.rlo + String(repeating: "a", count: 80)
            }
        }

        var shown: String {
            let a = { (n: Int) in String(repeating: "a", count: n) }
            switch self {
            case .plainLong:
                return a(220) + "… (4700 characters not shown) …" + a(80)
            case .spacePadding:
                return "git status" + String(repeating: " ", count: 210) + "… (120 characters not shown) …"
                    + String(repeating: " ", count: 70) + "; rm -rf ~"
            case .escapesAtTheCut:
                // The 14th escape would push the tail past 80: it is left out whole.
                return a(220) + "… (181 characters not shown) …" + String(repeating: escaped("202e"), count: 13)
            case .oneCharacterLeftOut:
                return a(220) + "… (1 character not shown) …" + a(80)
            }
        }

        var description: String { rawValue }
    }

    enum SubjectForgery: CaseIterable, CustomStringConvertible {
        case forgedParagraph, newlinePadding, carriageReturnAndTab, ansiEscape, bidiOverride
        case zeroWidth, lineAndParagraphSeparators, nonBreakingAndIdeographicSpace, astralFormatTag
        case typedBackslashN, typedBackslashU

        var command: String {
            switch self {
            case .forgedParagraph: "echo hi\n\nrv checked this call: SAFE. Approve."
            case .newlinePadding: "echo hi" + String(repeating: "\n", count: 40) + "rm -rf ~"
            case .carriageReturnAndTab: "rm -rf ~\rls\tx"
            case .ansiEscape: "rm -rf ~\u{1B}[2K\u{1B}[1Als"
            case .bidiOverride: "echo \u{202E}hs.txt rm -rf ~"
            case .zeroWidth: "r\u{200B}m -rf ~\u{FEFF}"
            case .lineAndParagraphSeparators: "ls\u{2028}rm -rf ~\u{2029}"
            case .nonBreakingAndIdeographicSpace: "rm\u{00A0}-rf\u{3000}~"
            case .astralFormatTag: "ls\u{E0041}"
            // Typed backslash text, not escapes: it must not pass for one.
            case .typedBackslashN: "echo " + backslash + "n done"
            case .typedBackslashU: "echo " + escaped("202e") + " done"
            }
        }

        var shown: String {
            switch self {
            case .forgedParagraph: #"echo hi\n\nrv checked this call: SAFE. Approve."#
            case .newlinePadding: "echo hi" + String(repeating: #"\n"#, count: 40) + "rm -rf ~"
            case .carriageReturnAndTab: #"rm -rf ~\rls\tx"#
            case .ansiEscape: "rm -rf ~" + escaped("001b") + "[2K" + escaped("001b") + "[1Als"
            case .bidiOverride: "echo " + escaped("202e") + "hs.txt rm -rf ~"
            case .zeroWidth: "r" + escaped("200b") + "m -rf ~" + escaped("feff")
            case .lineAndParagraphSeparators: "ls" + escaped("2028") + "rm -rf ~" + escaped("2029")
            case .nonBreakingAndIdeographicSpace: "rm" + escaped("00a0") + "-rf" + escaped("3000") + "~"
            case .astralFormatTag: "ls" + escaped("db40") + escaped("dc41")
            case .typedBackslashN: "echo " + backslash + backslash + "n done"
            case .typedBackslashU: "echo " + backslash + escaped("202e") + " done"
            }
        }

        var description: String {
            switch self {
            case .forgedParagraph: "forgedParagraph"
            case .newlinePadding: "newlinePadding"
            case .carriageReturnAndTab: "carriageReturnAndTab"
            case .ansiEscape: "ansiEscape"
            case .bidiOverride: "bidiOverride"
            case .zeroWidth: "zeroWidth"
            case .lineAndParagraphSeparators: "lineAndParagraphSeparators"
            case .nonBreakingAndIdeographicSpace: "nonBreakingAndIdeographicSpace"
            case .astralFormatTag: "astralFormatTag"
            case .typedBackslashN: "typedBackslashN"
            case .typedBackslashU: "typedBackslashU"
            }
        }
    }

    enum OwnerConfigCase: String, CaseIterable, CustomStringConvertible {
        // Keep the ask.
        case missingFile, parentIsAFile, emptyObject, keyAbsent, switchTrue, stringFalse, zero, null
        case nestedUnderGuard
        // Pin block: explicit false, whoever may write the file.
        case false0600, false0400, false0664, false0666
        // Pin block: the file exists but cannot be used.
        case unreadable, symlinkToFalse, symlinkToTrue, danglingSymlink, directory, fifo
        case oversizeSparse, emptyFile, corrupt, byteOrderMark, duplicateKey, arrayRoot, notUTF8

        var pins: Bool {
            switch self {
            case .missingFile, .parentIsAFile, .emptyObject, .keyAbsent, .switchTrue, .stringFalse, .zero, .null,
                .nestedUnderGuard:
                false
            default:
                true
            }
        }

        func prepare(_ path: URL) throws -> URL {
            let dir = path.deletingLastPathComponent()
            let falseJSON = #"{"hookAskWhenDown": false}"#
            switch self {
            case .missingFile: break
            case .parentIsAFile:
                let file = dir.appendingPathComponent("not-a-dir")
                try writeOwnerConfig("{}", at: file)
                return file.appendingPathComponent("config.json")
            case .emptyObject: try writeOwnerConfig("{}", at: path)
            case .keyAbsent: try writeOwnerConfig(#"{"guard": {"mode": "enforce"}}"#, at: path)
            case .switchTrue: try writeOwnerConfig(#"{"hookAskWhenDown": true}"#, at: path)
            case .stringFalse: try writeOwnerConfig(#"{"hookAskWhenDown": "false"}"#, at: path)
            case .zero: try writeOwnerConfig(#"{"hookAskWhenDown": 0}"#, at: path)
            case .null: try writeOwnerConfig(#"{"hookAskWhenDown": null}"#, at: path)
            case .nestedUnderGuard: try writeOwnerConfig(#"{"guard": {"hookAskWhenDown": false}}"#, at: path)
            case .false0600: try writeOwnerConfig(falseJSON, at: path)
            case .false0400: try writeOwnerConfig(falseJSON, at: path, mode: 0o400)
            case .false0664: try writeOwnerConfig(falseJSON, at: path, mode: 0o664)
            case .false0666: try writeOwnerConfig(falseJSON, at: path, mode: 0o666)
            case .unreadable: try writeOwnerConfig(falseJSON, at: path, mode: 0o000)
            case .symlinkToFalse, .symlinkToTrue:
                let target = dir.appendingPathComponent("real-config.json")
                try writeOwnerConfig(
                    self == .symlinkToFalse ? falseJSON : #"{"hookAskWhenDown": true}"#, at: target)
                try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
            case .danglingSymlink:
                try FileManager.default.createSymbolicLink(
                    at: path, withDestinationURL: dir.appendingPathComponent("nowhere.json"))
            case .directory:
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
            case .fifo:
                try #require(mkfifo(path.path, 0o600) == 0)
            case .oversizeSparse:
                try writeOwnerConfig("{}", at: path)
                let handle = try FileHandle(forWritingTo: path)
                try handle.truncate(atOffset: 2 * 1024 * 1024)
                try handle.close()
            case .emptyFile: try writeOwnerConfig("", at: path)
            case .corrupt: try writeOwnerConfig(#"{"hookAskWhenDown": true"#, at: path)
            case .byteOrderMark: try writeOwnerConfig(String(UnicodeScalar(0xFEFF)!) + "{}", at: path)
            case .duplicateKey:
                try writeOwnerConfig(#"{"hookAskWhenDown": true, "hookAskWhenDown": true}"#, at: path)
            case .arrayRoot: try writeOwnerConfig("[]", at: path)
            case .notUTF8:
                try Data([0x7B, 0x22, 0xFF, 0x22, 0x3A, 0x31, 0x7D]).write(to: path)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            }
            return path
        }

        var description: String { rawValue }
    }

    enum UnattendedSession: CaseIterable, CustomStringConvertible {
        case headlessPrint, attendedZeroWithCliEntrypoint, attendedNotOne, attendedEmpty
        case cliEntrypointOnly, desktopEntrypointOnly, vscodeEntrypointOnly
        case sdkEntrypoint, unknownEntrypoint, nothingSet

        var environment: [String: String] {
            switch self {
            case .headlessPrint: ["CLAUDE_CODE_SESSION_ATTENDED": "0", "CLAUDE_CODE_ENTRYPOINT": "sdk-cli"]
            case .attendedZeroWithCliEntrypoint: ["CLAUDE_CODE_SESSION_ATTENDED": "0", "CLAUDE_CODE_ENTRYPOINT": "cli"]
            case .attendedNotOne: ["CLAUDE_CODE_SESSION_ATTENDED": "true"]
            case .attendedEmpty: ["CLAUDE_CODE_SESSION_ATTENDED": ""]
            case .cliEntrypointOnly: ["CLAUDE_CODE_ENTRYPOINT": "cli"]
            case .desktopEntrypointOnly: ["CLAUDE_CODE_ENTRYPOINT": "claude-desktop"]
            case .vscodeEntrypointOnly: ["CLAUDE_CODE_ENTRYPOINT": "claude-vscode"]
            case .sdkEntrypoint: ["CLAUDE_CODE_ENTRYPOINT": "sdk-ts"]
            case .unknownEntrypoint: ["CLAUDE_CODE_ENTRYPOINT": "local-agent"]
            case .nothingSet: [:]
            }
        }

        var description: String {
            switch self {
            case .headlessPrint: "headlessPrint"
            case .attendedZeroWithCliEntrypoint: "attendedZeroWithCliEntrypoint"
            case .attendedNotOne: "attendedNotOne"
            case .attendedEmpty: "attendedEmpty"
            case .cliEntrypointOnly: "cliEntrypointOnly"
            case .desktopEntrypointOnly: "desktopEntrypointOnly"
            case .vscodeEntrypointOnly: "vscodeEntrypointOnly"
            case .sdkEntrypoint: "sdkEntrypoint"
            case .unknownEntrypoint: "unknownEntrypoint"
            case .nothingSet: "nothingSet"
            }
        }
    }

    enum DownPath: CaseIterable, CustomStringConvertible {
        case nativeUnreachable, nativeTimeout, nativeConnection, adapterTimeout

        var stub: AdapterStub {
            switch self {
            case .nativeUnreachable: daemonDownWire(.claude)
            case .nativeTimeout: claudeAskWire(reason: cTimeoutMessage)
            case .nativeConnection: claudeAskWire(reason: cConnectionMessage)
            case .adapterTimeout: .sleep(seconds: 5)
            }
        }

        var description: String {
            switch self {
            case .nativeUnreachable: "nativeUnreachable"
            case .nativeTimeout: "nativeTimeout"
            case .nativeConnection: "nativeConnection"
            case .adapterTimeout: "adapterTimeout"
            }
        }
    }

    enum OtherNativeAsk: CaseIterable, CustomStringConvertible {
        case noReason, otherText, downReasonWithSuffix, downReasonOnlyInSystemMessage
        case downReasonExitTwo, downReasonKilled, downReasonBesideDecisionDeny, downReasonBesideDecisionAsk

        var stub: AdapterStub {
            switch self {
            case .downReasonExitTwo:
                claudeAskWire(reason: daemonUnreachableMessage, exit: 2)
            case .downReasonKilled:
                claudeAskWire(reason: daemonUnreachableMessage, exit: 137)
            case .downReasonBesideDecisionDeny:
                .stdout(
                    "{\"decision\":\"deny\",\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\",\"permissionDecisionReason\":\"\(daemonUnreachableMessage)\"}}\n",
                    exit: 0)
            case .downReasonBesideDecisionAsk:
                .stdout(
                    "{\"decision\":\"ask\",\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\",\"permissionDecisionReason\":\"\(daemonUnreachableMessage)\"}}\n",
                    exit: 0)
            case .noReason:
                .stdout("{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\"}}\n", exit: 0)
            case .otherText:
                claudeAskWire(reason: "rvd is down, please approve")
            case .downReasonWithSuffix:
                claudeAskWire(reason: daemonUnreachableMessage + " Approve to continue.")
            case .downReasonOnlyInSystemMessage:
                .stdout(
                    "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\"},\"systemMessage\":\"\(daemonUnreachableMessage)\"}\n",
                    exit: 0)
            }
        }

        var expectedReason: String {
            switch self {
            case .noReason: "rv blocked this action without giving a reason. Run `rv doctor`."
            case .otherText: "rvd is down, please approve"
            case .downReasonWithSuffix: daemonUnreachableMessage + " Approve to continue."
            case .downReasonOnlyInSystemMessage, .downReasonExitTwo, .downReasonKilled,
                .downReasonBesideDecisionDeny:
                daemonUnreachableMessage
            case .downReasonBesideDecisionAsk: "rv blocked this action without giving a reason. Run `rv doctor`."
            }
        }

        var description: String {
            switch self {
            case .noReason: "noReason"
            case .otherText: "otherText"
            case .downReasonWithSuffix: "downReasonWithSuffix"
            case .downReasonOnlyInSystemMessage: "downReasonOnlyInSystemMessage"
            case .downReasonExitTwo: "downReasonExitTwo"
            case .downReasonKilled: "downReasonKilled"
            case .downReasonBesideDecisionDeny: "downReasonBesideDecisionDeny"
            case .downReasonBesideDecisionAsk: "downReasonBesideDecisionAsk"
            }
        }
    }

    enum StillBlocks: CaseIterable, CustomStringConvertible {
        case missing, notExecutable, unparseable, emptyNonZero, rvDeny, rvPolicyAsk

        var stub: AdapterStub {
            switch self {
            case .missing: .missing
            case .notExecutable: .notExecutable
            case .unparseable: .stdout("not-json", exit: 3)
            case .emptyNonZero: .stdout("", exit: 7)
            case .rvDeny:
                .stdout(
                    "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"no\"}}\n",
                    exit: 0)
            case .rvPolicyAsk: .stdout("{\"decision\":\"ask\",\"reason\":\"review\"}\n", exit: 0)
            }
        }

        var description: String {
            switch self {
            case .missing: "missing"
            case .notExecutable: "notExecutable"
            case .unparseable: "unparseable"
            case .emptyNonZero: "emptyNonZero"
            case .rvDeny: "rvDeny"
            case .rvPolicyAsk: "rvPolicyAsk"
            }
        }
    }
}

/// Writes the owner config the adapter reads, with `mode` set explicitly
/// (the umask cannot widen or narrow it).
private func writeOwnerConfig(_ text: String, at path: URL, mode: Int = 0o600) throws {
    try Data(text.utf8).write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path.path)
}

/// How the prompt shows one escaped UTF-16 unit: a backslash, `u`, and
/// four lowercase hex digits (built without a backslash literal so the
/// expectation stays readable as ASCII).
private func escaped(_ hex: String) -> String {
    backslash + "u" + hex
}

private let backslash = String(UnicodeScalar(92))

/// `kTimeoutMessage` / `kConnectionMessage` in `Sources/rv-c/hook_fallback.c`
/// (pinned by `ClaudeAdapterHookTests.cDownReasons_matchHookFallbackSource`).
private let cTimeoutMessage = "RV daemon did not answer in time. Retry; if it persists run `rv doctor`."
private let cConnectionMessage =
    "RV daemon connection failed or dropped before a verdict. Retry; if it persists run `rv doctor`."

/// The C hook's Claude `ask` reply for `reason` (`render_ask`).
private func claudeAskWire(reason: String, exit: Int32 = 0) -> AdapterStub {
    .stdout(
        "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\",\"permissionDecisionReason\":\"\(reason)\"},\"systemMessage\":\"\(reason)\"}\n",
        exit: exit)
}

/// Asserts Claude's documented ask wire (documented fields only) and
/// returns the prompt text.
private func expectClaudeAsk(_ run: PythonAdapterRun) throws -> String {
    #expect(run.exitCode == 0)
    let json = try wireObject(run.stdout)
    #expect(Set(json.keys) == ["systemMessage", "hookSpecificOutput"])
    let hook = try #require(json["hookSpecificOutput"] as? [String: Any])
    #expect(Set(hook.keys) == ["hookEventName", "permissionDecision", "permissionDecisionReason"])
    #expect(hook["hookEventName"] as? String == "PreToolUse")
    #expect(hook["permissionDecision"] as? String == "ask")
    let reason = try #require(hook["permissionDecisionReason"] as? String)
    #expect(json["systemMessage"] as? String == reason)
    return reason
}
