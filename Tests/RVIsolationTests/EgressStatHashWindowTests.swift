import Foundation
import Testing
import RVDomain
@testable import RVIsolation

/// T2: stat/hash window close (SEC-1-3) + bounded hash (CON-1-5) on the T1 core.
///
/// Every digest the cache trusts must describe the bytes it fingerprinted:
/// after hashing, the path is re-stated and the digest is trusted only when
/// the fingerprint still matches (double-stat). Hash reads on the relay
/// path are bounded: the size gate refuses before reading past the cap.
@Suite("Stat/hash window")
struct EgressStatHashWindowTests {
    private static let path = "/opt/rv/bin/agent"

    @Test func interleaveDuringHashDeniesWithoutPinning() {
        // Swapped mid-hash: pre-hash F7, post-hash F9.
        let script = WindowScript(
            captures: [Self.print(inode: 7), Self.print(inode: 9)],
            digest: "mixed-digest"
        )
        let cache = EgressBinaryPinCache(
            fingerprint: { script.capture($0) },
            hashFile: { script.hash($0) }
        )
        #expect(cache.verify(canonicalPath: Self.path) == .unreadable)
        // The hash ran: the denial comes from the re-stat, not a shortcut.
        #expect(script.hashCalls == 1)
        // Nothing was pinned: a stable observation pins fresh, not mismatch.
        script.restage(captures: [Self.print(inode: 7)], digest: "mixed-digest")
        #expect(cache.verify(canonicalPath: Self.path) == .pinned)
    }

    @Test func interleaveOnPinnedPathPreservesGolden() {
        let script = WindowScript(
            captures: [Self.print(inode: 7)],
            digest: "admission-digest"
        )
        let cache = EgressBinaryPinCache(
            fingerprint: { script.capture($0) },
            hashFile: { script.hash($0) }
        )
        #expect(cache.admit(canonicalPath: Self.path) == .pinned)
        // Swapped mid-hash on a pinned path: deny, golden untouched.
        script.restage(
            captures: [Self.print(inode: 9), Self.print(inode: 10)],
            digest: "swapped-digest"
        )
        #expect(cache.verifyAdmitted(canonicalPath: Self.path) == .unreadable)
        // Entry and fingerprint intact: fast-path match, no new hash.
        script.restage(captures: [Self.print(inode: 7)], digest: "admission-digest")
        #expect(cache.verifyAdmitted(canonicalPath: Self.path) == .match)
        #expect(script.hashCalls == 2)
        // Golden digest intact: a rehash still compares against admission.
        script.restage(captures: [Self.print(inode: 11)], digest: "admission-digest")
        #expect(cache.verifyAdmitted(canonicalPath: Self.path) == .match)
    }

    @Test func postHashStatFailureDenies() {
        // Deleted mid-hash: pre-hash F7, post-hash stat fails.
        let script = WindowScript(
            captures: [Self.print(inode: 7), nil],
            digest: "mixed-digest"
        )
        let cache = EgressBinaryPinCache(
            fingerprint: { script.capture($0) },
            hashFile: { script.hash($0) }
        )
        #expect(cache.verify(canonicalPath: Self.path) == .unreadable)
        script.restage(captures: [Self.print(inode: 7)], digest: "mixed-digest")
        #expect(cache.verify(canonicalPath: Self.path) == .pinned)
    }

