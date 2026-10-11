#if os(macOS)
import Darwin
import Foundation
import RVDomain
import RVFileStore
import Testing
@testable import RVIsolation

private func spawnBrokerEntry(
    provider: String = "file",
    item: String = "github",
    field: String? = nil,
    env: String,
    agents: [String]? = nil
) -> RuntimeResourceProfile.BrokerEntry {
    RuntimeResourceProfile.BrokerEntry(
        provider: provider, item: item, field: field, env: env, agents: agents
    )
}

private func spawnBrokerProfile(
    secrets: [RuntimeResourceProfile.BrokerEntry],
    credentials: [RuntimeResourceProfile.Credential] = [],
    environment: [RuntimeResourceProfile.Environment] = []
) -> RuntimeResourceProfile {
    RuntimeResourceProfile(
        id: "spawn-broker", projects: ["/tmp/spawn-broker-project"],
        credentials: credentials, environment: environment, secrets: secrets
    )
}

private func spawnBrokerScratch(prefix: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// E1-B spawn-path staging injection: `broker:` env threading, stage
/// payload capture + merge, and best-effort staging-drop audit.
@Suite("Spawn broker staging")
struct SessionSupervisorBrokerTests {
    @Test func brokerPairsInjectIntoSpawnedEnvironment() {
        let values = containedRuntimeEnvironment(
            workspace: "/tmp/ws", io: .inherit,
            hostEnvironment: [:],
            broker: [(name: "SYNTHETIC_BROKER_ONE", value: "broker-alpha")]
        )
        #expect(values.contains("SYNTHETIC_BROKER_ONE=broker-alpha"))
    }

    @Test func brokerPairsMatchKeychainLoopExactly() {
        // The shared loop filters identically no matter which batch the
        // pairs arrive in: NUL-bearing and oversized values never
        // inject, exact-cap values do.
        let pairs: [(name: String, value: String)] = [
            (name: "SYNTHETIC_BROKER_NUL", value: "a\0b"),
            (name: "SYNTHETIC_BROKER_BIG", value: String(repeating: "x", count: 8_193)),
            (name: "SYNTHETIC_BROKER_CAP", value: String(repeating: "y", count: 8_192)),
        ]
        let viaBroker = containedRuntimeEnvironment(
            workspace: "/tmp/ws", io: .inherit,
            hostEnvironment: [:], keychain: [], broker: pairs
        )
        let viaKeychain = containedRuntimeEnvironment(
            workspace: "/tmp/ws", io: .inherit,
            hostEnvironment: [:], keychain: pairs, broker: []
        )
        #expect(viaBroker == viaKeychain)
        #expect(viaBroker.allSatisfy { !$0.hasPrefix("SYNTHETIC_BROKER_NUL=") })
        #expect(viaBroker.allSatisfy { !$0.hasPrefix("SYNTHETIC_BROKER_BIG=") })
        #expect(viaBroker.contains("SYNTHETIC_BROKER_CAP=" + String(repeating: "y", count: 8_192)))
    }

    @Test func brokerFirstSpellingWins() {
        let values = containedRuntimeEnvironment(
            workspace: "/tmp/ws", io: .inherit,
            hostEnvironment: [:],
            broker: [
                (name: "SYNTHETIC_BROKER_DUP", value: "first"),
                (name: "SYNTHETIC_BROKER_DUP", value: "second"),
            ]
        )
        #expect(values.contains("SYNTHETIC_BROKER_DUP=first"))
        #expect(values.filter { $0.hasPrefix("SYNTHETIC_BROKER_DUP=") }.count == 1)
    }

    @Test func keychainBeatsBrokerOnCollision() {
        // Legacy wins ties: a keychain value for a colliding name lands,
        // the broker pair does not.
        let values = containedRuntimeEnvironment(
            workspace: "/tmp/ws", io: .inherit,
            hostEnvironment: [:],
            keychain: [(name: "SYNTHETIC_CLASH", value: "keychain")],
            broker: [(name: "SYNTHETIC_CLASH", value: "broker")]
        )
        #expect(values.contains("SYNTHETIC_CLASH=keychain"))
        #expect(values.allSatisfy { $0 != "SYNTHETIC_CLASH=broker" })
    }

    @Test func profileEnvironmentBeatsBrokerOnCollision() {
        let profile = spawnBrokerProfile(
            secrets: [],
            environment: [
                RuntimeResourceProfile.Environment(
                    name: "SYNTHETIC_CLASH", literalValue: "profile"
                )
            ]
        )
        let manifest = RuntimeResourceManifest(profile)
        let values = containedRuntimeEnvironment(
            workspace: "/tmp/ws", io: .inherit,
            resources: manifest,
            hostEnvironment: [:],
            broker: [
                (name: "SYNTHETIC_CLASH", value: "broker"),
                (name: "SYNTHETIC_BROKER_OTHER", value: "kept"),
            ]
        )
        #expect(values.contains("SYNTHETIC_CLASH=profile"))
        #expect(values.allSatisfy { $0 != "SYNTHETIC_CLASH=broker" })
        #expect(values.contains("SYNTHETIC_BROKER_OTHER=kept"))
    }

    @Test func hostBeatsBrokerOnCollision() {
        // Runtime-owned and projected host names win ties: a broker
        // pair can neither hijack PATH nor shadow an inherited TERM.
        let values = containedRuntimeEnvironment(
            workspace: "/tmp/ws", io: .inherit,
            hostEnvironment: ["TERM": "host-term"],
            broker: [
                (name: "TERM", value: "broker-term"),
                (name: "PATH", value: "broker-path"),
                (name: "SYNTHETIC_BROKER_KEPT", value: "kept"),
            ]
        )
        #expect(values.contains("TERM=host-term"))
        #expect(values.allSatisfy { $0 != "TERM=broker-term" })
        #expect(values.allSatisfy { $0 != "PATH=broker-path" })
        #expect(values.filter { $0.hasPrefix("PATH=") }.count == 1)
        #expect(values.contains("SYNTHETIC_BROKER_KEPT=kept"))
    }

    @Test func explicitBrokerBeatsStagedOnCollision() {
        // The spawn body concatenates caller pairs before staged pairs,
        // so first spelling wins keeps the explicit value on a clash.
        let combined = brokerPairsForSpawn(
            explicit: [(name: "SYNTHETIC_EXPLICIT", value: "explicit")],
            staged: [
                (name: "SYNTHETIC_EXPLICIT", value: "staged"),
                (name: "SYNTHETIC_STAGED_ONLY", value: "staged"),
            ]
        )
        #expect(combined.map(\.name) == [
            "SYNTHETIC_EXPLICIT", "SYNTHETIC_EXPLICIT", "SYNTHETIC_STAGED_ONLY",
        ])
        let values = containedRuntimeEnvironment(
            workspace: "/tmp/ws", io: .inherit,
            hostEnvironment: [:], broker: combined
        )
        #expect(values.contains("SYNTHETIC_EXPLICIT=explicit"))
        #expect(values.filter { $0.hasPrefix("SYNTHETIC_EXPLICIT=") }.count == 1)
        #expect(values.contains("SYNTHETIC_STAGED_ONLY=staged"))
    }

    @Test func legacyDefaultIsByteIdentical() {
        let host = [
            "META_API_KEY": "secret",
            "ANTHROPIC_BASE_URL": "http://localhost:10000",
            "TERM": "xterm-256color",
        ]
        for io in [IsolatedIO.inherit, .pseudoTerminal(rows: 24, columns: 80)] {
            let legacy = containedRuntimeEnvironment(
                workspace: "/tmp/ws", io: io, hostEnvironment: host
            )
            let explicit = containedRuntimeEnvironment(
                workspace: "/tmp/ws", io: io, hostEnvironment: host,
                keychain: [], broker: []
            )
            #expect(legacy == explicit)
        }
    }

    @Test func stageCapturesBrokerPayload() throws {
        let entry = spawnBrokerEntry(item: "github", env: "SYNTHETIC_FIRST")
        let manifest = RuntimeResourceManifest(spawnBrokerProfile(secrets: [entry]))
        defer { manifest.remove() }
        let ref = try #require(entry.ref)
        let result = stageResourcesForSpawn(
            manifest, agentName: nil,
            brokerValues: [ref: .text("synthetic-secret")],
            brokerAuditDirectory: nil
        )
        guard case .success(let payload) = result else {
            Issue.record("staging must succeed, got \(result)")
            return
        }
        #expect(payload.map(\.name) == ["SYNTHETIC_FIRST"])
        #expect(payload.map(\.value) == ["synthetic-secret"])
    }

    @Test func nilBrokerValuesKeepsLegacyEmpty() throws {
        let entry = spawnBrokerEntry(env: "SYNTHETIC_FIRST")
        let manifest = RuntimeResourceManifest(spawnBrokerProfile(secrets: [entry]))
        defer { manifest.remove() }
        let scratch = try spawnBrokerScratch(prefix: "rv-spawn-broker-legacy")
        defer { try? FileManager.default.removeItem(at: scratch) }
        // A directory that does not exist yet: no drops means no IO, not
        // even directory creation.
        let auditDir = scratch.appendingPathComponent("audit", isDirectory: true)
        let result = stageResourcesForSpawn(
            manifest, agentName: nil, brokerValues: nil,
            brokerAuditDirectory: auditDir
        )
        guard case .success(let payload) = result else {
            Issue.record("legacy staging must succeed, got \(result)")
            return
        }
        #expect(payload.isEmpty)
        #expect(FileManager.default.fileExists(atPath: auditDir.path) == false)
    }

    @Test func stageFailureMapsToIsolationError() {
        let profile = spawnBrokerProfile(
            secrets: [],
            credentials: [
                RuntimeResourceProfile.Credential(
                    source: "/nonexistent/e1b-\(UUID().uuidString.lowercased())",
                    destination: "cred"
                )
            ]
        )
        let manifest = RuntimeResourceManifest(profile)
        defer { manifest.remove() }
        let result = stageResourcesForSpawn(
            manifest, agentName: nil, brokerValues: nil,
            brokerAuditDirectory: nil
        )
        guard case .failure(let error) = result else {
            Issue.record("broken credential must fail staging, got \(result)")
            return
        }
        #expect(error == .resourceStagingFailed("credential 'cred'"))
    }

    @Test func payloadMergesIntoSpawnedEnvironment() throws {
        // The seam the spawn body composes: the captured payload feeds
        // `broker:`, landing in the spawned environment verbatim.
        let entry = spawnBrokerEntry(item: "github", env: "SYNTHETIC_FIRST")
        let manifest = RuntimeResourceManifest(spawnBrokerProfile(secrets: [entry]))
        defer { manifest.remove() }
        let ref = try #require(entry.ref)
        let staged = stageResourcesForSpawn(
            manifest, agentName: nil,
            brokerValues: [ref: .text("synthetic-secret")],
            brokerAuditDirectory: nil
        )
        guard case .success(let payload) = staged else {
            Issue.record("staging must succeed, got \(staged)")
            return
        }
        let values = containedRuntimeEnvironment(
            workspace: "/tmp/ws", io: .inherit,
            resources: manifest,
            hostEnvironment: [:],
            broker: payload
        )
        #expect(values.contains("SYNTHETIC_FIRST=synthetic-secret"))
    }

    @Test func fileValueStagesIntoPayload() throws {
        // A `.filePath` value is copied into the 0700 home and the
        // staged path — not the bytes — flows through the payload into
        // the spawned environment.
        let scratch = try spawnBrokerScratch(prefix: "rv-spawn-broker-fileval")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("secret.txt", isDirectory: false)
        try Data("file-secret-bytes".utf8).write(to: source)
        let entry = spawnBrokerEntry(item: "github", env: "SYNTHETIC_FILEVAL")
        let manifest = RuntimeResourceManifest(spawnBrokerProfile(secrets: [entry]))
        defer { manifest.remove() }
        let ref = try #require(entry.ref)
        let staged = stageResourcesForSpawn(
            manifest, agentName: nil,
            brokerValues: [ref: .filePath(source.path)],
            brokerAuditDirectory: nil
        )
        guard case .success(let payload) = staged else {
            Issue.record("file staging must succeed, got \(staged)")
            return
        }
        let pair = try #require(payload.count == 1 ? payload[0] : nil)
        #expect(pair.name == "SYNTHETIC_FILEVAL")
        #expect(pair.value == "\(manifest.privateHome)/secrets/SYNTHETIC_FILEVAL")
        let stagedBytes = try Data(contentsOf: URL(fileURLWithPath: pair.value))
        #expect(stagedBytes == Data("file-secret-bytes".utf8))
        let values = containedRuntimeEnvironment(
            workspace: "/tmp/ws", io: .inherit,
            resources: manifest,
            hostEnvironment: [:],
            broker: payload
        )
        #expect(values.contains("\(pair.name)=\(pair.value)"))
    }
}

