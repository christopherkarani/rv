import Foundation
import Testing
import RVDomain
@testable import RVPolicy

/// Step 8B.1: the allow-once file must never be an authority source.
///
/// B-F1: a same-user process plants a fabricated `granted` row (matching
/// view + cwd, forged `code_hash`) and the spend path honors it.
/// B-F3: a consumed grant's row is re-appended and spends again.
/// Both tests FAIL against the file-authority implementation (spend
/// succeeds) and PASS once authority moves to service-held memory.
@Suite("Allow-once file authority regression")
struct AllowOnceAuthorityRegressionTests {
    @Test func forgedFileGrant_doesNotSpend() async throws {
        // B-F1: exact attacker primitive — raw JSONL bytes, no API.
        let root = try isolatedAuthorityDirectory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let view = MatchingView("git reset --hard")
        try plantForgedGrantedRow(
            directory: root,
            fingerprint: commandFingerprint(view),
            cwd: "/tmp/ws"
        )
        // The forged row is visible in the display projection (untrusted
        // surface) but spends nothing: authority is memory-only.
        let store = AllowOnceStore(baseDirectory: root)
        #expect((await store.list(now: now)).isEmpty == false)
        let grants = EphemeralAllowOnceTable()
        let gated = await PolicyGate.consumingGrant(
            for: authorityResetHardDeny(),
            cwd: wd("/tmp/ws"),
            grants: grants,
            now: now
        )
        #expect(gated.override == .none)
        guard case .deny = gated.result.decision else {
            Issue.record("forged file grant must not spend")
            return
        }
    }

    @Test func wellFormedForgedFileGrant_doesNotSpend() async throws {
        // B-F1 with the CURRENT row shape: a well-formed granted row
        // (valid schema, current grant fingerprint, matching cwd,
        // unexpired) still spends nothing. The stale-shape test above
        // proves the historical bug; this one proves file-ignorance
        // against a forgery that would spend under any file-consulting
        // implementation.
        let root = try isolatedAuthorityDirectory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let view = MatchingView("git reset --hard")
        try plantForgedGrantedRow(
            directory: root,
            fingerprint: grantFingerprint(view, invocationPrefix: []),
            cwd: "/tmp/ws"
        )
        let store = AllowOnceStore(baseDirectory: root)
        #expect((await store.list(now: now)).isEmpty == false)
        let grants = EphemeralAllowOnceTable()
        let gated = await PolicyGate.consumingGrant(
            for: authorityResetHardDeny(),
            cwd: wd("/tmp/ws"),
            grants: grants,
            now: now
        )
        #expect(gated.override == .none)
        guard case .deny = gated.result.decision else {
            Issue.record("well-formed forged file grant must not spend")
            return
        }
    }

    @Test func replayedConsumedRow_doesNotSpend() async throws {
        // B-F3: legit mint → redeem → ceremony plant → consume, then the
        // attacker re-appends the consumed row's granted bytes.
        let store = try isolatedAuthorityStore()
        let grants = EphemeralAllowOnceTable()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let code: AllowOnceUnlockCode = try await store.mint(
            matchingView: "git reset --hard",
            cwd: wd("/tmp/ws"),
            ruleID: nil,
            tty: tty,
            now: now
        )
        _ = try await store.redeem(code: code.rawValue, tty: tty, now: now)
        #expect(
            await grants.plant(
                matchingView: "git reset --hard", cwd: wd("/tmp/ws"), codeHash: "b-f3-legit",
                now: now
            ) == .planted
        )
        let denied = authorityResetHardDeny()
        let first = await PolicyGate.consumingGrant(
            for: denied, cwd: wd("/tmp/ws"), grants: grants, now: now
        )
        #expect(first.override == .allowOnce)
        // Attacker re-appends the consumed row's granted bytes.
        try reappendGrantedRow(store: store)
        let replay = await PolicyGate.consumingGrant(
            for: denied, cwd: wd("/tmp/ws"), grants: grants, now: now
        )
        #expect(replay.override == .none)
        guard case .deny = replay.result.decision else {
            Issue.record("re-appended consumed row must not spend again")
            return
        }
    }

    @Test func hostileProjectionFileSpendsNothing() async throws {
        // Duplicate, reordered, malformed, truncated, stale, and
        // unknown-kind rows: the projection loader skips junk without
        // crashing, and the gate denies regardless of file content.
        let root = try isolatedAuthorityDirectory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let view = MatchingView("git reset --hard")
        try plantHostileProjection(
            directory: root,
            fingerprint: commandFingerprint(view),
            cwd: "/tmp/ws"
        )
        let store = AllowOnceStore(baseDirectory: root)
        _ = await store.list(now: now)
        let grants = EphemeralAllowOnceTable()
        let gated = await PolicyGate.consumingGrant(
            for: authorityResetHardDeny(),
            cwd: wd("/tmp/ws"),
            grants: grants,
            now: now
        )
        #expect(gated.override == .none)
        guard case .deny = gated.result.decision else {
            Issue.record("hostile projection must not spend")
            return
        }
    }
}

