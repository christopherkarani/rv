import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVService

/// SEC-A01 / AC-A01..A03: the typed reader (`GuardConfig.read(home:)` +
/// `GuardModeResolution`) against the legacy `JSONSerialization` +
/// `[String: Any]` readers, over the same `config.json` bytes on disk.
///
/// Where the two parsers legitimately disagree the new path must be the
/// stricter one: `enforce` for the mode, `nil` for the engine, a missing
/// entry for a host. A new `observe` the legacy path did not produce is a
/// blocking defect.
@Suite("Guard config equivalence")
struct GuardConfigEquivalenceTests {
    struct Document: Sendable, CustomTestStringConvertible {
        let name: String
        /// nil: no `config.json` at all.
        let bytes: [UInt8]?
        var testDescription: String { name }

        init(_ name: String, _ json: String) {
            self.name = name
            self.bytes = Array(json.utf8)
        }

        init(_ name: String, bytes: [UInt8]?) {
            self.name = name
            self.bytes = bytes
        }
    }

    static let environments: [[String: String]] = [
        [:],
        ["RV_GUARD_MODE": "enforce"],
        ["RV_GUARD_MODE": "ENFORCE"],
        ["RV_GUARD_MODE": "observe"],
        ["RV_GUARD_MODE": "bogus"],
    ]

    static let hosts: [HookHost?] = [nil] + HookHost.allCases.map { Optional($0) }

