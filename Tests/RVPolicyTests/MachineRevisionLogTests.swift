import Foundation
import Testing
import RVDomain
@testable import RVPolicy

/// Characterization of the sealed machine revision log (SEC-002). Golden
/// bytes were captured from the pre-refactor store; the KAT chain was
/// computed with `openssl dgst -sha256 -mac HMAC -macopt hexkey:...` as an
/// independent oracle. These tests drive the on-disk wiring through the
/// store, so they hold before and after the pure-core move.
@Suite("MachineRevisionLogGolden")
struct MachineRevisionLogGoldenTests {
    @Test func goldenFixtureVerifiesAndListsGenerations() throws {
        let root = try goldenConfigDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)

        let history = try store.listMachineRevisions()

        #expect(history.map(\.revision) == [1, 2, 3, 4])
        #expect(history.map(\.ruleCount) == [1, 2, 3, 2])
        #expect(history[3].toml == MachineRevisionLogFixtures.policyTOML)
        #expect(try store.machineHistory() == history)
        #expect(try store.loadMachineDocument() == history[3].document)
    }

    @Test func saveAfterGoldenFixtureKeepsExistingLogLinesByteIdentical() throws {
        let root = try goldenConfigDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        let live = try store.loadMachineDocument()
        let next = PolicyDocument(
            rules: live.rules + [denyRule(pattern: "v4", branch: "release")]
        )

        try store.saveMachine(next)

        let log = try String(
            contentsOf: RVPolicyPaths.policyRevisionLogFile(inConfigDir: root), encoding: .utf8
        )
        #expect(log.hasPrefix(MachineRevisionLogFixtures.log))
        #expect(log.split(separator: "\n").count == MachineRevisionLogFixtures.sealedRecordCount + 1)
        let key = try Data(contentsOf: RVPolicyPaths.policyRevisionLogKeyFile(inConfigDir: root))
        #expect(key == MachineRevisionLogFixtures.keyBytes)
        #expect(try store.machineHistory().map(\.revision) == [1, 2, 3, 4, 5])
    }

    @Test func identicalResaveAfterGoldenFixtureSealsDuplicateWithoutGeneration() throws {
        let root = try goldenConfigDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)

        try store.saveMachine(try store.loadMachineDocument())

        let log = try String(
            contentsOf: RVPolicyPaths.policyRevisionLogFile(inConfigDir: root), encoding: .utf8
        )
        #expect(log.hasPrefix(MachineRevisionLogFixtures.log))
        #expect(log.split(separator: "\n").count == MachineRevisionLogFixtures.sealedRecordCount + 1)
        #expect(try store.machineHistory().count == MachineRevisionLogFixtures.generationCount)
        let display = try String(
            contentsOf: RVPolicyPaths.policyRevisionsFile(inConfigDir: root), encoding: .utf8
        )
        #expect(display == MachineRevisionLogFixtures.displayLog)
    }

    @Test func rollbackAfterGoldenFixtureSealsRestoreWithGenerationNumbering() throws {
        let root = try goldenConfigDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)

        let head = try store.rollbackMachine(toRevision: 3)

        #expect(head.revision == 5)
        let log = try String(
            contentsOf: RVPolicyPaths.policyRevisionLogFile(inConfigDir: root), encoding: .utf8
        )
        #expect(log.hasPrefix(MachineRevisionLogFixtures.log))
        #expect(try store.machineHistory().map(\.revision) == [1, 2, 3, 4, 5])
    }

    // MARK: - Independent oracle (openssl) chain

    @Test func opensslComputedChainVerifies() throws {
        let root = try opensslChainDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)

        let history = try store.listMachineRevisions()

        #expect(history.map(\.revision) == [1, 2])
        #expect(history.map(\.ruleCount) == [1, 2])
    }

    @Test func opensslChainWithFlippedTipMACFails() throws {
        let root = try opensslChainDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let tipURL = RVPolicyPaths.policyRevisionLogTipFile(inConfigDir: root)
        let tip = try String(contentsOf: tipURL, encoding: .utf8)
        try tip.replacingOccurrences(of: OpenSSLChain.tipMAC.prefix(2), with: "ff")
            .write(to: tipURL, atomically: true, encoding: .utf8)

        #expect(throws: TypedRuleStoreError.logCorrupted) {
            try TypedRuleStore(baseDirectory: root).listMachineRevisions()
        }
    }
}