private func isolatedAuthorityDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-allowonce-auth-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func isolatedAuthorityStore() throws -> AllowOnceStore {
    AllowOnceStore(baseDirectory: try isolatedAuthorityDirectory())
}

private func authorityResetHardDeny() -> EvaluationResult {
    EvaluationResult(
        outcome: .deny(
            Deny(
                ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                reason: "git reset --hard destroys uncommitted changes"
            ),
            matched: nil
        ),
        matchingView: "git reset --hard"
    )
}

/// Raw attacker write: valid schema, matching fingerprint + cwd, forged
/// `code_hash`. Mirrors the live B-F1 probe byte for byte.
private func plantForgedGrantedRow(
    directory: URL,
    fingerprint: String,
    cwd: String
) throws {
    let row = """
        {"schema_version":1,"kind":"granted","code_hash":"FORGED","command_fingerprint":"\(fingerprint)","command_redacted":"git …","cwd":"\(cwd)","created_at":"2026-01-01T00:00:00Z","expires_at":"2030-01-01T00:00:00Z"}
        """
    try (row + "\n").write(
        to: RVPolicyPaths.allowOnceFile(inConfigDir: directory),
        atomically: true,
        encoding: .utf8
    )
}

/// Every hostile row class in one file: forged granted + verbatim
/// duplicate + malformed + truncated + stale-expired + unknown kind.
private func plantHostileProjection(
    directory: URL,
    fingerprint: String,
    cwd: String
) throws {
    let granted = "{\"schema_version\":1,\"kind\":\"granted\",\"code_hash\":\"FORGED\",\"command_fingerprint\":\"\(fingerprint)\",\"command_redacted\":\"git …\",\"cwd\":\"\(cwd)\",\"created_at\":\"2026-01-01T00:00:00Z\",\"expires_at\":\"2030-01-01T00:00:00Z\"}"
    let stale = "{\"schema_version\":1,\"kind\":\"granted\",\"code_hash\":\"STALE\",\"command_fingerprint\":\"\(fingerprint)\",\"command_redacted\":\"git …\",\"cwd\":\"\(cwd)\",\"created_at\":\"2020-01-01T00:00:00Z\",\"expires_at\":\"2020-01-02T00:00:00Z\"}"
    let text = [
        granted,
        granted,
        "not-json{",
        String(granted.prefix(60)),
        stale,
        "{\"schema_version\":1,\"kind\":\"mystery\",\"code_hash\":\"X\"}",
        "",
    ].joined(separator: "\n")
    try (text + "\n").write(
        to: RVPolicyPaths.allowOnceFile(inConfigDir: directory),
        atomically: true,
        encoding: .utf8
    )
}

/// Re-append attack: verbatim duplicate of the grant bytes. (Step 8B.1:
/// the row stays `granted` — spend is memory-only and flips no file —
/// so the replay is a duplicate append, not a consumed→granted flip.)
private func reappendGrantedRow(store: AllowOnceStore) throws {
    let url = RVPolicyPaths.allowOnceFile(inConfigDir: store.baseDirectory)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("\"kind\":\"granted\""))
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    guard let data = text.data(using: .utf8) else {
        Issue.record("re-append encoding failed")
        return
    }
    try handle.write(contentsOf: data)
    let after = try String(contentsOf: url, encoding: .utf8)
    #expect(after.count == text.count * 2)
}