/// Staging-drop audit: denied rows land in the ledger with names only,
/// and a dead ledger never fails the spawn.
@Suite("Spawn broker staging audit")
struct SessionSupervisorBrokerAuditTests {
    @Test func dropsAppendDeniedRowsToLedger() throws {
        let entry = spawnBrokerEntry(item: "github", env: "SYNTHETIC_OVERSIZED")
        let manifest = RuntimeResourceManifest(spawnBrokerProfile(secrets: [entry]))
        defer { manifest.remove() }
        let ref = try #require(entry.ref)
        let scratch = try spawnBrokerScratch(prefix: "rv-spawn-broker-audit")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let auditDir = scratch.appendingPathComponent("audit", isDirectory: true)
        let staged = stageResourcesForSpawn(
            manifest, agentName: "opencode",
            brokerValues: [ref: .text(String(repeating: "v", count: 9_000))],
            brokerAuditDirectory: auditDir
        )
        guard case .success(let payload) = staged else {
            Issue.record("dropped batch must still succeed, got \(staged)")
            return
        }
        #expect(payload.isEmpty)
        let ledgerURL = auditDir.appendingPathComponent(
            "secrets-audit.jsonl", isDirectory: false
        )
        #expect(FileManager.default.fileExists(atPath: ledgerURL.path))
        let rows = SecretsLedger.loadRecords(fileURL: ledgerURL)
        let row = try #require(rows.count == 1 ? rows[0] : nil)
        #expect(row.kind == .secretResolve)
        #expect(row.decision == .denied)
        #expect(row.addressOrRef == .secret(provider: "file", item: "github", field: nil))
        #expect(row.cause?.redacted == "stagingDrop:oversized:SYNTHETIC_OVERSIZED")
        #expect(row.principal.definitionID == "opencode")
        #expect(row.principal.ownerUID == geteuid())
    }

