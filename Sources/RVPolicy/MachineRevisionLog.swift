#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import RVDomain

/// The sealed machine revision log as a pure value core: bytes in, decisions
/// and bytes out. No `FileManager`, no clock, no locks. `TypedRuleStore`
/// reads the files under its locks, calls in here, and writes what comes
/// back.
///
/// Wire format (SEC-002, byte-pinned by golden fixtures): one
/// `[.sortedKeys]` JSON object per line, lines joined by "\n" with a
/// trailing "\n"; the tip is one sorted-keys object with no newline.
/// Record MAC = HMAC-SHA256 over
/// `rv-policy-log/v1\n<revision>\n<prev>\n<recordedAtMs>\n` + raw TOML bytes;
/// tip MAC over `rv-policy-log-tip/v1\n<revision>\n<tip>`.
enum MachineRevisionLog {
    static let genesis = "genesis"
    static let keyByteCount = 32

    /// One verified sealed record with its decoded TOML.
    struct Record: Sendable, Equatable {
        let revision: Int
        let prev: String
        let mac: String
        let recordedAtMs: Int64
        let toml: String
        let document: PolicyDocument
    }

    /// A chain that passed full verification (or the empty chain of a fresh
    /// config dir). It carries the key that verified it, so an append can
    /// never mint a key over an existing log. Only `verify`, `classifyAbsent`
    /// and `appending` construct it.
    struct VerifiedChain: Sendable {
        let records: [Record]
        fileprivate let keyBytes: Data?

        fileprivate init(records: [Record], keyBytes: Data?) {
            self.records = records
            self.keyBytes = keyBytes
        }

        /// The chain of a fresh config dir: no records, no key yet.
        static var fresh: VerifiedChain { VerifiedChain(records: [], keyBytes: nil) }

        /// Public numbering: consecutive records whose documents hash
        /// identically (identical re-saves) compress to the first.
        /// Public revision N is generation N (1-based).
        var generations: [Record] {
            var result: [Record] = []
            result.reserveCapacity(records.count)
            var previousHash: String?
            for record in records {
                let hash = PolicyRevisionIdentity.hash(record.document)
                if hash != previousHash {
                    result.append(record)
                    previousHash = hash
                }
            }
            return result
        }

        var sealedHead: Record? { records.last }
    }

    enum Reconciliation: Equatable {
        case unchanged
        case sealTail(toml: String, recordedAtMs: Int64)
    }

    struct Appended: Sendable {
        let chain: VerifiedChain
        let head: Record
        let logBytes: Data
        let tipBytes: Data
        /// Raw key bytes to persist before the log, only when this append
        /// minted the key (first record of a fresh log).
        let mintedKey: Data?
    }

    // MARK: - Missing log

    /// The log file is absent. Fresh config dir (no policy file, no
    /// remnants) is the empty chain; `policy.toml` without its log is
    /// `logMissing`; a lone tip or key is `logCorrupted`.
    static func classifyAbsent(
        policyFileExists: Bool,
        remnantExists: Bool
    ) throws(TypedRuleStoreError) -> VerifiedChain {
        if policyFileExists { throw .logMissing }
        if remnantExists { throw .logCorrupted }
        return .fresh
    }

    // MARK: - Verify