    @Test func trustOnFirstUseFlowSurvivesWindowClose() {
        let script = WindowScript(
            captures: [Self.print(inode: 7)],
            digest: "golden"
        )
        let cache = EgressBinaryPinCache(
            fingerprint: { script.capture($0) },
            hashFile: { script.hash($0) }
        )
        #expect(cache.verify(canonicalPath: Self.path) == .pinned)
        // Unchanged fingerprint skips the hash entirely.
        #expect(cache.verify(canonicalPath: Self.path) == .match)
        #expect(script.hashCalls == 1)
        // Rewritten with identical content: rehashes, matches, refreshes.
        script.restage(captures: [Self.print(inode: 8)], digest: "golden")
        #expect(cache.verify(canonicalPath: Self.path) == .match)
        #expect(script.hashCalls == 2)
        // Changed hash: denies, and the golden pin is unchanged.
        script.restage(captures: [Self.print(inode: 9)], digest: "tampered")
        #expect(
            cache.verify(canonicalPath: Self.path)
                == .mismatch(expected: "golden", observed: "tampered")
        )
        // Restored content matches the still-golden pin.
        script.restage(captures: [Self.print(inode: 10)], digest: "golden")
        #expect(cache.verify(canonicalPath: Self.path) == .match)
    }

    @Test func concurrentFirstPinYieldsSingleGolden() async {
        let script = WindowScript(
            captures: [Self.print(inode: 7)],
            digest: "golden"
        )
        let cache = EgressBinaryPinCache(
            fingerprint: { script.capture($0) },
            hashFile: { script.hash($0) }
        )
        let verdicts = await withTaskGroup(
            of: EgressBinaryPinCache.Verdict.self,
            returning: [EgressBinaryPinCache.Verdict].self
        ) { group in
            for _ in 0..<8 {
                group.addTask { cache.verify(canonicalPath: Self.path) }
            }
            var collected: [EgressBinaryPinCache.Verdict] = []
            for await verdict in group {
                collected.append(verdict)
            }
            return collected
        }
        #expect(verdicts.filter({ $0 == .pinned }).count == 1)
        #expect(verdicts.filter({ $0 == .match }).count == 7)
    }

    @Test func boundedHashRefusesHugeFileBeforeReading() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-egress-huge-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: EgressBinaryPinCache.maxHashBytes)
        try handle.write(contentsOf: Data([0x7f]))
        try handle.close()
        defer { try? FileManager.default.removeItem(at: file) }
        // The size gate refuses before reading: instant, no hash to EOF.
        let start = Date()
        #expect(EgressBinaryPinCache.boundedHashOfFile(atPath: file.path) == nil)
        #expect(Date().timeIntervalSince(start) < 10)
        // And the relay path denies it as unreadable.
        #expect(EgressBinaryPinCache().verify(canonicalPath: file.path) == .unreadable)
    }

    @Test func boundedHashMatchesUnboundedForSmallFiles() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-egress-bounded-\(UUID().uuidString)")
        try Data("pinned-bytes".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(
            EgressBinaryPinCache.boundedHashOfFile(atPath: file.path)
                == RVDigest.sha256HexOfFile(atPath: file.path)
        )
        let cache = EgressBinaryPinCache()
        #expect(cache.verify(canonicalPath: file.path) == .pinned)
        #expect(cache.verify(canonicalPath: file.path) == .match)
        try Data("pinned-bytes-plus-more".utf8).write(to: file)
        let verdict = cache.verify(canonicalPath: file.path)
        guard case .mismatch = verdict else {
            Issue.record("expected mismatch after rewrite, got \(verdict)")
            return
        }
    }

    @Test func boundedHashRefusesMissingPath() {
        #expect(
            EgressBinaryPinCache.boundedHashOfFile(
                atPath: "/nonexistent-rv-dir-\(UUID().uuidString)/nope"
            ) == nil
        )
    }

    private static func print(inode: UInt64) -> EgressBinaryFingerprint {
        EgressBinaryFingerprint(
            size: 128,
            mtimeSeconds: 1_700_000_000,
            mtimeNanoseconds: 0,
            ctimeSeconds: 1_700_000_000,
            ctimeNanoseconds: 0,
            device: 1,
            inode: inode
        )
    }
}

/// Scripted `stat`/hash backend with a per-call capture queue, so tests
/// can swing the fingerprint mid-verify (stat/hash interleave). Captures
/// are consumed in order; the last repeats once the queue drains.
private final class WindowScript: @unchecked Sendable {
    private let lock = NSLock()
    private var captures: [EgressBinaryFingerprint?]
    private var digest: String?
    private var hashCallsValue = 0

    init(captures: [EgressBinaryFingerprint?], digest: String?) {
        self.captures = captures
        self.digest = digest
    }

    func restage(captures: [EgressBinaryFingerprint?], digest: String?) {
        lock.lock()
        defer { lock.unlock() }
        self.captures = captures
        self.digest = digest
    }

    func capture(_: String) -> EgressBinaryFingerprint? {
        lock.lock()
        defer { lock.unlock() }
        guard captures.isEmpty == false else { return nil }
        if captures.count > 1 {
            return captures.removeFirst()
        }
        return captures[0]
    }

    func hash(_: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        hashCallsValue += 1
        return digest
    }

    var hashCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return hashCallsValue
    }
}
