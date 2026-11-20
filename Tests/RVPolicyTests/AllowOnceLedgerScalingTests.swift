import Foundation
import RVDomain
import Testing
@testable import RVPolicy

/// Every hook deny mints through the allow-once projection file, which
/// holds up to `maxStoredRows` live rows. Re-reading and re-encoding the
/// whole file per deny made deny latency grow with it (15 ms → ~300 ms as
/// it grew from 40 to 1 900 rows). A deny now costs about the same at any
/// ledger size, and another writer's save is still picked up.
struct AllowOnceLedgerScalingTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func store(seeded rows: Int) throws -> AllowOnceStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-allow-once-scale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var body = Data()
        for index in 0..<rows {
            body.append(try encoder.encode(Self.row(index)))
            body.append(0x0A)
        }
        try body.write(to: RVPolicyPaths.allowOnceFile(inConfigDir: root))
        return AllowOnceStore(baseDirectory: root)
    }

    private static func row(_ index: Int) -> AllowOnceRecord {
        AllowOnceRecord(
            schemaVersion: 1,
            lifecycle: .pending,
            codeHash: CodeHash(rawValue: String(format: "%064x", index)),
            commandFingerprint: GrantFingerprint(rawValue: String(format: "%064x", index + 1_000_000)),
            commandRedacted: "rm -rf build-\(index)",
            cwd: WorkingDirectory(validating: "/tmp/ws")!,
            ruleID: RuleID(pack: .coreFilesystem, pattern: "rm-rf-general"),
            createdAt: now.addingTimeInterval(Double(index) / 1000),
            expiresAt: now.addingTimeInterval(15 * 60)
        )
    }

    /// Mean wall time of `count` fresh deny mints against a seeded ledger.
    private func meanMint(seeded rows: Int, count: Int) async throws -> Duration {
        let store = try store(seeded: rows)
        let cwd = WorkingDirectory(validating: "/tmp/ws")!
        // The first call reads the file; steady state is what a deny pays.
        _ = await store.mintFromDeny(matchingView: "warm up", cwd: cwd, ruleID: nil, now: Self.now)
        let started = ContinuousClock.now
        for index in 0..<count {
            let minted = await store.mintFromDeny(
                matchingView: MatchingView("git reset --hard HEAD~\(index)"),
                cwd: cwd, ruleID: nil, now: Self.now
            )
            #expect(minted != nil)
        }
        return (ContinuousClock.now - started) / count
    }

    @Test func denyMintCostDoesNotScaleWithLedgerSize() async throws {
        let small = try await meanMint(seeded: 40, count: 20)
        let large = try await meanMint(seeded: 1_900, count: 20)
        print("allow-once mintFromDeny mean: 40 rows \(small), 1900 rows \(large)")
        // Generous for a shared CI host; the old per-deny full decode and
        // re-encode of 1 900 rows took ~100-300 ms each.
        #expect(large < .milliseconds(60), "1900-row mint \(large)")
    }

    /// The cache never hides another writer: a save by a second instance (the
    /// CLI's redeem, a different process) is read on the next call.
    @Test func otherWritersAreSeen() async throws {
        let first = try store(seeded: 10)
        let second = AllowOnceStore(baseDirectory: first.baseDirectory)
        let cwd = WorkingDirectory(validating: "/tmp/ws")!
        #expect(await first.list(now: Self.now).count == 10)
        _ = await second.mintFromDeny(matchingView: "git push --force", cwd: cwd, ruleID: nil, now: Self.now)
        #expect(await first.list(now: Self.now).count == 11)
        _ = await first.mintFromDeny(matchingView: "git clean -fdx", cwd: cwd, ruleID: nil, now: Self.now)
        #expect(await second.list(now: Self.now).count == 12)
        // A same-command deny on the first instance reuses the second's row.
        #expect(await first.mintFromDeny(
            matchingView: "git push --force", cwd: cwd, ruleID: nil, now: Self.now) == .earlierPending)
        #expect(await second.list(now: Self.now).count == 12)
    }

    /// The file keeps whole-second dates. `rv allow-once list` and redeem
    /// read it in another process, so the instance that wrote a row (rvd)
    /// must see the same values they do, not the sub-second dates it held
    /// before saving: after a full rewrite, an append, a projection and a
    /// redeem flip.
    @Test func theWriterSeesTheSameRowsAsAFreshReader() async throws {
        let writer = try store(seeded: 2)
        let root = writer.baseDirectory
        let cwd = WorkingDirectory(validating: "/tmp/ws")!
        let fractional = Date(timeIntervalSince1970: 1_700_000_000.123_456)
        func agree(_ note: Comment) async {
            let fresh = AllowOnceStore(baseDirectory: root)
            #expect(await writer.list(now: fractional) == fresh.list(now: fractional), note)
        }
        let first = await writer.mintFromDeny(
            matchingView: "git push --force", cwd: cwd, ruleID: nil, now: fractional)
        await agree("after a full rewrite")
        _ = await writer.mintFromDeny(
            matchingView: "git clean -fdx", cwd: cwd, ruleID: nil, now: fractional.addingTimeInterval(0.5))
        await agree("after an append")
        await writer.project(
            lifecycle: .consumed(at: fractional.addingTimeInterval(0.25)), matchingView: "make deploy",
            cwd: cwd, codeHash: String(repeating: "c", count: 64), now: fractional.addingTimeInterval(0.25))
        await agree("after a projection")
        let code = try #require(first?.code)
        let flipped = try await writer.redeem(
            code: code.rawValue, tty: TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false),
            now: fractional.addingTimeInterval(0.75))
        await agree("after a redeem flip")
        let readBack = await AllowOnceStore(baseDirectory: root).list(now: fractional)
        #expect(readBack.contains(flipped), "redeem returns the row as saved")
    }

    /// Expiry is decided on the file's whole-second dates. rvd mints a deny
    /// code at a sub-second instant; the CLI redeems in another process.
    /// Near the end of the code's life both must agree on whether it is
    /// live: rvd must not hand the code out again (or vouch for it) after
    /// redeem already calls it expired, nor drop it while redeem still
    /// accepts it.
    @Test func theWriterAndAFreshReaderAgreeWhenACodeExpires() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-allow-once-expiry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let writer = AllowOnceStore(baseDirectory: root)
        let cwd = WorkingDirectory(validating: "/tmp/ws")!
        let ttl: TimeInterval = 15 * 60
        let minted = Date(timeIntervalSince1970: 1_700_000_000.7)
        let code = try #require(await writer.mintFromDeny(
            matchingView: "git push --force", cwd: cwd, ruleID: nil, now: minted, ttl: ttl)?.code)
        let saved = try #require(await AllowOnceStore(baseDirectory: root).list(now: minted).first).expiresAt
        let held = minted.addingTimeInterval(ttl)
        try #require(saved != held, "the file keeps whole seconds")
        // An instant between the two expiries.
        let between = Date(timeIntervalSince1970: (saved.timeIntervalSince1970 + held.timeIntervalSince1970) / 2)
        let freshSeesLive = await AllowOnceStore(baseDirectory: root)
            .validatePending(code: code.rawValue, now: between) != nil
        #expect(await (writer.validatePending(code: code.rawValue, now: between) != nil) == freshSeesLive)
        #expect(await (writer.issued(codeHash: sha256Hex(code.rawValue), now: between) != nil) == freshSeesLive)
        let again = await writer.mintFromDeny(
            matchingView: "git push --force", cwd: cwd, ruleID: nil, now: between, ttl: ttl)
        #expect((again == .code(code)) == freshSeesLive, "deny reprints the code only while redeem accepts it")
    }
}