    @Test func dropRowsCarryNamesOnly() throws {
        let marker = "e1b-distinctive-\(UUID().uuidString.lowercased())"
        let entries = [
            spawnBrokerEntry(item: "good", env: "SYNTHETIC_GOOD"),
            spawnBrokerEntry(item: "big", env: "SYNTHETIC_OVERSIZED"),
        ]
        let manifest = RuntimeResourceManifest(spawnBrokerProfile(secrets: entries))
        defer { manifest.remove() }
        let good = try #require(entries[0].ref)
        let big = try #require(entries[1].ref)
        let scratch = try spawnBrokerScratch(prefix: "rv-spawn-broker-names")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let staged = stageResourcesForSpawn(
            manifest, agentName: nil,
            brokerValues: [
                good: .text(marker),
                big: .text(String(repeating: "w", count: 9_000)),
            ],
            brokerAuditDirectory: scratch
        )
        guard case .success(let payload) = staged else {
            Issue.record("mixed batch must succeed, got \(staged)")
            return
        }
        #expect(payload.map(\.name) == ["SYNTHETIC_GOOD"])
        let ledgerURL = scratch.appendingPathComponent(
            "secrets-audit.jsonl", isDirectory: false
        )
        let raw = try String(contentsOf: ledgerURL, encoding: .utf8)
        #expect(raw.contains("stagingDrop:oversized:SYNTHETIC_OVERSIZED"))
        #expect(raw.contains("SYNTHETIC_OVERSIZED"))
        #expect(raw.contains("SYNTHETIC_GOOD") == false)
        #expect(raw.contains(marker) == false)
        #expect(raw.contains(String(repeating: "w", count: 64)) == false)
        #expect(SecretsLedger.loadRecords(fileURL: ledgerURL).count == 1)
    }

