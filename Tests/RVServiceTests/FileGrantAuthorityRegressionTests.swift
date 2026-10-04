import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVService

/// Step 8B.1 at the daemon spend shape: `LiveEvaluateWorld.apply` (the
/// hook/`rvd` path) must not honor file-planted or replayed grants.
/// Both tests FAIL against the file-authority implementation.
@Suite("File-grant daemon-spend regression")
struct FileGrantAuthorityRegressionTests {
    @Test func forgedFileGrant_applyDenies() async throws {
        let directory = try isolatedFileGrantDirectory()
        let view = MatchingView("git reset --hard")
        try plantForgedGrantedRow(
            directory: directory,
            fingerprint: commandFingerprint(view),
            cwd: "/tmp/ws"
        )
        let world = LiveEvaluateWorld(
            home: try isolatedFileGrantHome(),
            store: AllowOnceStore(baseDirectory: directory),
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let result = await world.apply(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: wd("/tmp/ws")
        )
        guard case .deny(let deny) = result.decision else {
            Issue.record("forged file grant must not spend on the daemon path")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }

    @Test func replayedConsumedRow_applyDenies() async throws {
        let store = AllowOnceStore(baseDirectory: try isolatedFileGrantDirectory())
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
        // The file redeem flips projection only; the ceremony plant (here
        // direct, in production via attestation/resolve) mints authority.
        #expect(
            await grants.plant(
                matchingView: "git reset --hard", cwd: wd("/tmp/ws"), codeHash: "file-b-f3",
                now: now
            ) == .planted
        )
        let world = LiveEvaluateWorld(
            home: try isolatedFileGrantHome(),
            store: store,
            grants: grants,
            clock: { now }
        )
        let command = ShellCommand(rawValue: "git reset --hard")
        let first = await world.apply(command: command, cwd: wd("/tmp/ws"))
        #expect(first.decision == .allow)
        try reappendGrantedRow(store: store)
        let replay = await world.apply(command: command, cwd: wd("/tmp/ws"))
        guard case .deny = replay.decision else {
            Issue.record("re-appended consumed row must not spend again")
            return
        }
    }
}

private func isolatedFileGrantDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-filegrant-auth-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func isolatedFileGrantHome() throws -> HomeDirectory {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-filegrant-home-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return try #require(HomeDirectory(validating: root.path))
}

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