    static let corpus: [Document] = [
        // Each key: nested only, flat only, both.
        Document("mode nested", #"{"guard": {"mode": "observe"}}"#),
        Document("mode flat", #"{"guard.mode": "observe"}"#),
        Document("mode both, nested wins", #"{"guard": {"mode": "enforce"}, "guard.mode": "observe"}"#),
        Document("mode both, nested observe", #"{"guard": {"mode": "observe"}, "guard.mode": "enforce"}"#),
        Document("engine nested", #"{"judge": {"engine": "ft"}}"#),
        Document("engine flat", #"{"judge.engine": "laya"}"#),
        Document("engine both", #"{"judge": {"engine": "laya"}, "judge.engine": "ft"}"#),
        Document("hosts nested", #"{"guard": {"hosts": {"claude": "observe", "codex": "off", "grok": "block"}}}"#),
        Document("hosts flat (unsupported)", #"{"guard.hosts": {"claude": "observe"}}"#),
        Document("hosts both", #"{"guard": {"hosts": {"claude": "block"}}, "guard.hosts": {"claude": "observe"}}"#),
        Document("hosts over enforce mode", #"{"guard": {"mode": "enforce", "hosts": {"claude": "off", "cursor": "observe"}}}"#),
        Document("block host over observe mode", #"{"guard": {"mode": "observe", "hosts": {"claude": "block"}}}"#),
        Document("all keys", #"{"guard": {"mode": "observe", "hosts": {"pi": "block"}}, "judge": {"engine": "laya"}}"#),
        // Unknown nested value shadowing a valid flat one.
        Document("mode unknown nested shadows flat", #"{"guard": {"mode": "bogus"}, "guard.mode": "observe"}"#),
        Document("engine unknown nested shadows flat", #"{"judge": {"engine": "gpt"}, "judge.engine": "ft"}"#),
        // Empty strings.
        Document("mode empty nested falls through", #"{"guard": {"mode": ""}, "guard.mode": "OBSERVE"}"#),
        Document("mode empty flat", #"{"guard.mode": ""}"#),
        Document("engine empty nested falls through", #"{"judge": {"engine": ""}, "judge.engine": "laya"}"#),
        Document("host empty value", #"{"guard": {"mode": "observe", "hosts": {"claude": ""}}}"#),
        Document("empty object", "{}"),
        // Mixed case.
        Document("mode mixed case", #"{"guard": {"mode": "ObSeRvE"}}"#),
        Document("engine mixed case", #"{"judge.engine": "LaYa"}"#),
        Document("host value mixed case", #"{"guard": {"hosts": {"claude": "Observe", "codex": "OFF", "pi": "Block"}}}"#),
        Document("host key mixed case", #"{"guard": {"hosts": {"Claude": "observe"}}}"#),
        Document("nested key mixed case", #"{"Guard": {"Mode": "observe"}, "Guard.Mode": "observe"}"#),
        // Non-string values.
        Document("mode number", #"{"guard": {"mode": 1}, "guard.mode": "observe"}"#),
        Document("mode bool", #"{"guard": {"mode": true}, "guard.mode": "observe"}"#),
        Document("mode null", #"{"guard": {"mode": null}, "guard.mode": "observe"}"#),
        Document("mode object", #"{"guard": {"mode": {"x": "observe"}}, "guard.mode": "observe"}"#),
        Document("mode array", #"{"guard": {"mode": ["observe"]}, "guard.mode": "observe"}"#),
        Document("flat mode non-string", #"{"guard.mode": false}"#),
        Document("flat mode array", #"{"guard.mode": ["observe"]}"#),
        Document("engine non-strings", #"{"judge": {"engine": 0}, "judge.engine": null}"#),
        Document("engine non-string nested, flat valid", #"{"judge": {"engine": [1]}, "judge.engine": "ft"}"#),
        Document("host values non-string", #"{"guard": {"mode": "observe", "hosts": {"claude": 1, "codex": true, "cursor": null, "grok": {}, "pi": ["off"]}}}"#),
        Document("hosts as array", #"{"guard": {"hosts": ["claude"], "mode": "observe"}}"#),
        Document("hosts as string", #"{"guard": {"hosts": "observe"}}"#),
        // Unknown host keys.
        Document("unknown host keys", #"{"guard": {"hosts": {"nope": "observe", "": "off", "claude ": "observe"}}}"#),
        // `guard` / `judge` as a non-object.
        Document("guard string", #"{"guard": "observe", "guard.mode": "observe"}"#),
        Document("guard array", #"{"guard": [{"mode": "observe"}]}"#),
        Document("guard null", #"{"guard": null, "guard.mode": "observe"}"#),
        Document("guard number", #"{"guard": 1}"#),
        Document("judge string", #"{"judge": "ft", "judge.engine": "laya"}"#),
        // Top-level non-object.
        Document("top-level string", #""observe""#),
        Document("top-level array", #"[{"guard": {"mode": "observe"}}]"#),
        Document("top-level null", "null"),
        Document("top-level number", "1"),
        Document("top-level bool", "true"),
        // Duplicate keys.
        Document("duplicate guard, observe last", #"{"guard": {"mode": "enforce"}, "guard": {"mode": "observe"}}"#),
        Document("duplicate guard, observe first", #"{"guard": {"mode": "observe"}, "guard": {"mode": "enforce"}}"#),
        Document("duplicate mode, observe last", #"{"guard": {"mode": "enforce", "mode": "observe"}}"#),
        Document("duplicate mode, observe first", #"{"guard": {"mode": "observe", "mode": "enforce"}}"#),
        Document("duplicate flat mode", #"{"guard.mode": "enforce", "guard.mode": "observe"}"#),
        Document("duplicate host key", #"{"guard": {"hosts": {"claude": "block", "claude": "observe"}}}"#),
        Document("duplicate host key, observe first", #"{"guard": {"hosts": {"claude": "observe", "claude": "block"}}}"#),
        Document("duplicate engine", #"{"judge": {"engine": "ft", "engine": "laya"}}"#),
        Document("duplicate guard, object then string", #"{"guard": {"mode": "enforce"}, "guard": "x", "guard.mode": "observe"}"#),
        Document("duplicate guard, string then object", #"{"guard": "x", "guard": {"mode": "observe"}}"#),
        Document("duplicate in an unrelated object", #"{"guard.mode": "observe", "analytics": {"enabled": true, "enabled": false}}"#),
        // U+FEFF in a key: Darwin JSONSerialization drops a leading one.
        Document("BOM-prefixed flat mode key", "{\"\u{FEFF}guard.mode\": \"enforce\", \"guard.mode\": \"observe\"}"),
        Document("BOM-prefixed guard key", "{\"\u{FEFF}guard\": {\"mode\": \"enforce\"}, \"guard\": {\"mode\": \"observe\"}}"),
        Document("raw and escaped BOM keys", "{\"\u{FEFF}guard.mode\": \"observe\", " + #""\uFEFFguard.mode": "enforce"}"#),
        // Integers beyond 2^53.
        Document("mode big int, flat observe", #"{"guard": {"mode": 9007199254740993}, "guard.mode": "observe"}"#),
        Document("mode huge uint, flat observe", #"{"guard": {"mode": 18446744073709551615}, "guard.mode": "observe"}"#),
        Document("engine big int, flat ft", #"{"judge": {"engine": 9007199254740993}, "judge.engine": "ft"}"#),
        Document("host big int", #"{"guard": {"mode": "observe", "hosts": {"claude": 9007199254740993}}}"#),
        Document("flat mode big int", #"{"guard.mode": 9007199254740993}"#),
        Document("sibling big int", #"{"guard": {"mode": "observe"}, "n": 9007199254740993}"#),
        Document("sibling beyond Double", #"{"guard": {"mode": "observe"}, "n": 1e400}"#),
        Document("sibling negative big int", #"{"guard.mode": "observe", "n": -9223372036854775809}"#),
        // Parsers disagree on validity (Darwin or Linux legacy accepts).
        Document("arrays nested 512 deep", #"{"guard.mode": "observe", "x": "#
            + String(repeating: "[", count: 512) + String(repeating: "]", count: 512) + "}"),
        Document("sibling -1e309", #"{"guard.mode": "observe", "x": -1e309}"#),
        Document("arrays nested 65 deep", #"{"guard.mode": "observe", "x": "#
            + String(repeating: "[", count: 64) + String(repeating: "]", count: 64) + "}"),
        Document("arrays nested 64 deep", #"{"guard.mode": "observe", "x": "#
            + String(repeating: "[", count: 63) + String(repeating: "]", count: 63) + "}"),
        Document("UTF-32LE with BOM", bytes: [0xFF, 0xFE, 0x00, 0x00]
            + Array(#"{"guard.mode": "observe"}"#.data(using: .utf32LittleEndian)!)),
        Document("UTF-16LE", bytes: Array(#"{"guard.mode": "observe"}"#.data(using: .utf16LittleEndian)!)),
        // UTF-8 BOM.
        Document("BOM nested observe", bytes: [0xEF, 0xBB, 0xBF] + Array(#"{"guard": {"mode": "observe"}}"#.utf8)),
        Document("BOM host observe", bytes: [0xEF, 0xBB, 0xBF] + Array(#"{"guard": {"hosts": {"claude": "observe"}}}"#.utf8)),
        // Escapes and odd strings.
        Document("escaped mode", #"{"guard": {"mode": "\u006Fbserve"}}"#),
        Document("escaped key", #"{"gu\u0061rd": {"mode": "observe"}}"#),
        Document("lone surrogate sibling", #"{"guard.mode": "observe", "x": "\ud800"}"#),
        Document("mode with whitespace", #"{"guard": {"mode": " observe"}, "guard.mode": "observe"}"#),
        Document("mode with NUL", #"{"guard": {"mode": "observe\u0000"}}"#),
        // Invalid JSON.
        Document("truncated", #"{"guard": {"mode": "observe"}"#),
        Document("trailing comma", #"{"guard.mode": "observe",}"#),
        Document("comment", "// observe\n" + #"{"guard.mode": "observe"}"#),
        Document("single quotes", #"{'guard.mode': 'observe'}"#),
        Document("unquoted key", #"{guard: {mode: "observe"}}"#),
        Document("trailing garbage", #"{"guard.mode": "observe"} x"#),
        Document("not json", "observe"),
        Document("empty file", ""),
        Document("whitespace file", " \n"),
        Document("invalid UTF-8", bytes: Array(#"{"guard.mode": "observe", "x": ""#.utf8) + [0xFF, 0xFE] + Array(#""}"#.utf8)),
        // No file.
        Document("no file", bytes: nil),
    ]

    /// What the typed reader resolves for each corpus document, generated
    /// from the T1 tip (where it was checked against the legacy
    /// `[String: Any]` readers on macOS, and in a standalone copy on Linux)
    /// and committed verbatim. It keeps guarding `GuardConfig.read` +
    /// `GuardModeResolution` after the legacy readers are deleted.
    ///
    /// `modes` has one row per `environments` entry, in order; each row has
    /// one letter per `hosts` entry (nil, then `HookHost.allCases`):
    /// `E` enforce, `O` observe. `hosts` is the decoded `guard.hosts`,
    /// sorted, as `host=mode` pairs.
    struct Golden: Sendable {
        let name: String
        let modes: [String]
        let engine: JudgeEngine?
        let hosts: String

        init(_ name: String, modes: [String], engine: JudgeEngine?, hosts: String) {
            self.name = name
            self.modes = modes
            self.engine = engine
            self.hosts = hosts
        }
    }

    static let golden: [Golden] = [
        Golden("mode nested", modes: ["OOOOOOOOOOO", "EEEEEEEEEEE", "EEEEEEEEEEE", "OOOOOOOOOOO", "OOOOOOOOOOO"], engine: nil, hosts: ""),
        Golden("mode flat", modes: ["OOOOOOOOOOO", "EEEEEEEEEEE", "EEEEEEEEEEE", "OOOOOOOOOOO", "OOOOOOOOOOO"], engine: nil, hosts: ""),
        Golden("mode both, nested wins", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("mode both, nested observe", modes: ["OOOOOOOOOOO", "EEEEEEEEEEE", "EEEEEEEEEEE", "OOOOOOOOOOO", "OOOOOOOOOOO"], engine: nil, hosts: ""),
        Golden("engine nested", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: .ft, hosts: ""),
        Golden("engine flat", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: .laya, hosts: ""),
        Golden("engine both", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: .laya, hosts: ""),
        Golden("hosts nested", modes: ["EEEEOEEOEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEOEEOEEE", "EEEEOEEOEEE"], engine: nil, hosts: "claude=observe,codex=off,grok=block"),
        Golden("hosts flat (unsupported)", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("hosts both", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: "claude=block"),
        Golden("hosts over enforce mode", modes: ["EEEEOEEEOEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEOEEEOEE", "EEEEOEEEOEE"], engine: nil, hosts: "claude=off,cursor=observe"),
        Golden("block host over observe mode", modes: ["OOOOEOOOOOO", "EEEEEEEEEEE", "EEEEEEEEEEE", "OOOOEOOOOOO", "OOOOEOOOOOO"], engine: nil, hosts: "claude=block"),
        Golden("all keys", modes: ["OOEOOOOOOOO", "EEEEEEEEEEE", "EEEEEEEEEEE", "OOEOOOOOOOO", "OOEOOOOOOOO"], engine: .laya, hosts: "pi=block"),
        Golden("mode unknown nested shadows flat", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("engine unknown nested shadows flat", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("mode empty nested falls through", modes: ["OOOOOOOOOOO", "EEEEEEEEEEE", "EEEEEEEEEEE", "OOOOOOOOOOO", "OOOOOOOOOOO"], engine: nil, hosts: ""),
        Golden("mode empty flat", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("engine empty nested falls through", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: .laya, hosts: ""),
        Golden("host empty value", modes: ["OOOOOOOOOOO", "EEEEEEEEEEE", "EEEEEEEEEEE", "OOOOOOOOOOO", "OOOOOOOOOOO"], engine: nil, hosts: ""),
        Golden("empty object", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("mode mixed case", modes: ["OOOOOOOOOOO", "EEEEEEEEEEE", "EEEEEEEEEEE", "OOOOOOOOOOO", "OOOOOOOOOOO"], engine: nil, hosts: ""),
        Golden("engine mixed case", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: .laya, hosts: ""),
        Golden("host value mixed case", modes: ["EEEEOEEOEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEOEEOEEE", "EEEEOEEOEEE"], engine: nil, hosts: "claude=observe,codex=off,pi=block"),
        Golden("host key mixed case", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("nested key mixed case", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("mode number", modes: ["OOOOOOOOOOO", "EEEEEEEEEEE", "EEEEEEEEEEE", "OOOOOOOOOOO", "OOOOOOOOOOO"], engine: nil, hosts: ""),
        Golden("mode bool", modes: ["OOOOOOOOOOO", "EEEEEEEEEEE", "EEEEEEEEEEE", "OOOOOOOOOOO", "OOOOOOOOOOO"], engine: nil, hosts: ""),
        Golden("mode null", modes: ["OOOOOOOOOOO", "EEEEEEEEEEE", "EEEEEEEEEEE", "OOOOOOOOOOO", "OOOOOOOOOOO"], engine: nil, hosts: ""),
        Golden("mode object", modes: ["OOOOOOOOOOO", "EEEEEEEEEEE", "EEEEEEEEEEE", "OOOOOOOOOOO", "OOOOOOOOOOO"], engine: nil, hosts: ""),
        Golden("mode array", modes: ["OOOOOOOOOOO", "EEEEEEEEEEE", "EEEEEEEEEEE", "OOOOOOOOOOO", "OOOOOOOOOOO"], engine: nil, hosts: ""),
        Golden("flat mode non-string", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("flat mode array", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("engine non-strings", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("engine non-string nested, flat valid", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: .ft, hosts: ""),
        Golden("host values non-string", modes: ["OOOOOOOOOOO", "EEEEEEEEEEE", "EEEEEEEEEEE", "OOOOOOOOOOO", "OOOOOOOOOOO"], engine: nil, hosts: ""),
        Golden("hosts as array", modes: ["OOOOOOOOOOO", "EEEEEEEEEEE", "EEEEEEEEEEE", "OOOOOOOOOOO", "OOOOOOOOOOO"], engine: nil, hosts: ""),
        Golden("hosts as string", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("unknown host keys", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("guard string", modes: ["OOOOOOOOOOO", "EEEEEEEEEEE", "EEEEEEEEEEE", "OOOOOOOOOOO", "OOOOOOOOOOO"], engine: nil, hosts: ""),
        Golden("guard array", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("guard null", modes: ["OOOOOOOOOOO", "EEEEEEEEEEE", "EEEEEEEEEEE", "OOOOOOOOOOO", "OOOOOOOOOOO"], engine: nil, hosts: ""),
        Golden("guard number", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("judge string", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: .laya, hosts: ""),
        Golden("top-level string", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("top-level array", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("top-level null", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("top-level number", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("top-level bool", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("duplicate guard, observe last", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""), // reads as .empty; legacy is parser-dependent
        Golden("duplicate guard, observe first", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""), // reads as .empty; legacy is parser-dependent
        Golden("duplicate mode, observe last", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""), // reads as .empty; legacy is parser-dependent
        Golden("duplicate mode, observe first", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""), // reads as .empty; legacy is parser-dependent
        Golden("duplicate flat mode", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""), // reads as .empty; legacy is parser-dependent
        Golden("duplicate host key", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""), // reads as .empty; legacy is parser-dependent
        Golden("duplicate host key, observe first", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""), // reads as .empty; legacy is parser-dependent
        Golden("duplicate engine", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""), // reads as .empty; legacy is parser-dependent
        Golden("duplicate guard, object then string", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""), // reads as .empty; legacy is parser-dependent
        Golden("duplicate guard, string then object", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""), // reads as .empty; legacy is parser-dependent
        Golden("duplicate in an unrelated object", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""), // reads as .empty; legacy is parser-dependent
        Golden("BOM-prefixed flat mode key", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""), // reads as .empty; legacy is parser-dependent
        Golden("BOM-prefixed guard key", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""), // reads as .empty; legacy is parser-dependent
        Golden("raw and escaped BOM keys", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""), // reads as .empty; legacy is parser-dependent
        Golden("mode big int, flat observe", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""), // reads as .empty; legacy is parser-dependent
        Golden("mode huge uint, flat observe", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""), // reads as .empty; legacy is parser-dependent
        Golden("engine big int, flat ft", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""), // reads as .empty; legacy is parser-dependent
        Golden("host big int", modes: ["OOOOOOOOOOO", "EEEEEEEEEEE", "EEEEEEEEEEE", "OOOOOOOOOOO", "OOOOOOOOOOO"], engine: nil, hosts: ""),
        Golden("flat mode big int", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("sibling big int", modes: ["OOOOOOOOOOO", "EEEEEEEEEEE", "EEEEEEEEEEE", "OOOOOOOOOOO", "OOOOOOOOOOO"], engine: nil, hosts: ""),
        Golden("sibling beyond Double", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("sibling negative big int", modes: ["OOOOOOOOOOO", "EEEEEEEEEEE", "EEEEEEEEEEE", "OOOOOOOOOOO", "OOOOOOOOOOO"], engine: nil, hosts: ""),
        Golden("arrays nested 512 deep", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""), // reads as .empty; legacy is parser-dependent
        Golden("sibling -1e309", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""), // reads as .empty; legacy is parser-dependent
        Golden("arrays nested 65 deep", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""), // reads as .empty; legacy is parser-dependent
        Golden("arrays nested 64 deep", modes: ["OOOOOOOOOOO", "EEEEEEEEEEE", "EEEEEEEEEEE", "OOOOOOOOOOO", "OOOOOOOOOOO"], engine: nil, hosts: ""),
        Golden("UTF-32LE with BOM", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""), // reads as .empty; legacy is parser-dependent
        Golden("UTF-16LE", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""), // reads as .empty; legacy is parser-dependent
        Golden("BOM nested observe", modes: ["OOOOOOOOOOO", "EEEEEEEEEEE", "EEEEEEEEEEE", "OOOOOOOOOOO", "OOOOOOOOOOO"], engine: nil, hosts: ""),
        Golden("BOM host observe", modes: ["EEEEOEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEOEEEEEE", "EEEEOEEEEEE"], engine: nil, hosts: "claude=observe"),
        Golden("escaped mode", modes: ["OOOOOOOOOOO", "EEEEEEEEEEE", "EEEEEEEEEEE", "OOOOOOOOOOO", "OOOOOOOOOOO"], engine: nil, hosts: ""),
        Golden("escaped key", modes: ["OOOOOOOOOOO", "EEEEEEEEEEE", "EEEEEEEEEEE", "OOOOOOOOOOO", "OOOOOOOOOOO"], engine: nil, hosts: ""),
        Golden("lone surrogate sibling", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("mode with whitespace", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("mode with NUL", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("truncated", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("trailing comma", modes: ["OOOOOOOOOOO", "EEEEEEEEEEE", "EEEEEEEEEEE", "OOOOOOOOOOO", "OOOOOOOOOOO"], engine: nil, hosts: ""),
        Golden("comment", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("single quotes", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("unquoted key", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("trailing garbage", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("not json", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("empty file", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("whitespace file", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("invalid UTF-8", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
        Golden("no file", modes: ["EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE", "EEEEEEEEEEE"], engine: nil, hosts: ""),
    ]

    /// Both readers' view of one document, read from the same file.
    struct Views {
        let legacy: [String: Any]?
        let typed: GuardConfig

        static func load(_ document: Document) throws -> Views {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("rv-guard-equiv-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: url) }
            let home = try #require(HomeDirectory(validating: url.path))
            if let bytes = document.bytes {
                let directory = RVPolicyPaths.configDirectory(home: home)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data(bytes).write(to: directory.appendingPathComponent("config.json"))
            }
            return Views(legacy: JudgeRuntime.loadConfigDict(home: home), typed: GuardConfig.read(home: home))
        }

        typealias ModeDivergence = (host: HookHost?, environment: [String: String], old: GuardMode, new: GuardMode)

        func modeDivergences() -> [ModeDivergence] {
            var out: [ModeDivergence] = []
            for host in GuardConfigEquivalenceTests.hosts {
                for environment in GuardConfigEquivalenceTests.environments {
                    let old = JudgeRuntime.guardMode(environment: environment, config: legacy, host: host)
                    let new = GuardModeResolution.resolve(typed, host: host, environment: environment)
                    if old != new { out.append((host: host, environment: environment, old: old, new: new)) }
                }
            }
            return out
        }

        var engineDiverges: Bool { typed.judgeEngine != JudgeRuntime.explicitEngine(config: legacy) }
        var hostsDiverge: Bool { typed.hosts != HostModeStore.modes(inConfig: legacy) }
    }

    @Test("golden table: the typed reader resolves each document as frozen", arguments: zip(corpus, golden))
    func goldenTable(_ document: Document, _ expected: Golden) throws {
        #expect(document.name == expected.name)
        let config = try Views.load(document).typed
        let modes = Self.environments.map { environment in
            String(Self.hosts.map {
                GuardModeResolution.resolve(config, host: $0, environment: environment) == .enforce ? "E" : "O"
            })
        }
        #expect(modes == expected.modes)
        #expect(config.judgeEngine == expected.engine)
        let hosts = config.hosts.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)=\($0.value.rawValue)" }.joined(separator: ",")
        #expect(hosts == expected.hosts)
    }

    @Test("the golden table covers the corpus one to one")
    func goldenCoversCorpus() {
        #expect(Self.golden.map(\.name) == Self.corpus.map(\.name))
        #expect(Set(Self.corpus.map(\.name)).count == Self.corpus.count)
    }

    @Test("AC-A01: same guard mode as the legacy reader, or enforce", arguments: corpus)
    func guardMode(_ document: Document) throws {
        let views = try Views.load(document)
        for divergence in views.modeDivergences() {
            #expect(
                divergence.new == .enforce,
                "new path observes where legacy enforces: host \(String(describing: divergence.host)), env \(divergence.environment)")
        }
        #expect(views.typed.machineMode == JudgeRuntime.guardMode(environment: [:], config: views.legacy)
            || views.typed.machineMode == .enforce)
    }

    @Test("AC-A02: same judge engine as the legacy reader, or nil", arguments: corpus)
    func judgeEngine(_ document: Document) throws {
        let views = try Views.load(document)
        let old = JudgeRuntime.explicitEngine(config: views.legacy)
        #expect(views.typed.judgeEngine == old || views.typed.judgeEngine == nil)
    }

    @Test("AC-A03: same host modes as the legacy reader, or an entry omitted", arguments: corpus)
    func hostModes(_ document: Document) throws {
        let views = try Views.load(document)
        let old = HostModeStore.modes(inConfig: views.legacy)
        for (host, mode) in views.typed.hosts {
            #expect(old[host] == mode, "new path adds or changes \(host): \(mode), legacy \(String(describing: old[host]))")
        }
    }

    /// Every other document resolves exactly as the legacy reader does, on
    /// every platform.
    @Test("outside the known divergences the readers agree exactly", arguments: corpus)
    func agreesOutsideKnownDivergences(_ document: Document) throws {
        guard !Self.knownDivergences.contains(document.name) else { return }
        let views = try Views.load(document)
        #expect(views.modeDivergences().isEmpty)
        #expect(!views.engineDiverges)
        #expect(!views.hostsDiverge)
    }

    /// Where the legacy reader's answer depends on the platform's parser,
    /// the typed reader does not: it reads `.empty` (enforce, no engine, no
    /// host entries) on every platform.
    @Test("known divergences read as empty", arguments: knownDivergences)
    func knownDivergenceIsEmpty(_ name: String) throws {
        let document = try #require(Self.corpus.first { $0.name == name })
        #expect(try Views.load(document).typed == .empty)
    }

    /// Documents the parsers may disagree on.
    /// - Integers beyond 2^53: `JSONValue` keeps the digit string, which as
    ///   the nested value is chosen, fails to parse and shadows the flat
    ///   key. The legacy reader sees an `NSNumber`, skips it and takes the
    ///   flat key.
    /// - Duplicate keys: Darwin keeps the first, swift-corelibs
    ///   `JSONSerialization` the last. `GuardConfig(jsonData:)` rejects any
    ///   duplicate, and any key holding U+FEFF (Darwin drops a leading one,
    ///   so `"\u{FEFF}guard"` and `"guard"` collide there).
    /// - Validity: Darwin legacy accepts arrays nested 512 deep and
    ///   `-1e309`; Linux legacy accepts UTF-32LE with a BOM; both accept
    ///   UTF-16, which the duplicate-key scan cannot vouch for, and nesting
    ///   past `JSONDuplicateKeys.maxNestingDepth` (65 containers).
    static let knownDivergences: [String] = [
        "duplicate guard, observe last",
        "duplicate guard, observe first",
        "duplicate mode, observe last",
        "duplicate mode, observe first",
        "duplicate flat mode",
        "duplicate host key",
        "duplicate host key, observe first",
        "duplicate engine",
        "duplicate guard, object then string",
        "duplicate guard, string then object",
        "duplicate in an unrelated object",
        "BOM-prefixed flat mode key",
        "BOM-prefixed guard key",
        "raw and escaped BOM keys",
        "mode big int, flat observe",
        "mode huge uint, flat observe",
        "engine big int, flat ft",
        "arrays nested 512 deep",
        "sibling -1e309",
        "arrays nested 65 deep",
        "UTF-32LE with BOM",
        "UTF-16LE",
    ]

    @Test("the corpus resolves to observe somewhere, so the equivalence is not vacuous")
    func corpusExercisesObserve() throws {
        var observed = 0
        for document in Self.corpus {
            let views = try Views.load(document)
            for host in Self.hosts where GuardModeResolution.resolve(views.typed, host: host, environment: [:]) == .observe {
                observed += 1
            }
        }
        #expect(observed > 0)
    }
}