    @Test func invalidRefDropAuditsWithFallbackRef() throws {
        let entry = spawnBrokerEntry(
            provider: "bogus-provider", item: "keepme", env: "SYNTHETIC_BADREF"
        )
        #expect(entry.ref == nil)
        let manifest = RuntimeResourceManifest(spawnBrokerProfile(secrets: [entry]))
        defer { manifest.remove() }
        let scratch = try spawnBrokerScratch(prefix: "rv-spawn-broker-badref")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let staged = stageResourcesForSpawn(
            manifest, agentName: nil, brokerValues: [:],
            brokerAuditDirectory: scratch
        )
        guard case .success(let payload) = staged else {
            Issue.record("invalid-ref batch must succeed, got \(staged)")
            return
        }
        #expect(payload.isEmpty)
        let ledgerURL = scratch.appendingPathComponent(
            "secrets-audit.jsonl", isDirectory: false
        )
        let rows = SecretsLedger.loadRecords(fileURL: ledgerURL)
        let row = try #require(rows.count == 1 ? rows[0] : nil)
        #expect(row.decision == .denied)
        #expect(row.cause?.redacted == "stagingDrop:invalidRef:SYNTHETIC_BADREF")
        // The valid item label survives; only the unknown provider falls
        // back to the default.
        #expect(row.addressOrRef == .secret(provider: "file", item: "keepme", field: nil))
    }

