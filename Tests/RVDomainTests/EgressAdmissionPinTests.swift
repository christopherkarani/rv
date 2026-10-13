import Foundation
import Testing
@testable import RVDomain

/// T1: admission-time pins and policy-authored expected hashes (Item 1).
///
/// A bound proxy must not let the first CONNECT both create the golden pin
/// and admit the creating request (REQ-1-1). Trust is established at a
/// trustworthy moment — `admit(at:)` at admission, or `pinExpected` from a
/// policy-authored digest — and `verifyAdmitted` denies unknown paths
/// without pinning. Restart semantics: pins are memory-only per cache
/// instance; a fresh cache starts empty and requires re-admission.
@Suite("Admission-time pin")
struct EgressAdmissionPinTests {
    private static let path = "/opt/rv/bin/agent"

    @Test func admitEstablishesGoldenBeforeFirstConnect() {
        let script = AdmissionPinScript(
            fingerprint: Self.print(inode: 7),
            digest: "admission-digest"
        )
        let cache = EgressBinaryPinCache(
            fingerprint: { script.capture($0) },
            hashFile: { script.hash($0) }
        )
        #expect(cache.admit(canonicalPath: Self.path) == .pinned)
        // First CONNECT verifies against the admission-time golden; the
        // unchanged fingerprint skips the hash entirely.
        #expect(cache.verifyAdmitted(canonicalPath: Self.path) == .match)
        #expect(script.hashCalls == 1)
    }

    @Test func verifyAdmittedDeniesUnknownPathWithoutPinning() {
        let script = AdmissionPinScript(
            fingerprint: Self.print(inode: 7),
            digest: "attacker-digest"
        )
        let cache = EgressBinaryPinCache(
            fingerprint: { script.capture($0) },
            hashFile: { script.hash($0) }
        )
        // First sighting on a bound proxy denies and creates no golden.
        #expect(cache.verifyAdmitted(canonicalPath: Self.path) == .unreadable)
        #expect(cache.verifyAdmitted(canonicalPath: Self.path) == .unreadable)
        #expect(script.hashCalls == 0)
        // Nothing was pinned: admission still pins fresh.
        #expect(cache.admit(canonicalPath: Self.path) == .pinned)
    }