    /// Full-chain verification: UTF-8 and non-empty log, a 32-byte key,
    /// contiguous 1-based revisions, `prev` linkage from `genesis`, valid
    /// base64 and HMAC per record, parseable sealed TOML, and a MAC-sealed
    /// tip matching the last record (which makes truncation detectable).
    /// Any failure throws `logCorrupted`. Never mints or repairs.
    static func verify(
        logBytes: Data?,
        tipBytes: Data?,
        keyBytes: Data?
    ) throws(TypedRuleStoreError) -> VerifiedChain {
        guard let logBytes, let logText = String(data: logBytes, encoding: .utf8) else {
            throw .logCorrupted
        }
        let lines = logText.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.isEmpty == false else { throw .logCorrupted }
        guard let keyBytes, keyBytes.count == keyByteCount else { throw .logCorrupted }
        let decoder = JSONDecoder()
        var verified: [Record] = []
        verified.reserveCapacity(lines.count)
        var expectedPrev = genesis
        for (index, line) in lines.enumerated() {
            guard let lineData = String(line).data(using: .utf8),
                let wire = try? decoder.decode(WireRecord.self, from: lineData),
                wire.revision == index + 1,
                wire.prev == expectedPrev,
                let tomlData = Data(base64Encoded: wire.tomlBase64),
                let toml = String(data: tomlData, encoding: .utf8)
            else {
                throw .logCorrupted
            }
            let expected = recordMAC(
                revision: wire.revision,
                prev: wire.prev,
                recordedAtMs: wire.recordedAtMs,
                toml: tomlData,
                keyBytes: keyBytes
            )
            guard constantTimeEqual(expected, wire.mac) else { throw .logCorrupted }
            guard let document = try? PolicyDocumentTOML.parse(toml) else {
                throw .logCorrupted
            }
            verified.append(
                Record(
                    revision: wire.revision,
                    prev: wire.prev,
                    mac: wire.mac,
                    recordedAtMs: wire.recordedAtMs,
                    toml: toml,
                    document: document
                )
            )
            expectedPrev = wire.mac
        }
        guard let tipBytes,
            let tip = try? decoder.decode(WireTip.self, from: tipBytes),
            let last = verified.last,
            tip.revision == last.revision,
            tip.tip == last.mac
        else {
            throw .logCorrupted
        }
        let expectedTipMAC = tipMAC(revision: tip.revision, tip: tip.tip, keyBytes: keyBytes)
        guard constantTimeEqual(expectedTipMAC, tip.mac) else { throw .logCorrupted }
        return VerifiedChain(records: verified, keyBytes: keyBytes)
    }

    // MARK: - Display agreement

    /// Dual-log agreement (BYPASS-1/2): the display log must describe the
    /// same generation sequence as the sealed chain. After compressing
    /// identical re-saves, both sequences must agree in length and, per
    /// generation, in byte-exact TOML, document hash, and sealed record
    /// time. An empty display list against non-empty sealed history
    /// (deleted `.jsonl`) is `logMissing`; everything else is
    /// `logCorrupted`.
    static func checkDisplay(
        _ chain: VerifiedChain,
        matches entries: [PolicyRevision]
    ) throws(TypedRuleStoreError) {
        if entries.isEmpty {
            if chain.records.isEmpty { return }
            throw .logMissing
        }
        let generations = chain.generations
        guard generations.count == entries.count else { throw .logCorrupted }
        guard displayPrefixAgrees(entries, generations) else { throw .logCorrupted }
    }

    private static func displayPrefixAgrees(
        _ entries: [PolicyRevision],
        _ generations: [Record]
    ) -> Bool {
        for (entry, record) in zip(entries, generations) {
            guard entry.toml == record.toml,
                entry.hash == PolicyRevisionIdentity.hash(record.document),
                ms(of: entry.recordedAt) == record.recordedAtMs
            else {
                return false
            }
        }
        return true
    }

    // MARK: - Interrupted-save reconcile

    /// An interrupted dual-write is exactly: display log = sealed
    /// generations plus one tail line, every shared generation agreeing,
    /// and the tail's TOML equal to the live `policy.toml` bytes. Then the
    /// missing seal is appended using the tail's own timestamp. Any other
    /// shape is `unchanged` for the normal cross-check to judge.
    static func reconcile(
        _ chain: VerifiedChain,
        display entries: [PolicyRevision],
        liveTOML: String?
    ) -> Reconciliation {
        let generations = chain.generations
        guard entries.count == generations.count + 1, let tail = entries.last else {
            return .unchanged
        }
        guard displayPrefixAgrees(entries, generations) else { return .unchanged }
        guard let liveTOML, liveTOML == tail.toml else { return .unchanged }
        return .sealTail(toml: tail.toml, recordedAtMs: ms(of: tail.recordedAt))
    }

    // MARK: - Append

