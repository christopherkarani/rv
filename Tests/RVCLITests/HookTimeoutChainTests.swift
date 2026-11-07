import Foundation
import RVService
import Testing
@testable import RVCLI

/// The hook path crosses four timeouts in three languages. They must stay
/// ordered so the innermost one expires first: if a host or shim gives up
/// while rvd still treats the call as live, rvd can spend an allow-once
/// grant on a reply nobody reads. Order:
/// rvd (request by the send cutoff + its 7 s budget) and the C client
/// (send cutoff + evaluate timeout) < shim < host hook config.
@Suite("Hook timeout chain")
struct HookTimeoutChainTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    /// First integer captured by `pattern` in `text`.
    private func number(_ pattern: String, in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return Int(text[range])
    }

    /// The C client never sends the evaluate request later than
    /// `RV_EVALUATE_SEND_CUTOFF_MS` after it started (two macOS hellos and
    /// a retry could otherwise push it past 12 s). Its worst case is the
    /// cutoff plus the evaluate timeout.
    private func cClientMaxMilliseconds() throws -> Int {
        let c = try source("Sources/rv-c/rv.c")
        let cutoff = try #require(number(#"^#define RV_EVALUATE_SEND_CUTOFF_MS (\d+)"#, in: c))
        let evaluate = try #require(number(#"^#define RV_EVALUATE_TIMEOUT_MS (\d+)"#, in: c))
        return cutoff + evaluate
    }

    /// The latest rvd can still commit a side effect such as a grant spend:
    /// the request arrives by the send cutoff, then rvd's own budget runs.
    private func daemonLatestMilliseconds() throws -> Int {
        let c = try source("Sources/rv-c/rv.c")
        let cutoff = try #require(number(#"^#define RV_EVALUATE_SEND_CUTOFF_MS (\d+)"#, in: c))
        let budget = HookDeadline.budget.components
        return cutoff + Int(budget.seconds) * 1000 + Int(budget.attoseconds / 1_000_000_000_000_000)
    }

    private static let shimTemplates = [
        "rv-guard-claude.py.tmpl", "rv-guard-codex.py.tmpl", "rv-guard-cursor.py.tmpl",
        "rv-guard-hermes.py.tmpl", "rv-guard-antigravity.py.tmpl",
        "rv-guard.js.tmpl", "rv-guard.ts.tmpl", "rv-guard-openclaw.js.tmpl",
    ]

    private func shimMilliseconds(_ template: String) throws -> Int {
        let text = try source("Sources/RVHooks/Resources/hosts/\(template)")
        if let seconds = number(#"^RV_HOOK_TIMEOUT_S = (\d+)"#, in: text) { return seconds * 1000 }
        return try #require(number(#"^const RV_HOOK_TIMEOUT_MS = (\d+);"#, in: text), "\(template) has no timeout")
    }

    @Test func daemonBudgetIsBelowTheCClientEvaluateTimeout() throws {
        let c = try source("Sources/rv-c/rv.c")
        let evaluate = try #require(number(#"^#define RV_EVALUATE_TIMEOUT_MS (\d+)"#, in: c))
        #expect(HookDeadline.budget < .milliseconds(evaluate))
    }

    @Test func everyShimOutlastsTheCClientAndTheDaemon() throws {
        let client = try cClientMaxMilliseconds()
        let daemon = try daemonLatestMilliseconds()
        for template in Self.shimTemplates {
            let shim = try shimMilliseconds(template)
            #expect(shim > client, "\(template) kills rv before the C client gives up")
            #expect(shim > daemon, "\(template) gives up while rvd can still spend a grant")
        }
    }

    @Test func helloPhasesFitInsideTheSendCutoff() throws {
        // A cold launchd spawn must still get its request out: one hello
        // timeout has to fit inside the cutoff.
        let c = try source("Sources/rv-c/rv.c")
        let cutoff = try #require(number(#"^#define RV_EVALUATE_SEND_CUTOFF_MS (\d+)"#, in: c))
        let hello = try #require(number(#"^#define RV_HELLO_TIMEOUT_MS (\d+)"#, in: c))
        #expect(hello < cutoff)
    }

    @Test func hostConfigsOutlastTheShims() throws {
        let longestShim = try Self.shimTemplates.map(shimMilliseconds).max() ?? 0
        let client = try cClientMaxMilliseconds()
        // Hosts that wrap a shim.
        for seconds in [CodexHooksMerge.timeout, CursorHooksMerge.timeout, AntigravityHooksMerge.timeout] {
            #expect(seconds * 1000 > longestShim)
        }
        // Hosts that call `rv hook` directly (Grok, Muse) must outlast the C client.
        for template in ["rv.json.tmpl", "rv-hooks-muse.json.tmpl"] {
            let text = try source("Sources/RVHooks/Resources/hosts/\(template)")
            let seconds = try #require(number(#""timeout": (\d+)"#, in: text))
            #expect(seconds * 1000 > client, "\(template) host timeout is shorter than the C client")
        }
    }
}
