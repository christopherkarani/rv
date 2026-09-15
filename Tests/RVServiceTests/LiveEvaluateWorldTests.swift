import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVService

struct LiveEvaluateWorldTests {
    @Test func peekOnAllowDoesNotInvokeAllowlistLoader() async throws {
        let store = try isolatedStore()
        let calls = UnfairLock(0)
        let world = try makeWorld(
            store: store,
            allowlist: { _, _ in
                calls.withLock { $0 += 1 }
                return .empty
            }
        )

        let result = await world.peek(
            command: ShellCommand(rawValue: "git stash drop"),
            cwd: wd("/tmp/ws")
        )

        #expect(result.decision == .allow)
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func peekOnDenyInvokesAllowlistLoader() async throws {
        let store = try isolatedStore()
        let calls = UnfairLock(0)
        let world = try makeWorld(
            store: store,
            allowlist: { _, _ in
                calls.withLock { $0 += 1 }
                return .empty
            }
        )

        let result = await world.peek(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: wd("/tmp/ws")
        )

        guard case .deny = result.decision else {
            Issue.record("reset --hard must deny so the loader is on the T13 deny path")
            return
        }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func applySpendsGrantOnce() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let world = try makeWorld(store: store, now: now)
        let command = ShellCommand(rawValue: "git reset --hard")
        try await store.insertGranted(
            matchingView: "git reset --hard",
            cwd: wd("/tmp/ws"),
            now: now
        )

        let first = await world.apply(command: command, cwd: wd("/tmp/ws"))
        #expect(first.decision == .allow)
        let second = await world.apply(command: command, cwd: wd("/tmp/ws"))
        guard case .deny(let deny) = second.decision else {
            Issue.record("second apply must deny after the grant is spent")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }

    @Test func peekDoesNotSpendGrant() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let world = try makeWorld(store: store, now: now)
        let command = ShellCommand(rawValue: "git reset --hard")
        try await store.insertGranted(
            matchingView: "git reset --hard",
            cwd: wd("/tmp/ws"),
            now: now
        )

        let peeked = await world.peek(command: command, cwd: wd("/tmp/ws"))
        #expect(peeked.decision == .allow)
        let peekedAgain = await world.peek(command: command, cwd: wd("/tmp/ws"))
        #expect(peekedAgain.decision == .allow)

        let first = await world.apply(command: command, cwd: wd("/tmp/ws"))
        #expect(first.decision == .allow)
        let second = await world.apply(command: command, cwd: wd("/tmp/ws"))
        guard case .deny = second.decision else {
            Issue.record("apply after peeks must still spend the grant once")
            return
        }
    }

    @Test func spendPlantsThenReplayDenies() async throws {
        let store = try isolatedStore()
        let world = try makeWorld(store: store)
        let command = ShellCommand(rawValue: "git reset --hard")

        let first = await world.spend(command: command, cwd: wd("/tmp/ws"))
        #expect(first.decision == .allow)
        let second = await world.apply(command: command, cwd: wd("/tmp/ws"))
        guard case .deny = second.decision else {
            Issue.record("replay after host spend must deny")
            return
        }
    }

    @Test func honorsAllowlistFromStoreDirectory() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ruleID = try #require(RuleID(rawValue: "core.git:reset-hard"))
        try AllowlistStore(baseDirectory: store.baseDirectory).add(
            AllowlistEntry(selector: .rule(ruleID), reason: "ci", addedAt: now),
            tty: TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        )
        let world = try makeWorld(store: store, now: now)

        let result = await world.peek(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: wd("/tmp/ws")
        )
        #expect(result.decision == .allow)
    }

    @Test func nilHomeWalksDayOne() async throws {
        let store = try isolatedStore()
        let world = LiveEvaluateWorld(
            home: nil,
            store: store,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let result = await world.peek(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: wd("/tmp/ws")
        )
        guard case .deny(let deny) = result.decision else {
            Issue.record("nil home must still compile day-one and deny reset --hard")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }

    @Test func runFileAllowsNonSecretPath() throws {
        let store = try isolatedStore()
        let world = try makeWorld(store: store)
        let result = world.runFile(
            action: FileToolAction(
                kind: .read,
                path: FileToolPath(rawValue: "/tmp/rv-oracle/src/main.swift")
            ),
            cwd: wd("/tmp/ws")
        )
        #expect(result.decision == .allow)
    }
}

private func makeWorld(
    store: AllowOnceStore,
    now: Date = Date(timeIntervalSince1970: 1_700_000_000),
    allowlist: (@Sendable (WorkingDirectory?, Date) -> AllowlistSnapshot)? = nil
) throws -> LiveEvaluateWorld {
    LiveEvaluateWorld(
        home: try isolatedHome(),
        store: store,
        clock: { now },
        allowlist: allowlist
    )
}

private func isolatedHome() throws -> HomeDirectory {
    try #require(HomeDirectory(validating: isolatedHomeDirectory().path))
}

private func isolatedStore() throws -> AllowOnceStore {
    AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory())
}
