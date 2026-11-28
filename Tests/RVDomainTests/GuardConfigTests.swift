import Foundation
import Testing
import RVDomain

/// `GuardConfig(JSONValue)` per-key rules and the `GuardModeResolution`
/// ladder, on decoded documents. The equivalence against the legacy
/// `[String: Any]` readers lives in `GuardConfigEquivalenceTests`
/// (RVServiceTests).
@Suite("Guard config")
struct GuardConfigTests {
    private static func config(_ json: String) throws -> GuardConfig {
        GuardConfig(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
    }

    struct ModeCase: Sendable, CustomTestStringConvertible {
        let json: String
        let mode: GuardMode?
        var testDescription: String { json }
    }

    @Test("guard.mode: nested over flat, lowercased, unparseable is nil", arguments: [
        ModeCase(json: #"{"guard": {"mode": "observe"}}"#, mode: .observe),
        ModeCase(json: #"{"guard.mode": "observe"}"#, mode: .observe),
        ModeCase(json: #"{"guard": {"mode": "enforce"}, "guard.mode": "observe"}"#, mode: .enforce),
        ModeCase(json: #"{"guard": {"mode": "bogus"}, "guard.mode": "observe"}"#, mode: nil),
        ModeCase(json: #"{"guard": {"mode": ""}, "guard.mode": "OBSERVE"}"#, mode: .observe),
        ModeCase(json: #"{"guard": {"mode": 1}, "guard.mode": "observe"}"#, mode: .observe),
        ModeCase(json: #"{"guard": "observe", "guard.mode": "Observe"}"#, mode: .observe),
        ModeCase(json: #"{"guard": {"mode": "ObSeRvE"}}"#, mode: .observe),
        ModeCase(json: #"{"guard.mode": ""}"#, mode: nil),
        ModeCase(json: #"{"guard.mode": true}"#, mode: nil),
        ModeCase(json: #"{"guard": {"mode": 9007199254740993}, "guard.mode": "observe"}"#, mode: nil),
        ModeCase(json: #"{}"#, mode: nil),
    ])
    func mode(_ testCase: ModeCase) throws {
        #expect(try Self.config(testCase.json).mode == testCase.mode)
    }

    struct EngineCase: Sendable, CustomTestStringConvertible {
        let json: String
        let engine: JudgeEngine?
        var testDescription: String { json }
    }

    @Test("judge.engine: nested over flat, lowercased, unparseable is nil", arguments: [
        EngineCase(json: #"{"judge": {"engine": "ft"}}"#, engine: .ft),
        EngineCase(json: #"{"judge.engine": "LAYA"}"#, engine: .laya),
        EngineCase(json: #"{"judge": {"engine": "laya"}, "judge.engine": "ft"}"#, engine: .laya),
        EngineCase(json: #"{"judge": {"engine": "gpt"}, "judge.engine": "ft"}"#, engine: nil),
        EngineCase(json: #"{"judge": {"engine": ""}, "judge.engine": "Ft"}"#, engine: .ft),
        EngineCase(json: #"{"judge": {"engine": null}, "judge.engine": "ft"}"#, engine: .ft),
        EngineCase(json: #"{"judge": ["ft"]}"#, engine: nil),
    ])
    func engine(_ testCase: EngineCase) throws {
        #expect(try Self.config(testCase.json).judgeEngine == testCase.engine)
    }

    @Test("judge.mode: only an explicit live decides; unset or unknown is shadow")
    func judgeMode() throws {
        #expect(try Self.config(#"{"judge": {"mode": "live"}}"#).judgeDecides)
        #expect(try Self.config(#"{"judge.mode": "LIVE"}"#).judgeDecides)
        #expect(try Self.config(#"{"judge": {"mode": "shadow"}}"#).judgeDecides == false)
        #expect(try Self.config(#"{"judge": {"mode": "bogus"}}"#).judgeDecides == false)
        #expect(try Self.config("{}").judgeDecides == false)
        #expect(try Self.config(#"{"judge": {"mode": "Shadow"}}"#).judgeMode == .shadow)
    }

    @Test("guard.hosts: nested only, known hosts and modes, lowercased")
    func hosts() throws {
        let mixed = try Self.config(
            #"{"guard": {"hosts": {"claude": "Observe", "nope": "off", "codex": 1, "cursor": "bogus", "grok": "BLOCK"}}}"#)
        #expect(mixed.hosts == [.claude: .observe, .grok: .block])
        #expect(try Self.config(#"{"guard.hosts": {"claude": "observe"}}"#).hosts == [:])
        #expect(try Self.config(#"{"guard": {"hosts": ["claude"]}}"#).hosts == [:])
    }

    @Test("a non-object root is empty", arguments: [#""observe""#, "[]", "null", "1", "true"])
    func nonObjectRoot(_ json: String) throws {
        #expect(try Self.config(json) == .empty)
    }

    @Test("ladder: env enforce, then host entry, then guard.mode, then enforce")
    func ladder() {
        let config = GuardConfig(mode: .observe, hosts: [.claude: .block, .codex: .off, .grok: .observe])
        let resolve = { (host: HookHost?, environment: [String: String]) in
            GuardModeResolution.resolve(config, host: host, environment: environment)
        }
        #expect(resolve(nil, [:]) == .observe)
        #expect(resolve(.claude, [:]) == .enforce)
        #expect(resolve(.codex, [:]) == .observe)
        #expect(resolve(.grok, [:]) == .observe)
        #expect(resolve(.cursor, [:]) == .observe)
        #expect(resolve(.codex, ["RV_GUARD_MODE": "ENFORCE"]) == .enforce)
        #expect(resolve(nil, ["RV_GUARD_MODE": "enforce"]) == .enforce)

        let enforcing = GuardConfig(mode: .enforce, hosts: [.claude: .observe])
        #expect(GuardModeResolution.resolve(enforcing, host: .claude, environment: ["RV_GUARD_MODE": "observe"]) == .observe)
        #expect(GuardModeResolution.resolve(enforcing, host: nil, environment: ["RV_GUARD_MODE": "observe"]) == .enforce)
        #expect(GuardModeResolution.resolve(.empty, host: nil, environment: ["RV_GUARD_MODE": "observe"]) == .enforce)
        #expect(GuardModeResolution.resolve(.empty, host: .claude, environment: ["RV_GUARD_MODE": "bogus"]) == .enforce)
    }

    @Test("machineMode ignores hosts and the environment")
    func machineMode() {
        #expect(GuardConfig(mode: .observe, hosts: [.claude: .block]).machineMode == .observe)
        #expect(GuardConfig(hosts: [.claude: .observe]).machineMode == .enforce)
        #expect(GuardConfig.empty.machineMode == .enforce)
    }
}
