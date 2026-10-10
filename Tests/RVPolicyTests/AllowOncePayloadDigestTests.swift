import Foundation
import Testing
import RVDomain
@testable import RVPolicy

// M-07: the allow-once file projection carries the masked payload digest
// (content digest only — never exact segments) so the TTY redeem TOCTOU
// binds the payload and a future attestation wire can plant bound grants.

struct AllowOncePayloadDigestTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let fingerprintHex = String(repeating: "a", count: 64)
    private static let digestHex = String(repeating: "b", count: 64)

    private static func record(digest: ContentPayloadDigest?) -> AllowOnceRecord {
        AllowOnceRecord(
            schemaVersion: 1,
            lifecycle: .pending,
            codeHash: CodeHash(rawValue: "hash"),
            commandFingerprint: GrantFingerprint(rawValue: Self.fingerprintHex),
            commandRedacted: "echo …",
            cwd: wd("/tmp/a"),
            ruleID: nil,
            createdAt: Self.now,
            expiresAt: Self.now.addingTimeInterval(60),
            payloadDigest: digest
        )
    }

    private static func boundRecord() -> AllowOnceRecord {
        Self.record(digest: ContentPayloadDigest(rawValue: Self.digestHex))
    }

    @Test func recordRoundTripsPayloadDigest() throws {
        let encoded = try JSONEncoder().encode(Self.boundRecord())
        let decoded = try JSONDecoder().decode(AllowOnceRecord.self, from: encoded)
        #expect(decoded == Self.boundRecord())
        #expect(decoded.payloadDigest == ContentPayloadDigest(rawValue: Self.digestHex))
    }

    @Test func recordOmitsNilDigestAndDecodesLegacy() throws {
        let encoded = try JSONEncoder().encode(Self.record(digest: nil))
        #expect(String(data: encoded, encoding: .utf8)?.contains("payload_digest") == false)
        let decoded = try JSONDecoder().decode(AllowOnceRecord.self, from: encoded)
        #expect(decoded.payloadDigest == nil)
    }

    @Test func ledgerMintStoresPayloadDigest() throws {
        let out = try AllowOnceLedger.mint(
            records: [],
            codeHash: "hash",
            fingerprint: "fingerprint",
            redacted: "echo …",
            cwd: wd("/tmp/a"),
            ruleID: nil,
            now: Self.now,
            ttl: 60,
            payloadDigest: "payload-digest"
        )
        guard case .appended(let records) = out else {
            Issue.record("fresh mint must append")
            return
        }
        #expect(records.first?.payloadDigest?.rawValue == "payload-digest")
    }

    @Test func ledgerRedeemBindsExpectedPayloadDigest() throws {
        let minted = try AllowOnceLedger.mint(
            records: [],
            codeHash: "hash",
            fingerprint: "fingerprint",
            redacted: "echo …",
            cwd: wd("/tmp/a"),
            ruleID: nil,
            now: Self.now,
            ttl: 60,
            payloadDigest: "payload-digest"
        )
        #expect(throws: AllowOnceError.redemptionChanged) {
            _ = try AllowOnceLedger.redeem(
                records: minted.records,
                codeHash: "hash",
                now: Self.now,
                expectedFingerprint: "fingerprint",
                expectedPayloadDigest: "swapped-digest"
            )
        }
        let granted = try AllowOnceLedger.redeem(
            records: minted.records,
            codeHash: "hash",
            now: Self.now,
            expectedFingerprint: "fingerprint",
            expectedPayloadDigest: "payload-digest"
        )
        guard case .granted = granted else {
            Issue.record("matching digest must grant")
            return
        }
    }

    @Test func storeMintValidateRedeemCarriesDigest() async throws {
        let store = try payloadDigestIsolatedStore()
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let code = try await store.mint(
            matchingView: "git reset --hard",
            cwd: wd("/tmp/a"),
            ruleID: nil,
            tty: tty,
            now: Self.now,
            maskedSegments: ["aaa"]
        )
        let peeked = try #require(await store.validatePending(code: code.rawValue, now: Self.now))
        #expect(peeked.fingerprint == grantFingerprint("git reset --hard", invocationPrefix: []).rawValue)
        #expect(peeked.payloadDigest == maskedPayloadContentDigest(["aaa"]).rawValue)
        await #expect(throws: AllowOnceError.redemptionChanged) {
            _ = try await store.redeem(
                code: code.rawValue, tty: tty, now: Self.now,
                expectedFingerprint: peeked.fingerprint,
                expectedPayloadDigest: "swapped-digest"
            )
        }
        let row = try await store.redeem(
            code: code.rawValue, tty: tty, now: Self.now,
            expectedFingerprint: peeked.fingerprint,
            expectedPayloadDigest: peeked.payloadDigest
        )
        #expect(row.cwd == wd("/tmp/a"))
    }

    @Test func hexShapeGateAcceptsOnlyLowercaseHex64() {
        #expect(ContentPayloadDigest(validatingHex: String(repeating: "a", count: 64)) != nil)
        #expect(ContentPayloadDigest(validatingHex: "short") == nil)
        #expect(ContentPayloadDigest(validatingHex: String(repeating: "Z", count: 64)) == nil)
        #expect(ContentPayloadDigest(validatingHex: String(repeating: "A", count: 64)) == nil)
        #expect(GrantFingerprint(validatingHex: String(repeating: "0", count: 64)) != nil)
        #expect(GrantFingerprint(validatingHex: "xyz") == nil)
        #expect(isLowercaseHex64("xyz") == false)
    }

    @Test func digestDecodeRejectsNonHex() throws {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ContentPayloadDigest.self, from: Data("\"short\"".utf8))
        }
        let upper = "\"\(String(repeating: "A", count: 64))\""
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(GrantFingerprint.self, from: Data(upper.utf8))
        }
        // Opaque domains stay total: prefixed ceremony keys must decode.
        let codeHash = try JSONDecoder().decode(CodeHash.self, from: Data("\"pending:anything\"".utf8))
        #expect(codeHash.rawValue == "pending:anything")
    }

    @Test func payloadBindingRoundTripsCodable() throws {
        let bindings: [PayloadBinding] = [
            .unbound,
            .salted(SaltedPayloadDigest(rawValue: "salted")),
            .content(ContentPayloadDigest(rawValue: String(repeating: "c", count: 64))),
        ]
        for binding in bindings {
            let decoded = try JSONDecoder().decode(
                PayloadBinding.self,
                from: try JSONEncoder().encode(binding)
            )
            #expect(decoded == binding)
        }
        // A both-set wire shape fails closed at decode.
        let both = #"{"salted":"s","content":"\#(String(repeating: "c", count: 64))"}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PayloadBinding.self, from: Data(both.utf8))
        }
    }
}

private func payloadDigestIsolatedStore() throws -> AllowOnceStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-allow-once-payload-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return AllowOnceStore(baseDirectory: root)
}