    @Test func unresolvedDropAuditsThroughStage() throws {
        let entry = spawnBrokerEntry(item: "github", env: "SYNTHETIC_UNRESOLVED")
        let manifest = RuntimeResourceManifest(spawnBrokerProfile(secrets: [entry]))
        defer { manifest.remove() }
        _ = try #require(entry.ref)
        let scratch = try spawnBrokerScratch(prefix: "rv-spawn-broker-unresolved")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let staged = stageResourcesForSpawn(
            manifest, agentName: nil, brokerValues: [:],
            brokerAuditDirectory: scratch
        )
        guard case .success(let payload) = staged else {
            Issue.record("unresolved batch must succeed, got \(staged)")
            return
        }
        #expect(payload.isEmpty)
        let ledgerURL = scratch.appendingPathComponent(
            "secrets-audit.jsonl", isDirectory: false
        )
        let rows = SecretsLedger.loadRecords(fileURL: ledgerURL)
        let row = try #require(rows.count == 1 ? rows[0] : nil)
        #expect(row.decision == .denied)
        #expect(row.cause?.redacted == "stagingDrop:unresolved:SYNTHETIC_UNRESOLVED")
        #expect(row.addressOrRef == .secret(provider: "file", item: "github", field: nil))
    }

    @Test func nulValueDropAuditsThroughStage() throws {
        let marker = "nulval-\(UUID().uuidString.lowercased())"
        let entry = spawnBrokerEntry(item: "github", env: "SYNTHETIC_NULVAL")
        let manifest = RuntimeResourceManifest(spawnBrokerProfile(secrets: [entry]))
        defer { manifest.remove() }
        let ref = try #require(entry.ref)
        let scratch = try spawnBrokerScratch(prefix: "rv-spawn-broker-nulval")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let staged = stageResourcesForSpawn(
            manifest, agentName: nil,
            brokerValues: [ref: .text("prefix-\(marker)\0suffix")],
            brokerAuditDirectory: scratch
        )
        guard case .success(let payload) = staged else {
            Issue.record("NUL batch must succeed, got \(staged)")
            return
        }
        #expect(payload.isEmpty)
        let ledgerURL = scratch.appendingPathComponent(
            "secrets-audit.jsonl", isDirectory: false
        )
        let rows = SecretsLedger.loadRecords(fileURL: ledgerURL)
        let row = try #require(rows.count == 1 ? rows[0] : nil)
        #expect(row.decision == .denied)
        #expect(row.cause?.redacted == "stagingDrop:invalidValue:SYNTHETIC_NULVAL")
        let raw = try String(contentsOf: ledgerURL, encoding: .utf8)
        #expect(raw.contains(marker) == false)
    }