/// HMAC-SHA256 vectors computed outside Swift:
/// `printf ... | openssl dgst -sha256 -mac HMAC -macopt hexkey:<keyHex> -r`
/// over `rv-policy-log/v1\n<rev>\n<prev>\n<ms>\n` + TOML bytes, and
/// `rv-policy-log-tip/v1\n<rev>\n<tip>` for the tip.
enum OpenSSLChain {
    static let keyHex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    static let ms1: Int64 = 1_700_000_000_000
    static let ms2: Int64 = 1_700_000_001_000
    static let mac1 = "38ef2e3e25bb6fc06c4da64af86b7670afce621ccd718b5cffac848face41f38"
    static let mac2 = "3d4ba3514687e9a599d0debe8a3b8651d93271cde8c82cfc226768b15782903b"
    static let tipMAC = "092782232f9522a993ae19918f088b2d8f3f704e2014d53578ab6ed54932c143"
    static let toml1 = """
        schema_version = 1

        [[rule]]
        id = "core.git:v1"
        verdict = "deny"
        predicate = "gitPush"
        force = "force"
        branch = "main"

        """
    static let toml2 = toml1 + """

        [[rule]]
        id = "core.git:v2"
        verdict = "deny"
        predicate = "gitPush"
        force = "force"
        branch = "develop"

        """
}

private func hexData(_ hex: String) -> Data {
    Data(stride(from: 0, to: hex.count, by: 2).map { offset in
        let start = hex.index(hex.startIndex, offsetBy: offset)
        return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
    })
}

private func goldenConfigDirectory() throws -> URL {
    let root = try temporaryConfigDirectory()
    try writeSealedFiles(
        to: root,
        key: MachineRevisionLogFixtures.keyBytes,
        log: MachineRevisionLogFixtures.log,
        tip: MachineRevisionLogFixtures.tip,
        display: MachineRevisionLogFixtures.displayLog,
        policy: MachineRevisionLogFixtures.policyTOML
    )
    return root
}

private func opensslChainDirectory() throws -> URL {
    let root = try temporaryConfigDirectory()
    let log = opensslLog()
    let tip = opensslTip()
    let display = try [
        (1, OpenSSLChain.toml1, OpenSSLChain.ms1),
        (2, OpenSSLChain.toml2, OpenSSLChain.ms2),
    ].map { revision, toml, ms in
        let document = try PolicyDocumentTOML.parse(toml)
        let entry = PolicyRevision(
            revision: revision,
            hash: PolicyRevisionIdentity.hash(document),
            ruleCount: document.rules.count,
            recordedAt: Date(timeIntervalSince1970: Double(ms) / 1000.0),
            toml: toml,
            document: document
        )
        return String(decoding: try JSONEncoder().encode(entry), as: UTF8.self) + "\n"
    }.joined()
    try writeSealedFiles(
        to: root,
        key: hexData(OpenSSLChain.keyHex),
        log: log,
        tip: tip,
        display: display,
        policy: OpenSSLChain.toml2
    )
    return root
}

private func temporaryConfigDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-machine-log-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func writeSealedFiles(
    to root: URL, key: Data, log: String, tip: String, display: String, policy: String
) throws {
    try key.write(to: RVPolicyPaths.policyRevisionLogKeyFile(inConfigDir: root))
    try log.write(
        to: RVPolicyPaths.policyRevisionLogFile(inConfigDir: root), atomically: true, encoding: .utf8)
    try tip.write(
        to: RVPolicyPaths.policyRevisionLogTipFile(inConfigDir: root), atomically: true, encoding: .utf8)
    try display.write(
        to: RVPolicyPaths.policyRevisionsFile(inConfigDir: root), atomically: true, encoding: .utf8)
    try policy.write(
        to: RVPolicyPaths.policyFile(inConfigDir: root), atomically: true, encoding: .utf8)
}