    @Test func swapBetweenAdmissionAndConnectDenies() {
        let script = AdmissionPinScript(
            fingerprint: Self.print(inode: 7),
            digest: "admission-digest"
        )
        let cache = EgressBinaryPinCache(
            fingerprint: { script.capture($0) },
            hashFile: { script.hash($0) }
        )
        #expect(cache.admit(canonicalPath: Self.path) == .pinned)
        // Attacker swaps the binary before first CONNECT: deny, golden kept.
        script.retarget(fingerprint: Self.print(inode: 9), digest: "swapped-digest")
        #expect(
            cache.verifyAdmitted(canonicalPath: Self.path)
                == .mismatch(expected: "admission-digest", observed: "swapped-digest")
        )
        // Restored bytes match the still-admission-time golden.
        script.retarget(fingerprint: Self.print(inode: 10), digest: "admission-digest")
        #expect(cache.verifyAdmitted(canonicalPath: Self.path) == .match)
    }

    @Test func expectedHashAuthoredByPolicy() {
        let authored = String(repeating: "ab", count: 32)
        let script = AdmissionPinScript(
            fingerprint: Self.print(inode: 7),
            digest: authored
        )
        let cache = EgressBinaryPinCache(
            fingerprint: { script.capture($0) },
            hashFile: { script.hash($0) }
        )
        #expect(cache.pinExpected(canonicalPath: Self.path, sha256Hex: authored))
        #expect(cache.verifyAdmitted(canonicalPath: Self.path) == .match)
        // Rewritten with identical content: rehashes, matches the authored pin.
        script.retarget(fingerprint: Self.print(inode: 8), digest: authored)
        #expect(cache.verifyAdmitted(canonicalPath: Self.path) == .match)
        // Changed bytes deny against the authored golden.
        script.retarget(fingerprint: Self.print(inode: 9), digest: String(repeating: "cd", count: 32))
        #expect(
            cache.verifyAdmitted(canonicalPath: Self.path)
                == .mismatch(expected: authored, observed: String(repeating: "cd", count: 32))
        )
    }

    @Test func expectedHashRejectsMalformedAndNeverOverwrites() {
        let authored = String(repeating: "ab", count: 32)
        let script = AdmissionPinScript(
            fingerprint: Self.print(inode: 7),
            digest: authored
        )
        let cache = EgressBinaryPinCache(
            fingerprint: { script.capture($0) },
            hashFile: { script.hash($0) }
        )
        #expect(cache.pinExpected(canonicalPath: Self.path, sha256Hex: "not-a-digest") == false)
        #expect(cache.pinExpected(canonicalPath: Self.path, sha256Hex: "") == false)
        #expect(
            cache.pinExpected(canonicalPath: Self.path, sha256Hex: String(repeating: "a", count: 63))
                == false
        )
        #expect(
            cache.pinExpected(
                canonicalPath: Self.path,
                sha256Hex: String(repeating: "zz", count: 32)
            ) == false
        )
        #expect(cache.pinExpected(canonicalPath: Self.path, sha256Hex: authored))
        // A golden once pinned is never overwritten: not by policy, not by
        // a later admission observation.
        #expect(
            cache.pinExpected(canonicalPath: Self.path, sha256Hex: String(repeating: "cd", count: 32))
                == false
        )
        script.retarget(fingerprint: Self.print(inode: 9), digest: String(repeating: "cd", count: 32))
        #expect(
            cache.admit(canonicalPath: Self.path)
                == .mismatch(expected: authored, observed: String(repeating: "cd", count: 32))
        )
    }

    @Test func expectedHashNormalizesUppercaseHex() {
        let upper = String(repeating: "AB", count: 32)
        let lower = String(repeating: "ab", count: 32)
        let script = AdmissionPinScript(
            fingerprint: Self.print(inode: 7),
            digest: lower
        )
        let cache = EgressBinaryPinCache(
            fingerprint: { script.capture($0) },
            hashFile: { script.hash($0) }
        )
        #expect(cache.pinExpected(canonicalPath: Self.path, sha256Hex: upper))
        script.retarget(fingerprint: Self.print(inode: 8), digest: lower)
        #expect(cache.verifyAdmitted(canonicalPath: Self.path) == .match)
    }

    @Test func expectedHashFailsClosedWhenUnstatable() {
        let script = AdmissionPinScript(fingerprint: nil, digest: String(repeating: "ab", count: 32))
        let cache = EgressBinaryPinCache(
            fingerprint: { script.capture($0) },
            hashFile: { script.hash($0) }
        )
        #expect(
            cache.pinExpected(canonicalPath: Self.path, sha256Hex: String(repeating: "ab", count: 32))
                == false
        )
        #expect(cache.verifyAdmitted(canonicalPath: Self.path) == .unreadable)
    }

    @Test func restartRequiresReadmission() {
        let script = AdmissionPinScript(
            fingerprint: Self.print(inode: 7),
            digest: "admission-digest"
        )
        let bound = EgressBinaryPinCache(
            fingerprint: { script.capture($0) },
            hashFile: { script.hash($0) }
        )
        #expect(bound.admit(canonicalPath: Self.path) == .pinned)
        // Pins are memory-only per cache instance: a fresh cache (a new
        // runtime binding) starts empty and denies until re-admitted.
        let fresh = EgressBinaryPinCache(
            fingerprint: { script.capture($0) },
            hashFile: { script.hash($0) }
        )
        #expect(fresh.verifyAdmitted(canonicalPath: Self.path) == .unreadable)
        #expect(fresh.admit(canonicalPath: Self.path) == .pinned)
        #expect(fresh.verifyAdmitted(canonicalPath: Self.path) == .match)
    }

    @Test func capacityAppliesToAdmission() {
        let digest = String(repeating: "ab", count: 32)
        let cache = EgressBinaryPinCache(
            fingerprint: { _ in Self.print(inode: 7) },
            hashFile: { _ in digest }
        )
        for index in 0..<EgressBinaryPinCache.maxEntries {
            #expect(cache.admit(canonicalPath: "/bin/agent-\(index)") == .pinned)
        }
        #expect(cache.admit(canonicalPath: "/bin/agent-overflow") == .unreadable)
        #expect(
            cache.pinExpected(canonicalPath: "/bin/agent-overflow", sha256Hex: digest) == false
        )
        // The full cache still serves its pinned entries.
        #expect(cache.verifyAdmitted(canonicalPath: "/bin/agent-0") == .match)
    }

    @Test func admitOnRealFile() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-egress-admit-\(UUID().uuidString)")
        try Data("admitted-bytes".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let cache = EgressBinaryPinCache()
        #expect(cache.verifyAdmitted(canonicalPath: file.path) == .unreadable)
        #expect(cache.admit(canonicalPath: file.path) == .pinned)
        #expect(cache.verifyAdmitted(canonicalPath: file.path) == .match)
        try Data("admitted-bytes-plus-more".utf8).write(to: file)
        let verdict = cache.verifyAdmitted(canonicalPath: file.path)
        guard case .mismatch = verdict else {
            Issue.record("expected mismatch after rewrite, got \(verdict)")
            return
        }
    }

    @Test func expectedHashOnRealFile() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-egress-expected-\(UUID().uuidString)")
        try Data("expected-bytes".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let digest = RVDigest.sha256HexOfFile(atPath: file.path) else {
            Issue.record("could not hash fixture file")
            return
        }
        let cache = EgressBinaryPinCache()
        #expect(cache.pinExpected(canonicalPath: file.path, sha256Hex: digest))
        #expect(cache.verifyAdmitted(canonicalPath: file.path) == .match)
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

/// Scripted `stat`/hash backend for admission-pin tests.
private final class AdmissionPinScript: @unchecked Sendable {
    private let lock = NSLock()
    private var fingerprint: EgressBinaryFingerprint?
    private var digest: String?
    private var hashCallsValue = 0

    init(fingerprint: EgressBinaryFingerprint?, digest: String?) {
        self.fingerprint = fingerprint
        self.digest = digest
    }

    func retarget(fingerprint: EgressBinaryFingerprint?, digest: String?) {
        lock.lock()
        defer { lock.unlock() }
        self.fingerprint = fingerprint
        self.digest = digest
    }

    func capture(_: String) -> EgressBinaryFingerprint? {
        lock.lock()
        defer { lock.unlock() }
        return fingerprint
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