    @Test func blockedNameDropAuditsThroughStage() throws {
        let entry = spawnBrokerEntry(item: "github", env: "PATH")
        let manifest = RuntimeResourceManifest(spawnBrokerProfile(secrets: [entry]))
        defer { manifest.remove() }
        let ref = try #require(entry.ref)
        let scratch = try spawnBrokerScratch(prefix: "rv-spawn-broker-blocked")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let staged = stageResourcesForSpawn(
            manifest, agentName: nil,
            brokerValues: [ref: .text("synthetic-secret")],
            brokerAuditDirectory: scratch
        )
        guard case .success(let payload) = staged else {
            Issue.record("blocked-name batch must succeed, got \(staged)")
            return
        }
        #expect(payload.isEmpty)
        let ledgerURL = scratch.appendingPathComponent(
            "secrets-audit.jsonl", isDirectory: false
        )
        let rows = SecretsLedger.loadRecords(fileURL: ledgerURL)
        let row = try #require(rows.count == 1 ? rows[0] : nil)
        #expect(row.decision == .denied)
        #expect(row.cause?.redacted == "stagingDrop:blockedName:PATH")
        #expect(row.addressOrRef == .secret(provider: "file", item: "github", field: nil))
    }

    @Test func invalidNameDropAuditsThroughStage() throws {
        let entry = spawnBrokerEntry(item: "github", env: "9BAD")
        let manifest = RuntimeResourceManifest(spawnBrokerProfile(secrets: [entry]))
        defer { manifest.remove() }
        let ref = try #require(entry.ref)
        let scratch = try spawnBrokerScratch(prefix: "rv-spawn-broker-badname")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let staged = stageResourcesForSpawn(
            manifest, agentName: nil,
            brokerValues: [ref: .text("synthetic-secret")],
            brokerAuditDirectory: scratch
        )
        guard case .success(let payload) = staged else {
            Issue.record("invalid-name batch must succeed, got \(staged)")
            return
        }
        #expect(payload.isEmpty)
        let ledgerURL = scratch.appendingPathComponent(
            "secrets-audit.jsonl", isDirectory: false
        )
        let rows = SecretsLedger.loadRecords(fileURL: ledgerURL)
        let row = try #require(rows.count == 1 ? rows[0] : nil)
        #expect(row.decision == .denied)
        #expect(row.cause?.redacted == "stagingDrop:invalidName:9BAD")
        #expect(row.addressOrRef == .secret(provider: "file", item: "github", field: nil))
    }

