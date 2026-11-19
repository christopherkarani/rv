import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVService

/// Observe-mode floor bypasses found live on v0.2.2.
///
/// F1: an encoded rvd stop (`eval "$(echo <b64> | base64 -d)"`) passed the
/// lexical lifecycle floor; with rvd gone the hook steps aside and observe
/// allows everything. Unanalyzable execution now holds the floor.
///
/// F3: a read-only command naming an rv wiring path (`codesign -dv
/// ~/.local/bin/rv-…`) was escalated to enforce and blocked by the judge.
/// A proven read of a wiring path is now observed like any other command.
/// `launchctl bootout gui/501/dev.rv.evaluate`, base64.
private let stop = "bGF1bmNoY3RsIGJvb3RvdXQgZ3VpLzUwMS9kZXYucnYuZXZhbHVhdGU="

@Suite("Observe floor bypasses")
struct ObserveFloorBypassTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: F1

    @Test("observe host: an encoded rvd stop is floored", arguments: [
        #"eval "$(echo \#(stop) | base64 -d)""#,
        "echo \(stop) | base64 -d | sh",
        #"python3 -c "import os,base64;os.system(base64.b64decode('\#(stop)'))""#,
        #"sh -c "$(printf '%s' \#(stop) | base64 -d)""#,
        #"git status && eval "$(echo \#(stop) | base64 -d)""#,
        "echo \(stop) | base64 -d | bash -s",
        // Not `bash <(echo … | base64 -d)`: a shell running a script file
        // is the residual risk documented in known-limits.md.
        "$(echo \(stop) | base64 -d)",
        "`echo \(stop) | base64 -d`",
        "x=$(echo \(stop) | base64 -d); $x",
        "launchctl bootout gui/501/dev.rv.evaluate",
    ])
    func observeFloorsUnanalyzableExecution(command: String) async throws {
        let home = try observeHome()
        defer { remove(home) }
        let result = await GatedEvaluate().apply(
            command: ShellCommand(rawValue: command), cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { .empty }, host: .hook(.claude)
        )
        #expect(result.decision != .allow, "\(command)")
        #expect(ledgerRows(home).allSatisfy { $0.observed == false }, "\(command)")
        let agent = GatedEvaluate().evaluateAgent(
            EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
            cwd: nil, home: home, now: Self.now,
            inputs: EvaluationInputs.gather(home: home, cwd: nil, environment: [:], host: .hook(.claude))
        )
        #expect(agent.decision != .allow, "agent door: \(command)")
    }

    /// The floor keeps the enforce verdict: a deny is never softened to
    /// "run it in Terminal".
    @Test("observe host: an unwrap-limited deny stays the deny")
    func observeKeepsUnwrapLimitedDeny() async throws {
        let home = try observeHome()
        defer { remove(home) }
        let result = await GatedEvaluate().apply(
            command: ShellCommand(rawValue: "echo \(stop) | base64 -d | sh"), cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { .empty }, host: .hook(.claude)
        )
        guard case .deny(let deny) = result.decision else {
            Issue.record("must stay denied, got \(result.decision)")
            return
        }
        #expect(deny.ruleID == BuiltinRule.unwrapLimited.ruleID)
    }

    @Test("observe host: everyday commands are still observed allows", arguments: [
        "git status",
        "ls",
        "swift build",
        "npm test",
        "git reset --hard",
        "echo aGVsbG8= | base64 -d",
        "python3 -c 'print(1)'",
    ])
    func observeEverydayAllowed(command: String) async throws {
        let home = try observeHome()
        defer { remove(home) }
        let result = await GatedEvaluate().apply(
            command: ShellCommand(rawValue: command), cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { .empty }, host: .hook(.claude)
        )
        #expect(result.decision == .allow, "\(command)")
    }

    // MARK: F3

    /// Read-only inspection of rv's install, under a judge that blocks
    /// everything: only an observed allow gets past it.
    @Test("observe host: a proven read of rv's wiring is observed", arguments: [
        "ls ~/.local/bin/rv_RVPacks.bundle",
        "ls -la ~/.local/bin/rvd",
        "stat ~/.local/bin/rvd",
        "codesign -dv ~/.local/bin/rv-workspace-host",
        "codesign -dvvv --verbose=4 ~/.local/bin/rvd",
        "codesign --verify --deep --strict ~/.local/bin/rvd",
        "codesign -dv ~/.local/bin/rv-workspace-host; log show --last 5m --style compact",
        "ls ~/.local/bin/rvd && stat ~/.local/bin/rv",
        "head -n 5 ~/Library/LaunchAgents/dev.rv.evaluate.plist",
        "ls ~/.local/bin/rvd | wc -l",
    ])
    func observeAllowsProvenWiringReads(command: String) async throws {
        let home = try observeHome()
        defer { remove(home) }
        let result = await blockingJudgeApply(command, home: home, mode: .observe)
        #expect(result.decision == .allow, "\(command)")
    }

    /// The reads above that the judge sees under enforce (outside its safe
    /// lane): before this fix an observe host escalated them to exactly this.
    @Test("enforce host: the same reads reach the judge", arguments: [
        "stat ~/.local/bin/rvd",
        "codesign -dv ~/.local/bin/rv-workspace-host",
        "codesign -dv ~/.local/bin/rv-workspace-host; log show --last 5m --style compact",
    ])
    func enforceJudgesWiringReads(command: String) async throws {
        let home = try observeHome()
        defer { remove(home) }
        let result = await blockingJudgeApply(command, home: home, mode: .enforce)
        #expect(result.decision != .allow, "\(command)")
    }

    /// The observe verdict is the enforce verdict, judge included. (Some
    /// `ls` rows are in the judge's safe lane, so both allow those.)
    @Test("observe host: anything short of a proven read stays enforced", arguments: [
        // rv's config is secret: any word naming it escalates, read or not.
        "cat ~/.config/rv/config.json",
        "cp ~/.config/rv/config.json /tmp/x",
        "ls ~/.config/rv",
        "head ~/.config/rv/config.json",
        "echo x > ~/.config/rv/config.json",
        "python3 -c 'print(1)' ~/.config/rv/x",
        // Wiring: writes, interpreters, redirects, unknown verbs, dynamic text.
        "python3 -c 'import json' ~/.local/bin/rv_RVPacks.bundle",
        "codesign -s - ~/.local/bin/rvd",
        "codesign -f -s - ~/.local/bin/rvd",
        "codesign -dv --extract-certificates ~/.local/bin/rvd",
        "codesign -d -r out ~/.local/bin/rvd",
        "codesign -d --entitlements out ~/.local/bin/rvd",
        "ls ~/.local/bin/rvd > /tmp/x",
        "ls ~/.local/bin/rvd | sh",
        "ls ~/.local/bin/rvd && rm ~/.local/bin/rvd",
        "stat ~/.local/bin/rvd; touch ~/.local/bin/rvd",
        "tee ~/.claude/settings.json",
        "cat ~/.claude/settings.json | tee ~/.claude/settings.json",
        "log erase ~/.local/bin/rvd",
        "ls $(echo ~/.local/bin/rvd)",
        "ls \"~/.local/bin/rvd\"",
        "ls ~/.local/bin/rv*",
        "env ls ~/.local/bin/rvd",
        "LS_COLORS=x ls ~/.local/bin/rvd",
        "file -C -m ~/.local/bin/rvd",
        "sed -n 1p ~/.claude/settings.json",
        // Grapheme clusters hide a separator or redirect from a
        // Character scan: `"\r\n"` and `">\u{301}"` are one Character.
        "ls ~/.local/bin/rvd \r\nrm ~/.claude/settings.json",
        "ls ~/.local/bin/rvd \rrm ~/.claude/settings.json",
        "ls ~/.local/bin/rvd >\u{301} ~/.claude/settings.json",
        "ls ~/.local/bin/rvd \u{200D};rm ~/.claude/settings.json",
        "ls ~/.local/bin/rvd \u{600};rm ~/.claude/settings.json",
        "ls ~/.local/bin/rvd\u{00A0}x",
    ])
    func observeEnforcesUnprovenWiringCommands(command: String) async throws {
        let home = try observeHome()
        defer { remove(home) }
        let observed = await blockingJudgeApply(command, home: home, mode: .observe)
        let enforced = await blockingJudgeApply(command, home: home, mode: .enforce)
        #expect(observed.decision == enforced.decision, "\(command)")
    }

    /// The proof itself, whatever the analysis says: a scalar outside its
    /// ASCII allowlist is no proof, even when every Character looks plain.
    @Test("read proof: grapheme clusters and line breaks are no proof", arguments: [
        "ls ~/.local/bin/rvd \r\nrm ~/.claude/settings.json",
        "ls ~/.local/bin/rvd \rrm ~/.claude/settings.json",
        "ls ~/.local/bin/rvd\nrm ~/.claude/settings.json",
        "ls ~/.local/bin/rvd >\u{301} ~/.claude/settings.json",
        "ls ~/.local/bin/rvd \u{200D}>~/.claude/settings.json",
        "ls ~/.local/bin/rvd \u{600};rm ~/.claude/settings.json",
        "ls ~/.local/bin/rvd\u{00A0}x",
    ])
    func readProofRefusesNonPlainScalars(command: String) {
        #expect(ObserveReadProof.proves(ShellCommand(rawValue: command), analysis: .unknown) == false,
                "\(command.debugDescription)")
    }

    @Test("read proof: plain reads prove")
    func readProofAcceptsPlainReads() {
        #expect(ObserveReadProof.proves(ShellCommand(rawValue: "ls -la ~/.local/bin/rvd | wc -l"), analysis: .unknown))
    }

    private func blockingJudgeApply(
        _ command: String, home: HomeDirectory, mode: GuardMode
    ) async -> EvaluationResult {
        let block: JudgeRuntime.JudgeRun
        do {
            block = .verdict(try effectVerdict(choice: "block", risk: 1.0))
        } catch {
            Issue.record("verdict: \(error)")
            return EvaluationResult(outcome: .plain, matchingView: MatchingView(""))
        }
        let inputs = EvaluationInputs(
            guardMode: mode,
            judge: JudgeSelection(
                engine: .ft, bundle: URL(fileURLWithPath: "/nonexistent/rv-fake-bundle", isDirectory: true)
            ),
            store: .gather(home: home, cwd: nil)
        )
        return await GatedEvaluate(EvaluateSession(), judge: EffectFixedJudge(run: block)).gated(
            .apply,
            EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
            cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { .empty }, host: .hook(.claude), tool: .bash, inputs: inputs
        )
    }
}

private func observeHome() throws -> HomeDirectory {
    let home = try guardHome(mode: nil)
    let directory = RVPolicyPaths.configDirectory(home: home)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try #"{"guard":{"hosts":{"claude":"observe"}}}"#
        .write(to: directory.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
    return home
}
