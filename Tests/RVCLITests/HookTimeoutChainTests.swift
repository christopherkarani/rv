import Foundation
import RVService
import Testing
@testable import RVCLI

/// The hook path crosses four timeouts in three languages. They must stay
/// ordered so the innermost one expires first: if a host or shim gives up
/// while rvd still treats the call as live, rvd can spend an allow-once
/// grant on a reply nobody reads. Order:
/// daemon budget < C client (hello + evaluate) < shim < host hook config.
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

    private func cClientMaxMilliseconds() throws -> Int {
        let c = try source("Sources/rv-c/rv.c")
        let hello = try #require(number(#"^#define RV_HELLO_TIMEOUT_MS (\d+)"#, in: c))
        let evaluate = try #require(number(#"^#define RV_EVALUATE_TIMEOUT_MS (\d+)"#, in: c))
        let retry = number(#"^#define RV_HOOK_RETRY_DELAY_MS (\d+)"#, in: c) ?? 0
        return hello + evaluate + retry
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

    @Test func everyShimOutlastsTheCClient() throws {
        let client = try cClientMaxMilliseconds()
        for template in Self.shimTemplates {
            #expect(try shimMilliseconds(template) > client, "\(template) kills rv before the C client gives up")
        }
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