    @Test func fileUnreadableDropAuditsThroughStage() throws {
        let entry = spawnBrokerEntry(item: "github", env: "SYNTHETIC_BADFILE")
        let manifest = RuntimeResourceManifest(spawnBrokerProfile(secrets: [entry]))
        defer { manifest.remove() }
        let ref = try #require(entry.ref)
        let scratch = try spawnBrokerScratch(prefix: "rv-spawn-broker-badfile")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let staged = stageResourcesForSpawn(
            manifest, agentName: nil,
            brokerValues: [ref: .filePath("/nonexistent/e1b-\(UUID().uuidString.lowercased())")],
            brokerAuditDirectory: scratch
        )
        guard case .success(let payload) = staged else {
            Issue.record("unreadable-file batch must succeed, got \(staged)")
            return
        }
        #expect(payload.isEmpty)
        let ledgerURL = scratch.appendingPathComponent(
            "secrets-audit.jsonl", isDirectory: false
        )
        let rows = SecretsLedger.loadRecords(fileURL: ledgerURL)
        let row = try #require(rows.count == 1 ? rows[0] : nil)
        #expect(row.decision == .denied)
        #expect(row.cause?.redacted == "stagingDrop:fileUnreadable:SYNTHETIC_BADFILE")
        #expect(row.addressOrRef == .secret(provider: "file", item: "github", field: nil))
    }

    @Test func ledgerFailureNeverFailsSpawn() throws {
        let entry = spawnBrokerEntry(item: "github", env: "SYNTHETIC_FIRST")
        let manifest = RuntimeResourceManifest(spawnBrokerProfile(secrets: [entry]))
        defer { manifest.remove() }
        let ref = try #require(entry.ref)
        let scratch = try spawnBrokerScratch(prefix: "rv-spawn-broker-deadledger")
        defer { try? FileManager.default.removeItem(at: scratch) }
        // A regular file where the ledger directory should be: the
        // append fails, the spawn payload must not.
        let blocker = scratch.appendingPathComponent("blocker", isDirectory: false)
        try Data("not a directory".utf8).write(to: blocker)
        let staged = stageResourcesForSpawn(
            manifest, agentName: nil,
            brokerValues: [ref: .text("synthetic-secret")],
            brokerAuditDirectory: blocker
        )
        guard case .success(let payload) = staged else {
            Issue.record("dead ledger must not fail staging, got \(staged)")
            return
        }
        #expect(payload.map(\.name) == ["SYNTHETIC_FIRST"])
        #expect(payload.map(\.value) == ["synthetic-secret"])
    }

    @Test func emptyDropsWriteNothing() throws {
        let entry = spawnBrokerEntry(item: "github", env: "SYNTHETIC_FIRST")
        let manifest = RuntimeResourceManifest(spawnBrokerProfile(secrets: [entry]))
        defer { manifest.remove() }
        let ref = try #require(entry.ref)
        let scratch = try spawnBrokerScratch(prefix: "rv-spawn-broker-nodrops")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let auditDir = scratch.appendingPathComponent("audit", isDirectory: true)
        let staged = stageResourcesForSpawn(
            manifest, agentName: nil,
            brokerValues: [ref: .text("synthetic-secret")],
            brokerAuditDirectory: auditDir
        )
        guard case .success(let payload) = staged else {
            Issue.record("clean batch must succeed, got \(staged)")
            return
        }
        #expect(payload.map(\.name) == ["SYNTHETIC_FIRST"])
        #expect(FileManager.default.fileExists(atPath: auditDir.path) == false)
    }