    /// Seals `toml` as the next head record and reseals the tip, encoding
    /// the whole chain for an atomic full rewrite. Mints a key only for the
    /// first record of a fresh log (`newKeyBytes` is the entropy seam).
    static func appending(
        toml: String,
        at recordedAtMs: Int64,
        to chain: VerifiedChain,
        newKeyBytes: () -> Data = { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
    ) throws(TypedRuleStoreError) -> Appended {
        let keyBytes: Data
        var mintedKey: Data?
        if chain.records.isEmpty {
            keyBytes = newKeyBytes()
            guard keyBytes.count == keyByteCount else { throw .logCorrupted }
            mintedKey = keyBytes
        } else {
            guard let existing = chain.keyBytes else { throw .logCorrupted }
            keyBytes = existing
        }
        let tomlData = Data(toml.utf8)
        let revision = (chain.records.last?.revision ?? 0) + 1
        let prev = chain.records.last?.mac ?? genesis
        let mac = recordMAC(
            revision: revision, prev: prev, recordedAtMs: recordedAtMs, toml: tomlData, keyBytes: keyBytes
        )
        guard let document = try? PolicyDocumentTOML.parse(toml) else {
            throw .logCorrupted
        }
        let head = Record(
            revision: revision,
            prev: prev,
            mac: mac,
            recordedAtMs: recordedAtMs,
            toml: toml,
            document: document
        )
        let records = chain.records + [head]
        let logBytes = try encodeLog(records)
        let tipBytes = try encodeTip(
            WireTip(
                revision: revision,
                tip: mac,
                mac: tipMAC(revision: revision, tip: mac, keyBytes: keyBytes)
            )
        )
        return Appended(
            chain: VerifiedChain(records: records, keyBytes: keyBytes),
            head: head,
            logBytes: logBytes,
            tipBytes: tipBytes,
            mintedKey: mintedKey
        )
    }

    // MARK: - Rollback target

    /// Public revisions are generations, so `generation` names the same
    /// record `machineHistory()` prints. Returns the target and the sealed
    /// head (the gate's second baseline).
    static func rollbackTarget(
        generation: Int,
        in chain: VerifiedChain
    ) throws(TypedRuleStoreError) -> (target: Record, sealedHead: Record) {
        let generations = chain.generations
        guard generation >= 1, generation <= generations.count,
            let sealedHead = chain.sealedHead
        else {
            throw .revisionNotFound
        }
        return (generations[generation - 1], sealedHead)
    }

    // MARK: - Timestamps

    /// Whole milliseconds since the epoch, the sealed timestamp unit.
    /// Integer milliseconds round-trip exactly through JSON; display
    /// `Date` values derive from them so the cross-check compares
    /// integers, never floats.
    static func ms(of date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func date(ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }

    // MARK: - MACs

    static func recordMAC(
        revision: Int,
        prev: String,
        recordedAtMs: Int64,
        toml: Data,
        keyBytes: Data
    ) -> String {
        var message = Data("rv-policy-log/v1\n\(revision)\n\(prev)\n\(recordedAtMs)\n".utf8)
        message.append(toml)
        return hexEncode(Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: keyBytes))))
    }

    static func tipMAC(revision: Int, tip: String, keyBytes: Data) -> String {
        let message = Data("rv-policy-log-tip/v1\n\(revision)\n\(tip)".utf8)
        return hexEncode(Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: keyBytes))))
    }

    private static func hexEncode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(left, right) {
            diff |= a ^ b
        }
        return diff == 0
    }

    // MARK: - Wire encoding

    private static func encodeLog(_ records: [Record]) throws(TypedRuleStoreError) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var lines: [String] = []
        lines.reserveCapacity(records.count)
        for record in records {
            let wire = WireRecord(
                revision: record.revision,
                prev: record.prev,
                tomlBase64: Data(record.toml.utf8).base64EncodedString(),
                recordedAtMs: record.recordedAtMs,
                mac: record.mac
            )
            guard let data = try? encoder.encode(wire),
                let line = String(data: data, encoding: .utf8)
            else {
                throw .invalidFile
            }
            lines.append(line)
        }
        guard let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) else {
            throw .invalidFile
        }
        return data
    }

    private static func encodeTip(_ tip: WireTip) throws(TypedRuleStoreError) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(tip) else { throw .invalidFile }
        return data
    }

    /// One JSONL line of `policy-revisions.log`.
    private struct WireRecord: Codable, Sendable {
        var revision: Int
        var prev: String
        var tomlBase64: String
        var recordedAtMs: Int64
        var mac: String

        enum CodingKeys: String, CodingKey {
            case revision
            case prev
            case tomlBase64 = "toml_base64"
            case recordedAtMs = "recorded_at_ms"
            case mac
        }
    }

    /// The sealed tip: pins the head revision + head MAC so a dropped
    /// tail (which still chains) is detectable.
    private struct WireTip: Codable, Sendable {
        var revision: Int
        var tip: String
        var mac: String
    }
}
