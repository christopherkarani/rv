import Foundation
import Testing
import RVDomain
@testable import RVPolicy

/// Step 8B.1: the memory table is the sole grant authority. No file, no
/// clock tricks, no races: one plant, one winner, strict expiry, epoch death.
@Suite("Ephemeral allow-once table")
struct EphemeralAllowOnceTableTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func plantThenConsumeAllowsOnce() async {
        let table = EphemeralAllowOnceTable()
        let planted = await table.plant(
            matchingView: "git reset --hard", cwd: wd("/tmp/ws"),
            codeHash: "ceremony-1", now: now
        )
        #expect(planted == .planted)
        #expect(await table.hasGrant(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now))
        #expect(await table.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now))
        #expect(await table.hasGrant(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now) == false)
        #expect(await table.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now) == false)
    }

    @Test func doubleAttestCreatesNoSecondGrant() async {
        let table = EphemeralAllowOnceTable()
        #expect(await table.plant(
            matchingView: "git reset --hard", cwd: wd("/tmp/ws"),
            codeHash: "ceremony-1", now: now
        ) == .planted)
        #expect(await table.plant(
            matchingView: "git reset --hard", cwd: wd("/tmp/ws"),
            codeHash: "ceremony-1", now: now
        ) == .alreadyRedeemed)
        #expect(await table.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now))
        #expect(await table.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now) == false)
    }

    @Test func substitutionAndCrossWorkspaceDoNotMatch() async {
        let table = EphemeralAllowOnceTable()
        #expect(await table.plant(
            matchingView: "git push origin feature", cwd: wd("/tmp/ws"),
            codeHash: "ceremony-1", now: now
        ) == .planted)
        #expect(await table.consume(
            matchingView: "git push --force origin main", cwd: wd("/tmp/ws"), now: now
        ) == false)
        #expect(await table.consume(
            matchingView: "git push origin feature", cwd: wd("/tmp/other"), now: now
        ) == false)
        #expect(await table.consume(
            matchingView: "git push origin feature", cwd: wd("/tmp/ws"), now: now
        ))
    }

    @Test func expiryIsStrict() async {
        let table = EphemeralAllowOnceTable()
        #expect(await table.plant(
            matchingView: "git reset --hard", cwd: wd("/tmp/ws"),
            codeHash: "ceremony-1", now: now, ttl: 60
        ) == .planted)
        let late = now.addingTimeInterval(61)
        #expect(await table.hasGrant(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: late) == false)
        #expect(await table.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: late) == false)
    }

    @Test func freshTableInvalidatesOutstandingGrants() async {
        let before = EphemeralAllowOnceTable()
        #expect(await before.plant(
            matchingView: "git reset --hard", cwd: wd("/tmp/ws"),
            codeHash: "ceremony-1", now: now
        ) == .planted)
        // A restart is a fresh table (fresh epoch): nothing carries over.
        let after = EphemeralAllowOnceTable()
        #expect(after.epoch != before.epoch)
        #expect(await after.hasGrant(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now) == false)
        #expect(await after.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now) == false)
        // The old code is spendable in the new epoch only via a new ceremony.
        #expect(await after.plant(
            matchingView: "git reset --hard", cwd: wd("/tmp/ws"),
            codeHash: "ceremony-2", now: now
        ) == .planted)
    }

    @Test func concurrentConsumeHasExactlyOneWinner() async {
        let table = EphemeralAllowOnceTable()
        #expect(await table.plant(
            matchingView: "git reset --hard", cwd: wd("/tmp/ws"),
            codeHash: "ceremony-1", now: now
        ) == .planted)
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    await table.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now)
                }
            }
            var wins = 0
            for await won in group where won { wins += 1 }
            #expect(wins == 1)
        }
    }

    @Test func redeemedCodeStaysRedeemedPastGrantExpiry() async {
        // M2: a replayed attestation after grant expiry must not plant a
        // fresh grant without a human. Codes are single-use per table
        // lifetime (evicted FIFO only past the retention cap).
        let table = EphemeralAllowOnceTable()
        #expect(await table.plant(
            matchingView: "git reset --hard", cwd: wd("/tmp/ws"),
            codeHash: "ceremony-1", now: now, ttl: 60
        ) == .planted)
        #expect(await table.plant(
            matchingView: "git reset --hard", cwd: wd("/tmp/ws"),
            codeHash: "ceremony-1", now: now, ttl: 60
        ) == .alreadyRedeemed)
        let late = now.addingTimeInterval(61)
        #expect(await table.plant(
            matchingView: "git reset --hard", cwd: wd("/tmp/ws"),
            codeHash: "ceremony-1", now: late, ttl: 60
        ) == .alreadyRedeemed)
        // The expired grant itself still spends nothing.
        #expect(await table.consume(
            matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: late
        ) == false)
    }

    @Test func redeemedCodesEvictFIFOPastCap() async {
        let table = EphemeralAllowOnceTable()
        let cap = EphemeralAllowOnceTable.maxRedeemedCodes
        // Advancing clock: old grants expire (freeing grant slots) while
        // their code markers accumulate to the retention cap.
        for index in 0...cap {
            let at = now.addingTimeInterval(TimeInterval(index * 2))
            #expect(await table.plant(
                fingerprint: "fp-\(index)", cwd: wd("/tmp/ws"),
                codeHash: "code-\(index)", now: at, ttl: 1
            ) == .planted)
        }
        let end = now.addingTimeInterval(TimeInterval((cap + 1) * 2))
        // A retained code still refuses to re-plant ...
        #expect(await table.plant(
            fingerprint: "fp-1", cwd: wd("/tmp/ws"),
            codeHash: "code-1", now: end, ttl: 1
        ) == .alreadyRedeemed)
        // ... while the single evicted oldest marker re-plants.
        #expect(await table.plant(
            fingerprint: "fp-0", cwd: wd("/tmp/ws"),
            codeHash: "code-0", now: end, ttl: 1
        ) == .planted)
    }

    @Test func fullTableRefusesPlants() async {
        let table = EphemeralAllowOnceTable()
        for index in 0..<EphemeralAllowOnceTable.maxGrants {
            #expect(await table.plant(
                matchingView: MatchingView("command-\(index)"), cwd: wd("/tmp/ws"),
                codeHash: "ceremony-\(index)", now: now
            ) == .planted)
        }
        #expect(await table.plant(
            matchingView: "one-too-many", cwd: wd("/tmp/ws"),
            codeHash: "ceremony-overflow", now: now
        ) == .refused)
        // Expiry frees a slot: the human retries against a pruned table.
        let late = now.addingTimeInterval(EphemeralAllowOnceTable.maxTTL + 1)
        #expect(await table.plant(
            matchingView: "one-too-many", cwd: wd("/tmp/ws"),
            codeHash: "ceremony-overflow", now: late
        ) == .planted)
    }

    @Test func invalidInputIsRefused() async {
        let table = EphemeralAllowOnceTable()
        #expect(await table.plant(
            matchingView: "", cwd: wd("/tmp/ws"), codeHash: "c", now: now
        ) == .refused)
        #expect(await table.plant(
            matchingView: "git reset --hard", cwd: wd("/tmp/ws"), codeHash: "", now: now
        ) == .refused)
        #expect(await table.hasGrant(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now) == false)
    }
}