    @Test func stagingDropTargetFallbackArms() {
        let profile = spawnBrokerProfile(secrets: [
            spawnBrokerEntry(provider: "file", item: "github", env: "SYNTHETIC_VALID"),
            spawnBrokerEntry(
                provider: "bogus-provider", item: "keepme", field: "token",
                env: "SYNTHETIC_BADPROVIDER"
            ),
            spawnBrokerEntry(provider: "vault-http", item: "", env: "SYNTHETIC_EMPTYITEM"),
            spawnBrokerEntry(provider: "bogus-provider", item: "", env: ""),
        ])
        #expect(
            stagingDropTarget(
                BrokerStagingDrop(env: "SYNTHETIC_VALID", reason: .oversized),
                profile: profile
            ) == .secret(provider: "file", item: "github", field: nil)
        )
        // Unknown provider falls back to the default; item and field
        // survive.
        #expect(
            stagingDropTarget(
                BrokerStagingDrop(env: "SYNTHETIC_BADPROVIDER", reason: .invalidRef),
                profile: profile
            ) == .secret(provider: "file", item: "keepme", field: "token")
        )
        // Empty item falls back to the env name; the valid provider
        // survives.
        #expect(
            stagingDropTarget(
                BrokerStagingDrop(env: "SYNTHETIC_EMPTYITEM", reason: .invalidRef),
                profile: profile
            ) == .secret(provider: "vault-http", item: "SYNTHETIC_EMPTYITEM", field: nil)
        )
        // Empty env is terminal `"unknown"`.
        #expect(
            stagingDropTarget(
                BrokerStagingDrop(env: "", reason: .invalidRef),
                profile: profile
            ) == .secret(provider: "file", item: "unknown", field: nil)
        )
        // No matching entry: default provider, env name as item.
        #expect(
            stagingDropTarget(
                BrokerStagingDrop(env: "SYNTHETIC_MISSING", reason: .unresolved),
                profile: spawnBrokerProfile(secrets: [])
            ) == .secret(provider: "file", item: "SYNTHETIC_MISSING", field: nil)
        )
    }

    @Test func auditRowsShareOneExecution() {
        let profile = spawnBrokerProfile(secrets: [
            spawnBrokerEntry(item: "a", env: "SYNTHETIC_DROP_A"),
            spawnBrokerEntry(item: "b", env: "SYNTHETIC_DROP_B"),
        ])
        let drops = [
            BrokerStagingDrop(env: "SYNTHETIC_DROP_A", reason: .oversized),
            BrokerStagingDrop(env: "SYNTHETIC_DROP_B", reason: .unresolved),
        ]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let records = brokerStagingAuditRecords(
            drops, profile: profile, agentTag: "opencode", now: now
        )
        #expect(records.count == 2)
        #expect(records[0].executionID == records[1].executionID)
        #expect(records[0].correlationID == records[1].correlationID)
        #expect(records.allSatisfy { $0.timestamp == now })
        #expect(records.allSatisfy { $0.principal.definitionID == "opencode" })
        #expect(records.allSatisfy { $0.principal.ownerUID == geteuid() })
        #expect(records.allSatisfy { $0.kind == .secretResolve })
        #expect(records.allSatisfy { $0.decision == .denied })
        let legacy = brokerStagingAuditRecords(
            [drops[0]], profile: profile, agentTag: nil, now: now
        )
        #expect(legacy.count == 1)
        #expect(legacy[0].principal.definitionID == "unknown")
    }

    @Test func causeFormatPinsReasonAndEnv() {
        let reasons: [BrokerStagingDropReason] = [
            .oversized, .invalidName, .blockedName, .invalidValue,
            .invalidRef, .unresolved, .fileUnreadable,
        ]
        let drops = reasons.map {
            BrokerStagingDrop(env: "SYNTHETIC_PIN", reason: $0)
        }
        let records = brokerStagingAuditRecords(
            drops, profile: spawnBrokerProfile(secrets: []),
            agentTag: nil, now: Date()
        )
        #expect(records.count == reasons.count)
        for (record, reason) in zip(records, reasons) {
            #expect(record.cause?.redacted == "stagingDrop:\(reason.rawValue):SYNTHETIC_PIN")
        }
    }
}
#endif
