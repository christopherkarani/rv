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
    func line(_ revision: Int, prev: String, ms: Int64, toml: String, mac: String) -> String {
        let b64 = Data(toml.utf8).base64EncodedString()
        return #"{"mac":"\#(mac)","prev":"\#(prev)","recorded_at_ms":\#(ms),"revision":\#(revision),"toml_base64":"\#(b64)"}"#
    }
    let log = [
        line(1, prev: "genesis", ms: OpenSSLChain.ms1, toml: OpenSSLChain.toml1, mac: OpenSSLChain.mac1),
        line(2, prev: OpenSSLChain.mac1, ms: OpenSSLChain.ms2, toml: OpenSSLChain.toml2, mac: OpenSSLChain.mac2),
    ].joined(separator: "\n") + "\n"
    let tip = #"{"mac":"\#(OpenSSLChain.tipMAC)","revision":2,"tip":"\#(OpenSSLChain.mac2)"}"#
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