// MARK: - Pure core (no FileManager, no clock)

@Suite("MachineRevisionLogPure")
struct MachineRevisionLogPureTests {
    typealias Log = MachineRevisionLog

    private static let key = hexData(OpenSSLChain.keyHex)

    private func chain(
        _ steps: [(toml: String, ms: Int64)]
    ) throws -> Log.VerifiedChain {
        var chain = Log.VerifiedChain.fresh
        for step in steps {
            chain = try Log.appending(
                toml: step.toml, at: step.ms, to: chain, newKeyBytes: { Self.key }
            ).chain
        }
        return chain
    }

    private func opensslLogBytes() -> Data { Data(opensslLog().utf8) }
    private func opensslTipBytes() -> Data { Data(opensslTip().utf8) }

    private func verified(
        log: Data? = nil, tip: Data? = nil, key: Data? = hexData(OpenSSLChain.keyHex)
    ) throws -> Log.VerifiedChain {
        try Log.verify(
            logBytes: log ?? opensslLogBytes(), tipBytes: tip ?? opensslTipBytes(), keyBytes: key
        )
    }

    // MARK: HMAC known answers

    @Test func recordMACsMatchOpenSSL() {
        let key = Self.key
        #expect(
            Log.recordMAC(
                revision: 1, prev: "genesis", recordedAtMs: OpenSSLChain.ms1,
                toml: Data(OpenSSLChain.toml1.utf8), keyBytes: key
            ) == OpenSSLChain.mac1
        )
        #expect(
            Log.recordMAC(
                revision: 2, prev: OpenSSLChain.mac1, recordedAtMs: OpenSSLChain.ms2,
                toml: Data(OpenSSLChain.toml2.utf8), keyBytes: key
            ) == OpenSSLChain.mac2
        )
        #expect(Log.tipMAC(revision: 2, tip: OpenSSLChain.mac2, keyBytes: key) == OpenSSLChain.tipMAC)
    }

    // MARK: Wire bytes

    @Test func appendingFromFreshReproducesOpenSSLChainBytes() throws {
        let first = try Log.appending(
            toml: OpenSSLChain.toml1, at: OpenSSLChain.ms1, to: .fresh, newKeyBytes: { Self.key }
        )
        #expect(first.mintedKey == hexData(OpenSSLChain.keyHex))
        let second = try Log.appending(
            toml: OpenSSLChain.toml2, at: OpenSSLChain.ms2, to: first.chain, newKeyBytes: { Self.key }
        )
        #expect(second.mintedKey == nil)
        #expect(second.logBytes == opensslLogBytes())
        #expect(second.tipBytes == opensslTipBytes())
        #expect(second.head.revision == 2)
        #expect(second.head.prev == OpenSSLChain.mac1)
    }

    @Test func goldenFixtureVerifiesAndReencodesByteIdentically() throws {
        let golden = try Log.verify(
            logBytes: Data(MachineRevisionLogFixtures.log.utf8),
            tipBytes: Data(MachineRevisionLogFixtures.tip.utf8),
            keyBytes: MachineRevisionLogFixtures.keyBytes
        )
        #expect(golden.records.count == MachineRevisionLogFixtures.sealedRecordCount)
        #expect(golden.generations.count == MachineRevisionLogFixtures.generationCount)

        let fixtureKey = MachineRevisionLogFixtures.keyBytes
        var rebuilt = Log.VerifiedChain.fresh
        var last: Log.Appended?
        for record in golden.records {
            let appended = try Log.appending(
                toml: record.toml, at: record.recordedAtMs, to: rebuilt, newKeyBytes: { fixtureKey }
            )
            rebuilt = appended.chain
            last = appended
        }
        #expect(last?.logBytes == Data(MachineRevisionLogFixtures.log.utf8))
        #expect(last?.tipBytes == Data(MachineRevisionLogFixtures.tip.utf8))
    }

    @Test func appendedBytesVerifyAndKeepTheKey() throws {
        let appended = try Log.appending(
            toml: OpenSSLChain.toml1, at: OpenSSLChain.ms1, to: .fresh, newKeyBytes: { Self.key }
        )
        let again = try Log.verify(
            logBytes: appended.logBytes, tipBytes: appended.tipBytes, keyBytes: appended.mintedKey
        )
        #expect(again.records == appended.chain.records)
        let next = try Log.appending(toml: OpenSSLChain.toml2, at: OpenSSLChain.ms2, to: again)
        #expect(next.mintedKey == nil)
    }

    @Test func appendingRefusesUnparseableTOML() {
        #expect(throws: TypedRuleStoreError.logCorrupted) {
            try Log.appending(toml: "not = [toml", at: 1, to: .fresh)
        }
    }

    // MARK: Verify (tamper tests as pure byte-level cases)

    @Test func verifyAcceptsOpenSSLChain() throws {
        let chain = try verified()
        #expect(chain.records.map(\.revision) == [1, 2])
        #expect(chain.sealedHead?.mac == OpenSSLChain.mac2)
    }

    @Test func verifyRejectsTamperedLog() {
        let b64 = Data(OpenSSLChain.toml1.utf8).base64EncodedString()
        let evil = Data(OpenSSLChain.toml1.replacingOccurrences(of: "main", with: "evil").utf8)
            .base64EncodedString()
        let tampers: [(name: String, log: String)] = [
            ("flipped record MAC", opensslLog().replacingOccurrences(
                of: OpenSSLChain.mac1, with: "f" + OpenSSLChain.mac1.dropFirst())),
            ("forged TOML payload", opensslLog().replacingOccurrences(of: b64, with: evil)),
            ("edited timestamp", opensslLog().replacingOccurrences(
                of: "1700000000000", with: "1700000000001")),
            ("garbage line", opensslLog() + "garbage\n"),
            ("empty log", ""),
            ("invalid base64", opensslLog().replacingOccurrences(of: b64, with: "!!!")),
        ]
        for tamper in tampers {
            #expect(throws: TypedRuleStoreError.logCorrupted, "\(tamper.name)") {
                try Log.verify(
                    logBytes: Data(tamper.log.utf8), tipBytes: opensslTipBytes(),
                    keyBytes: hexData(OpenSSLChain.keyHex)
                )
            }
        }
    }

    @Test func verifyRejectsReorderedRecords() {
        let lines = opensslLog().split(separator: "\n").map(String.init)
        let swapped = Data((lines.reversed().joined(separator: "\n") + "\n").utf8)
        #expect(throws: TypedRuleStoreError.logCorrupted) {
            try Log.verify(
                logBytes: swapped, tipBytes: opensslTipBytes(), keyBytes: hexData(OpenSSLChain.keyHex)
            )
        }
    }

    @Test func verifyRejectsTruncationThatStillChains() {
        // A bare prefix still chains; only the sealed tip catches it.
        let prefix = Data((opensslLog().split(separator: "\n").first.map(String.init)! + "\n").utf8)
        #expect(throws: TypedRuleStoreError.logCorrupted) {
            try Log.verify(
                logBytes: prefix, tipBytes: opensslTipBytes(), keyBytes: hexData(OpenSSLChain.keyHex)
            )
        }
    }

    @Test func verifyRejectsNonUTF8Log() {
        #expect(throws: TypedRuleStoreError.logCorrupted) {
            try Log.verify(
                logBytes: Data([0xff, 0xfe, 0x0a]), tipBytes: opensslTipBytes(),
                keyBytes: hexData(OpenSSLChain.keyHex)
            )
        }
    }

    @Test(arguments: [nil, Data(), Data(count: 31), Data(count: 33)] as [Data?])
    func verifyRejectsMissingOrWrongSizedKey(_ key: Data?) {
        #expect(throws: TypedRuleStoreError.logCorrupted) {
            try Log.verify(logBytes: opensslLogBytes(), tipBytes: opensslTipBytes(), keyBytes: key)
        }
    }

    @Test func verifyRejectsWrongKey() {
        #expect(throws: TypedRuleStoreError.logCorrupted) {
            try Log.verify(
                logBytes: opensslLogBytes(), tipBytes: opensslTipBytes(),
                keyBytes: Data(repeating: 7, count: 32)
            )
        }
    }

    @Test func verifyRejectsMissingOrTamperedTip() {
        let key = hexData(OpenSSLChain.keyHex)
        #expect(throws: TypedRuleStoreError.logCorrupted) {
            try Log.verify(logBytes: opensslLogBytes(), tipBytes: nil, keyBytes: key)
        }
        let flipped = opensslTip().replacingOccurrences(
            of: OpenSSLChain.tipMAC, with: "f" + OpenSSLChain.tipMAC.dropFirst()
        )
        #expect(throws: TypedRuleStoreError.logCorrupted) {
            try Log.verify(logBytes: opensslLogBytes(), tipBytes: Data(flipped.utf8), keyBytes: key)
        }
        let wrongRevision = opensslTip().replacingOccurrences(of: "\"revision\":2", with: "\"revision\":1")
        #expect(throws: TypedRuleStoreError.logCorrupted) {
            try Log.verify(logBytes: opensslLogBytes(), tipBytes: Data(wrongRevision.utf8), keyBytes: key)
        }
    }

    @Test func verifyRejectsValidlySealedButUnparseableTOML() throws {
        let key = Self.key
        let toml = "not = [toml"
        let mac = Log.recordMAC(
            revision: 1, prev: "genesis", recordedAtMs: 5, toml: Data(toml.utf8), keyBytes: key
        )
        let line = #"{"mac":"\#(mac)","prev":"genesis","recorded_at_ms":5,"revision":1,"toml_base64":"\#(Data(toml.utf8).base64EncodedString())"}"#
        let tip = #"{"mac":"\#(Log.tipMAC(revision: 1, tip: mac, keyBytes: key))","revision":1,"tip":"\#(mac)"}"#
        #expect(throws: TypedRuleStoreError.logCorrupted) {
            try Log.verify(
                logBytes: Data((line + "\n").utf8), tipBytes: Data(tip.utf8),
                keyBytes: hexData(OpenSSLChain.keyHex)
            )
        }
    }

    @Test func verifyRejectsValidlySealedRecordWithBrokenPrevLinkage() {
        // Record 2 carries a correct MAC over the wrong `prev`, and the tip
        // seals it honestly, so only the prev-linkage check can refuse it.
        let key = Self.key
        let wrongPrev = String(repeating: "a", count: 64)
        let mac2 = Log.recordMAC(
            revision: 2, prev: wrongPrev, recordedAtMs: OpenSSLChain.ms2,
            toml: Data(OpenSSLChain.toml2.utf8), keyBytes: key
        )
        let b64 = { (toml: String) in Data(toml.utf8).base64EncodedString() }
        let log = [
            #"{"mac":"\#(OpenSSLChain.mac1)","prev":"genesis","recorded_at_ms":\#(OpenSSLChain.ms1),"revision":1,"toml_base64":"\#(b64(OpenSSLChain.toml1))"}"#,
            #"{"mac":"\#(mac2)","prev":"\#(wrongPrev)","recorded_at_ms":\#(OpenSSLChain.ms2),"revision":2,"toml_base64":"\#(b64(OpenSSLChain.toml2))"}"#,
        ].joined(separator: "\n") + "\n"
        let tip = #"{"mac":"\#(Log.tipMAC(revision: 2, tip: mac2, keyBytes: key))","revision":2,"tip":"\#(mac2)"}"#
        #expect(throws: TypedRuleStoreError.logCorrupted) {
            try Log.verify(logBytes: Data(log.utf8), tipBytes: Data(tip.utf8), keyBytes: key)
        }
    }

    @Test func verifyRejectsHonestlySealedTipForAnEarlierRecord() {
        // The tip MAC is valid but pins record 1's MAC while the log ends at
        // record 2, so only the tip-equals-head check can refuse it.
        let key = Self.key
        let tip = #"{"mac":"\#(Log.tipMAC(revision: 2, tip: OpenSSLChain.mac1, keyBytes: key))","revision":2,"tip":"\#(OpenSSLChain.mac1)"}"#
        #expect(throws: TypedRuleStoreError.logCorrupted) {
            try Log.verify(logBytes: opensslLogBytes(), tipBytes: Data(tip.utf8), keyBytes: key)
        }
    }

    // MARK: Missing log

    @Test func classifyAbsentTable() throws {
        #expect(try Log.classifyAbsent(policyFileExists: false, remnantExists: false).records.isEmpty)
        #expect(throws: TypedRuleStoreError.logMissing) {
            try Log.classifyAbsent(policyFileExists: true, remnantExists: false)
        }
        #expect(throws: TypedRuleStoreError.logMissing) {
            try Log.classifyAbsent(policyFileExists: true, remnantExists: true)
        }
        #expect(throws: TypedRuleStoreError.logCorrupted) {
            try Log.classifyAbsent(policyFileExists: false, remnantExists: true)
        }
    }

    // MARK: Generations, display agreement, reconcile, rollback

    private func displayEntry(
        _ revision: Int, toml: String, ms: Int64
    ) throws -> PolicyRevision {
        let document = try PolicyDocumentTOML.parse(toml)
        return PolicyRevision(
            revision: revision,
            hash: PolicyRevisionIdentity.hash(document),
            ruleCount: document.rules.count,
            recordedAt: Log.date(ms: ms),
            toml: toml,
            document: document
        )
    }

    /// r1 = toml1, r2 = toml1 again (identical re-save), r3 = toml2.
    private func duplicateChain() throws -> Log.VerifiedChain {
        try chain([
            (OpenSSLChain.toml1, OpenSSLChain.ms1),
            (OpenSSLChain.toml1, OpenSSLChain.ms1 + 1),
            (OpenSSLChain.toml2, OpenSSLChain.ms2),
        ])
    }

    @Test func generationsCompressIdenticalResaves() throws {
        let chain = try duplicateChain()
        #expect(chain.records.map(\.revision) == [1, 2, 3])
        #expect(chain.generations.map(\.revision) == [1, 3])
    }

    @Test func checkDisplayAcceptsMatchingGenerations() throws {
        try Log.checkDisplay(
            try duplicateChain(),
            matches: [
                try displayEntry(1, toml: OpenSSLChain.toml1, ms: OpenSSLChain.ms1),
                try displayEntry(2, toml: OpenSSLChain.toml2, ms: OpenSSLChain.ms2),
            ]
        )
        try Log.checkDisplay(.fresh, matches: [])
    }

    @Test func checkDisplayEmptyAgainstSealedHistoryIsMissing() throws {
        #expect(throws: TypedRuleStoreError.logMissing) {
            try Log.checkDisplay(try duplicateChain(), matches: [])
        }
    }

    @Test func checkDisplayDisagreementIsCorrupted() throws {
        let chain = try duplicateChain()
        let good1 = try displayEntry(1, toml: OpenSSLChain.toml1, ms: OpenSSLChain.ms1)
        let good2 = try displayEntry(2, toml: OpenSSLChain.toml2, ms: OpenSSLChain.ms2)
        let wrongTime = try displayEntry(2, toml: OpenSSLChain.toml2, ms: OpenSSLChain.ms2 + 1)
        let wrongToml = try displayEntry(2, toml: OpenSSLChain.toml1, ms: OpenSSLChain.ms2)
        var wrongHash = good2
        wrongHash.hash = "00"
        for display in [[good1], [good1, good2, good2], [good1, wrongTime], [good1, wrongToml], [good1, wrongHash]] {
            #expect(throws: TypedRuleStoreError.logCorrupted) {
                try Log.checkDisplay(chain, matches: display)
            }
        }
    }

    @Test func reconcileSealsExactlyTheLiveTail() throws {
        let chain = try chain([(OpenSSLChain.toml1, OpenSSLChain.ms1)])
        let first = try displayEntry(1, toml: OpenSSLChain.toml1, ms: OpenSSLChain.ms1)
        let tail = try displayEntry(2, toml: OpenSSLChain.toml2, ms: OpenSSLChain.ms2)

        #expect(
            Log.reconcile(chain, display: [first, tail], liveTOML: OpenSSLChain.toml2)
                == .sealTail(toml: OpenSSLChain.toml2, recordedAtMs: OpenSSLChain.ms2)
        )
        #expect(Log.reconcile(chain, display: [first, tail], liveTOML: OpenSSLChain.toml1) == .unchanged)
        #expect(Log.reconcile(chain, display: [first, tail], liveTOML: nil) == .unchanged)
        #expect(Log.reconcile(chain, display: [first], liveTOML: OpenSSLChain.toml1) == .unchanged)
        #expect(Log.reconcile(chain, display: [], liveTOML: OpenSSLChain.toml2) == .unchanged)
        let forgedHead = try displayEntry(1, toml: OpenSSLChain.toml1, ms: OpenSSLChain.ms1 + 5)
        #expect(
            Log.reconcile(chain, display: [forgedHead, tail], liveTOML: OpenSSLChain.toml2) == .unchanged
        )
        #expect(Log.reconcile(chain, display: [first, tail, tail], liveTOML: OpenSSLChain.toml2) == .unchanged)
    }

    @Test func rollbackTargetUsesGenerationNumbering() throws {
        let chain = try duplicateChain()
        let first = try Log.rollbackTarget(generation: 1, in: chain)
        #expect(first.target.revision == 1)
        #expect(first.sealedHead.revision == 3)
        let second = try Log.rollbackTarget(generation: 2, in: chain)
        #expect(second.target.revision == 3)
        for bad in [0, -1, 3, 99] {
            #expect(throws: TypedRuleStoreError.revisionNotFound) {
                try Log.rollbackTarget(generation: bad, in: chain)
            }
        }
        #expect(throws: TypedRuleStoreError.revisionNotFound) {
            try Log.rollbackTarget(generation: 1, in: .fresh)
        }
    }

    // MARK: Timestamps

    @Test func millisecondsRoundNotTruncate() {
        #expect(Log.ms(of: Date(timeIntervalSince1970: 1.0006)) == 1001)
        #expect(Log.ms(of: Date(timeIntervalSince1970: 1.0004)) == 1000)
        #expect(Log.ms(of: Log.date(ms: 1_794_264_550_029)) == 1_794_264_550_029)
    }

    // MARK: Injected clock through the store

    @Test func injectedClockStampsBothLogsWithOneInstant() throws {
        let root = try temporaryConfigDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let instant = Log.date(ms: OpenSSLChain.ms1)
        let store = TypedRuleStore(baseDirectory: root, now: { instant })

        try store.saveMachine(try PolicyDocumentTOML.parse(OpenSSLChain.toml1))
        try store.saveMachine(try PolicyDocumentTOML.parse(OpenSSLChain.toml2))

        let history = try store.listMachineRevisions()
        #expect(history.map(\.recordedAt) == [instant, instant])
        let sealed = try Log.verify(
            logBytes: try Data(contentsOf: RVPolicyPaths.policyRevisionLogFile(inConfigDir: root)),
            tipBytes: try Data(contentsOf: RVPolicyPaths.policyRevisionLogTipFile(inConfigDir: root)),
            keyBytes: try Data(contentsOf: RVPolicyPaths.policyRevisionLogKeyFile(inConfigDir: root))
        )
        #expect(sealed.records.map(\.recordedAtMs) == [OpenSSLChain.ms1, OpenSSLChain.ms1])
    }
}

private func opensslLog() -> String {
    func line(_ revision: Int, prev: String, ms: Int64, toml: String, mac: String) -> String {
        let b64 = Data(toml.utf8).base64EncodedString()
        return #"{"mac":"\#(mac)","prev":"\#(prev)","recorded_at_ms":\#(ms),"revision":\#(revision),"toml_base64":"\#(b64)"}"#
    }
    return [
        line(1, prev: "genesis", ms: OpenSSLChain.ms1, toml: OpenSSLChain.toml1, mac: OpenSSLChain.mac1),
        line(2, prev: OpenSSLChain.mac1, ms: OpenSSLChain.ms2, toml: OpenSSLChain.toml2, mac: OpenSSLChain.mac2),
    ].joined(separator: "\n") + "\n"
}

private func opensslTip() -> String {
    #"{"mac":"\#(OpenSSLChain.tipMAC)","revision":2,"tip":"\#(OpenSSLChain.mac2)"}"#
}
