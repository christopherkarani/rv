import Foundation
import RVDomain
import Testing
@testable import RVPolicy

/// Every hook ask records a pending row under the exclusive lock on the
/// pending-approvals file. Decoding and re-encoding the whole file per ask
/// made each ask cost more as the file grew (9 → 14 ms over 120 rows on a
/// 4-vCPU Linux host) and made parallel agents queue behind each other
/// (deny p50 112 ms at 8 at once). An ask now costs about the same at any
/// store size, a repeated ask writes nothing, and another writer's save is
/// still picked up.
struct PendingApprovalStoreScalingTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let identity = ApprovalIdentity(session: SessionID(validating: "sess-1")!, agent: .pi)

    private static func request(
        _ index: Int,
        id: String? = nil,
        timeoutPolicy: ApprovalTimeoutPolicy = .keepWaiting,
        ttl: TimeInterval = 15 * 60
    ) -> PendingApprovalRequest {
        PendingApprovalRequest(
            id: ApprovalID(rawValue: id ?? "ask-\(index)"),
            identity: identity,
            action: .shell(
                ShellAction.effectOnly(
                    EffectShell(
                        fingerprint: ActionFingerprint(rawValue: "shell:git.force-push:origin:branch-\(index)"),
                        effects: ActionEffects(kinds: [.remoteSharedBranchMutation]),
                        resources: ActionResources(remoteName: "origin", branchName: "branch-\(index)"),
                        scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/rv"))
                    )
                )
            ),
            reason: .hostAsk,
            continuation: .hostNative,
            timeoutPolicy: timeoutPolicy,
            ttl: ttl
        )
    }

    private static func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-pending-scale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func remove(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    private static func file(_ root: URL) -> URL {
        RVPolicyPaths.pendingApprovalsFile(inConfigDir: root)
    }

    /// Inode, size and modification time: what a rewrite or append changes.
    private static func identityOf(_ url: URL) throws -> [String] {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return [
            "\(attrs[.systemFileNumber] ?? "")",
            "\(attrs[.size] ?? "")",
            "\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)",
        ]
    }

    /// Mean wall time of `count` fresh asks against a store holding `rows`.
    private func meanAsk(seeded rows: Int, count: Int) async throws -> Duration {
        let store = PendingApprovalStore(baseDirectory: try Self.directory())
        for index in 0..<rows {
            _ = try await store.create(Self.request(index), now: Self.now)
        }
        let started = ContinuousClock.now
        for index in rows..<(rows + count) {
            _ = try await store.create(Self.request(index), now: Self.now)
        }
        return (ContinuousClock.now - started) / count
    }

    @Test func askCostDoesNotScaleWithStoreSize() async throws {
        let small = try await meanAsk(seeded: 10, count: 10)
        let large = try await meanAsk(seeded: 236, count: 10)
        print("pending create mean: 10 rows \(small), 236 rows \(large)")
        // Before the cache a 236-row create decoded and re-encoded every row
        // (tens of ms in a debug build). Generous for a shared CI host.
        #expect(large < small * 4 + .milliseconds(5), "236-row ask \(large) vs 10-row \(small)")
    }

    @Test func aRepeatedAskWritesNothing() async throws {
        let root = try Self.directory()
        defer { Self.remove(root) }
        let store = PendingApprovalStore(baseDirectory: root)
        let first = try await store.create(Self.request(1), now: Self.now)
        _ = try await store.create(Self.request(2), now: Self.now)
        let before = try Self.identityOf(Self.file(root))
        // Same action, identity and subject under a new id: the waiting row is reused.
        let again = try await store.create(Self.request(1, id: "ask-1-again"), now: Self.now)
        #expect(again.id == first.id)
        #expect(try Self.identityOf(Self.file(root)) == before)
    }

    /// Appended rows read back exactly, in order, from a fresh instance (a
    /// restarted rvd), and resolving one rewrites them all faithfully.
    @Test func appendedRowsReadBackAndRewriteFaithfully() async throws {
        let root = try Self.directory()
        defer { Self.remove(root) }
        let store = PendingApprovalStore(baseDirectory: root)
        var created: [PendingApproval] = []
        for index in 0..<5 {
            created.append(try await store.create(Self.request(index), now: Self.now))
        }
        let lines = try String(contentsOf: Self.file(root), encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 5)

        let restarted = PendingApprovalStore(baseDirectory: root)
        #expect(try await restarted.list(now: Self.now) == created)

        let resolved = try await store.resolve(
            id: created[2].id,
            decision: .deny,
            fingerprint: ActionFingerprint(rawValue: "shell:git.force-push:origin:branch-2"),
            identity: Self.identity,
            now: Self.now
        )
        let reread = try await PendingApprovalStore(baseDirectory: root).load(id: created[2].id, now: Self.now)
        #expect(reread == resolved)
        #expect(try await PendingApprovalStore(baseDirectory: root).list(now: Self.now).map(\.id)
            == [created[0], created[1], created[3], created[4]].map(\.id))
    }

    /// The file keeps whole-second dates. The instance that wrote a row must
    /// hand out the same row as any other reader, or a review token hashed
    /// in one process never matches the one checked in another.
    @Test func theWriterSeesTheSameRowsAsAFreshReader() async throws {
        let root = try Self.directory()
        defer { Self.remove(root) }
        let store = PendingApprovalStore(baseDirectory: root)
        let fractional = Date(timeIntervalSince1970: 1_700_000_000.123_456)
        _ = try await store.create(Self.request(1), now: fractional)
        _ = try await store.create(Self.request(2), now: fractional.addingTimeInterval(0.5))
        let fresh = try await PendingApprovalStore(baseDirectory: root).list(now: fractional)
        #expect(try await store.list(now: fractional) == fresh)
        // Also after a rewrite (a resolve flips a row in place).
        _ = try await store.resolve(
            id: ApprovalID(rawValue: "ask-1"), decision: .deny,
            fingerprint: ActionFingerprint(rawValue: "shell:git.force-push:origin:branch-1"),
            identity: Self.identity, now: fractional.addingTimeInterval(1.25)
        )
        let afterResolve = try await PendingApprovalStore(baseDirectory: root).records(now: fractional)
        #expect(try await store.records(now: fractional) == afterResolve)
    }

    /// The call that writes returns the rows as saved, not as built: a
    /// create, a resolve and a timeout sweep at sub-second times each hand
    /// back what a fresh reader then loads (and what the same instance
    /// returns on its next call), so a review token built from the writing
    /// call's result matches one built anywhere else.
    @Test func theWritingCallReturnsTheRowsAsSaved() async throws {
        let root = try Self.directory()
        defer { Self.remove(root) }
        let store = PendingApprovalStore(baseDirectory: root)
        let fractional = Date(timeIntervalSince1970: 1_700_000_000.123_456)
        let created = try await store.create(Self.request(1), now: fractional)
        #expect(try await PendingApprovalStore(baseDirectory: root).load(id: created.id, now: fractional) == created)
        #expect(try await store.load(id: created.id, now: fractional) == created)

        let resolved = try await store.resolve(
            id: created.id, decision: .deny,
            fingerprint: ActionFingerprint(rawValue: "shell:git.force-push:origin:branch-1"),
            identity: Self.identity, now: fractional.addingTimeInterval(0.25)
        )
        #expect(try await PendingApprovalStore(baseDirectory: root).load(id: created.id, now: fractional) == resolved)

        // A short auto-deny row times out on the next sweep, at a
        // sub-second `now` that the saved line keeps only to the second.
        _ = try await store.create(Self.request(2, timeoutPolicy: .autoDeny, ttl: 1), now: fractional)
        let sweptAt = fractional.addingTimeInterval(5.5)
        let events = await store.events()
        let swept = try await store.records(now: sweptAt)
        let fresh = try await PendingApprovalStore(baseDirectory: root).records(now: sweptAt)
        #expect(swept == fresh)
        #expect(try await store.records(now: sweptAt) == swept)
        let timedOut = try #require(swept.first(where: { $0.id.rawValue == "ask-2" }))
        guard case .timedOut = timedOut.state else {
            Issue.record("the auto-deny row must time out")
            return
        }
        // The published event carries the saved row too.
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == .timedOut(timedOut))
    }

    /// A rows file that exists but cannot be read is a store failure, never
    /// an empty ledger: reads and writes throw, nothing is written over it,
    /// and once it reads again every earlier row is still there. (A symlink
    /// to a directory: `stat` succeeds, the read fails, even as root.)
    @Test func aFailedReadThrowsAndNeverWipesTheLedger() async throws {
        let root = try Self.directory()
        defer { Self.remove(root) }
        let file = Self.file(root)
        let store = PendingApprovalStore(baseDirectory: root)
        let first = try await store.create(Self.request(1), now: Self.now)
        _ = try await store.create(Self.request(2), now: Self.now)
        _ = try await store.resolve(
            id: first.id, decision: .deny,
            fingerprint: ActionFingerprint(rawValue: "shell:git.force-push:origin:branch-1"),
            identity: Self.identity, now: Self.now
        )
        #expect(try await store.records(now: Self.now).count == 2)

        let aside = root.appendingPathComponent("rows-aside")
        let target = root.appendingPathComponent("not-a-file", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: aside)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)

        await #expect(throws: PendingApprovalError.encodeFailed) {
            _ = try await store.list(now: Self.now)
        }
        await #expect(throws: PendingApprovalError.encodeFailed) {
            _ = try await store.records(now: Self.now)
        }
        await #expect(throws: PendingApprovalError.encodeFailed) {
            _ = try await store.create(Self.request(3), now: Self.now)
        }
        // Nothing was written in its place: the link is still the link.
        let kind = try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType
        #expect(kind == .typeSymbolicLink)

        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: aside, to: file)
        _ = try await store.create(Self.request(3), now: Self.now)
        let rows = try await PendingApprovalStore(baseDirectory: root).records(now: Self.now)
        #expect(rows.map(\.id.rawValue) == ["ask-1", "ask-2", "ask-3"])
        guard case .resolved = try #require(rows.first).state else {
            Issue.record("the resolved row must survive the failed read")
            return
        }
    }

    /// After a plain load the file may hold rows `load` skipped. The next
    /// write is a full rewrite, which drops them, never an append after them.
    @Test func aCorruptLineIsRewrittenAwayNotAppendedAfter() async throws {
        let root = try Self.directory()
        defer { Self.remove(root) }
        try "{not-json}\n".write(to: Self.file(root), atomically: true, encoding: .utf8)
        let store = PendingApprovalStore(baseDirectory: root)
        _ = try await store.create(Self.request(1), now: Self.now)
        _ = try await store.create(Self.request(2), now: Self.now)
        let text = try String(contentsOf: Self.file(root), encoding: .utf8)
        #expect(text.contains("{not-json}") == false)
        #expect(text.split(separator: "\n").count == 2)
    }

    /// The cache never hides another writer: a save by a second instance (the
    /// CLI's approve, a different process) is read on the next call.
    @Test func otherWritersAreSeen() async throws {
        let root = try Self.directory()
        defer { Self.remove(root) }
        let first = PendingApprovalStore(baseDirectory: root)
        let second = PendingApprovalStore(baseDirectory: root)
        let a = try await first.create(Self.request(1), now: Self.now)
        _ = try await second.create(Self.request(2), now: Self.now)
        #expect(try await first.list(now: Self.now).count == 2)
        _ = try await first.create(Self.request(3), now: Self.now)
        #expect(try await second.list(now: Self.now).count == 3)
        // A resolve on the second instance is what the first one reads next.
        _ = try await second.resolve(
            id: a.id, decision: .deny,
            fingerprint: ActionFingerprint(rawValue: "shell:git.force-push:origin:branch-1"),
            identity: Self.identity, now: Self.now
        )
        guard case .resolved = try await first.load(id: a.id, now: Self.now).state else {
            Issue.record("the first instance must see the second's resolve")
            return
        }
        // And the first instance's next ask does not write that resolve away.
        _ = try await first.create(Self.request(4), now: Self.now)
        guard case .resolved = try await second.load(id: a.id, now: Self.now).state else {
            Issue.record("an append must not drop another writer's resolve")
            return
        }
    }
}
