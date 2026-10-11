import Foundation
import Testing
import RVDomain
@testable import RVHistory
@testable import RVFileStore

struct SecretsAuditRecordsTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func principal() -> SecretsAuditPrincipal {
        SecretsAuditPrincipal(
            instanceID: AgentInstanceID(
                rawValue: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
            ),
            definitionID: "claude",
            ownerUID: 501
        )
    }

    private func address() throws -> MCPToolAddress {
        try MCPToolAddress.parse("tools.github.user.default.search")
    }

    private func record(
        executionID: SecretsExecutionID = SecretsExecutionID(),
        timestamp: Date = Date(timeIntervalSince1970: 1_800_000_000),
        kind: SecretsAuditKind = .secretResolve,
        decision: SecretsAuditDecision = .resolved,
        cause: SecretsAuditCause? = nil
    ) throws -> SecretsAuditRecord {
        SecretsAuditRecord(
            executionID: executionID,
            timestamp: timestamp,
            principal: principal(),
            kind: kind,
            addressOrRef: .secret(provider: "file", item: "api-token", field: nil),
            decision: decision,
            correlationID: SecretsCorrelationID(),
            cause: cause
        )
    }

    private func makeDir(prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func encode(_ record: SecretsAuditRecord) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        return try #require(String(data: data, encoding: .utf8))
    }

    private func decode(_ line: String) throws -> SecretsAuditRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SecretsAuditRecord.self, from: Data(line.utf8))
    }

    // MARK: - ID taxonomy (T0c)

    @Test func executionIDs_mintUnique() {
        #expect(SecretsExecutionID() != SecretsExecutionID())
        var seen: Set<SecretsExecutionID> = []
        for _ in 0..<256 {
            seen.insert(SecretsExecutionID())
        }
        #expect(seen.count == 256)
    }

    @Test func correlationIDs_mintUnique() {
        #expect(SecretsCorrelationID() != SecretsCorrelationID())
    }

    @Test func idTypes_areDistinct() {
        let uuid = UUID()
        let execution = SecretsExecutionID(rawValue: uuid)
        let correlation = SecretsCorrelationID(rawValue: uuid)
        #expect(String(describing: type(of: execution)) != String(describing: type(of: correlation)))
        #expect(AnyHashable(execution) != AnyHashable(correlation))
    }

    @Test(
        arguments: [
            "11111111-1111-1111-1111-111111111111",
            "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
        ]
    )
    func executionID_validatingRoundTrips(text: String) {
        let id = SecretsExecutionID(validating: text)
        #expect(id?.rawValue.uuidString == text.uppercased())
    }

    @Test(
        arguments: [
            "",
            "not-a-uuid",
            "11111111-1111-1111-1111-11111111111",
            "11111111-1111-1111-1111-111111111111-extra",
            "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
            " 11111111-1111-1111-1111-111111111111 ",
        ]
    )
    func executionID_rejectsMalformed(text: String) {
        #expect(SecretsExecutionID(validating: text) == nil)
        #expect(SecretsCorrelationID(validating: text) == nil)
    }

    @Test func correlationID_validatingRoundTrips() {
        let text = "22222222-2222-2222-2222-222222222222"
        #expect(SecretsCorrelationID(validating: text)?.rawValue.uuidString == text.uppercased())
    }

    @Test func idCodable_rejectsInvalidStrings() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SecretsExecutionID.self, from: Data(#""nope""#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SecretsCorrelationID.self, from: Data(#""nope""#.utf8))
        }
    }

    // MARK: - Kind and decision vocabularies

    @Test(
        arguments: [
            (SecretsAuditKind.secretResolve, "secret.resolve"),
            (.toolDispatch, "tool.dispatch"),
            (.toolApproval, "tool.approval"),
            (.toolOutcome, "tool.outcome"),
        ]
    )
    func kind_wireNamesMatchSpec(kind: RVFileStore.SecretsAuditKind, wire: String) throws {
        #expect(kind.rawValue == wire)
        let encoded = try JSONEncoder().encode(kind)
        #expect(String(data: encoded, encoding: .utf8) == "\"\(wire)\"")
        #expect(try JSONDecoder().decode(SecretsAuditKind.self, from: encoded) == kind)
    }

    @Test func kind_rejectsUnknown() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SecretsAuditKind.self, from: Data(#""secret.read""#.utf8))
        }
    }

    @Test(arguments: SecretsAuditDecision.allCases)
    func decision_roundTrips(decision: RVFileStore.SecretsAuditDecision) throws {
        let encoded = try JSONEncoder().encode(decision)
        #expect(try JSONDecoder().decode(SecretsAuditDecision.self, from: encoded) == decision)
    }

    @Test func decision_rejectsUnknown() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SecretsAuditDecision.self, from: Data(#""maybe""#.utf8))
        }
    }

    // MARK: - Record shape and labels-only proof

    @Test func record_jsonlBytesMatchGolden() throws {
        let record = SecretsAuditRecord(
            executionID: SecretsExecutionID(
                rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
            ),
            timestamp: Self.now,
            principal: principal(),
            kind: .secretResolve,
            addressOrRef: .secret(provider: "file", item: "api-token", field: nil),
            decision: .resolved,
            correlationID: SecretsCorrelationID(
                rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
            )
        )
        let golden =
            #"{"addressOrRef":{"item":"api-token","kind":"secret","provider":"file"},"correlationId":"22222222-2222-2222-2222-222222222222","decision":"resolved","executionId":"11111111-1111-1111-1111-111111111111","kind":"secret.resolve","principal":{"definitionID":"claude","instanceID":"33333333-3333-3333-3333-333333333333","ownerUID":501},"timestamp":"2027-01-15T08:00:00Z"}"#
        #expect(try encode(record) == golden)
        #expect(try decode(golden) == record)
    }

    @Test func record_jsonHoldsLabelsOnly() throws {
        let ref = try SecretRef(provider: "file", item: "api-token", field: "token")
        let record = SecretsAuditRecord.secretResolve(
            executionID: SecretsExecutionID(),
            timestamp: Self.now,
            principal: principal(),
            ref: ref,
            decision: .resolved,
            correlationID: SecretsCorrelationID()
        )
        let line = try encode(record)
        #expect(line.contains("hunter2-live-secret") == false)
        #expect(line.contains("api-token"))
        #expect(line.contains("\"executionId\""))
        #expect(line.contains("\"correlationId\""))
        #expect(line.contains("executionID") == false)
    }

    @Test func addressOrRef_secretLabelsRoundTrip() throws {
        let ref = try SecretRef(provider: "vault-http", item: "db creds", field: "password")
        let record = SecretsAuditRecord.secretResolve(
            executionID: SecretsExecutionID(),
            timestamp: Self.now,
            principal: principal(),
            ref: ref,
            decision: .denied,
            correlationID: SecretsCorrelationID()
        )
        let decoded = try decode(encode(record))
        #expect(decoded.addressOrRef == .secret(provider: "vault-http", item: "db creds", field: "password"))
    }

    @Test func addressOrRef_toolLiteralRoundTripsDotTolerantSegment() throws {
        let address = try MCPToolAddress.parse("tools.github.org.main.my.tool.v2")
        let record = SecretsAuditRecord.toolDispatch(
            executionID: SecretsExecutionID(),
            timestamp: Self.now,
            principal: principal(),
            address: address,
            decision: .allowed,
            correlationID: SecretsCorrelationID()
        )
        let decoded = try decode(encode(record))
        #expect(decoded.addressOrRef == .tool(address))
        #expect(try encode(record).contains("tools.github.org.main.my.tool.v2"))
    }

    @Test func addressOrRef_rejectsUnknownKind() throws {
        let line =
            #"{"addressOrRef":{"kind":"host"},"correlationId":"22222222-2222-2222-2222-222222222222","decision":"resolved","executionId":"11111111-1111-1111-1111-111111111111","kind":"secret.resolve","principal":{"definitionID":"claude","instanceID":"33333333-3333-3333-3333-333333333333","ownerUID":501},"timestamp":"2027-01-15T08:00:00Z"}"#
        #expect(throws: DecodingError.self) { try decode(line) }
    }

    @Test func addressOrRef_toleratesMalformedToolLiteralCarryingRaw() throws {
        // The invoker audits the raw attempted literal when parsing fails;
        // the shared record carries it verbatim instead of failing the row.
        let line =
            #"{"addressOrRef":{"address":"nope","kind":"tool"},"correlationId":"22222222-2222-2222-2222-222222222222","decision":"allowed","executionId":"11111111-1111-1111-1111-111111111111","kind":"tool.dispatch","principal":{"definitionID":"claude","instanceID":"33333333-3333-3333-3333-333333333333","ownerUID":501},"timestamp":"2027-01-15T08:00:00Z"}"#
        let record = try decode(line)
        #expect(record.addressOrRef == .toolRaw("nope"))
        #expect(try decode(encode(record)) == record)
        #expect(try encode(record).contains(#""address":"nope""#))
    }

    @Test func principal_rejectsMalformedInstanceID() throws {
        let line =
            #"{"addressOrRef":{"item":"api-token","kind":"secret","provider":"file"},"correlationId":"22222222-2222-2222-2222-222222222222","decision":"resolved","executionId":"11111111-1111-1111-1111-111111111111","kind":"secret.resolve","principal":{"definitionID":"claude","instanceID":"nope","ownerUID":501},"timestamp":"2027-01-15T08:00:00Z"}"#
        #expect(throws: DecodingError.self) { try decode(line) }
    }

    @Test func principal_fromTrustedContextCarriesLabelsOnly() throws {
        let instance = AgentInstance(
            id: AgentInstanceID(rawValue: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!),
            owner: OwnerPrincipal(uid: 501),
            definitionID: AgentDefinitionID(rawValue: "claude"),
            definitionRevision: AgentDefinitionRevision(digestHex: "abc123"),
            workspaceSessionID: WorkspaceSessionID(),
            runtimeSessionID: RuntimeSessionID(),
            executableEvidence: .none,
            assurance: .launchObserved,
            groupLeader: RuntimeChildIdentity(pid: 100),
            workloadProcess: nil,
            parent: nil,
            effectiveAuthority: AgentAuthority(scopes: ["fs.read"]),
            delegableAuthority: AgentAuthority(scopes: ["fs.read"]),
            mintedAt: Date(timeIntervalSince1970: 0)
        )
        let context = AuthenticatedAgentContext(instance: instance, validity: .active)
        let principal = SecretsAuditPrincipal(context: context)
        #expect(principal.instanceID == instance.id)
        #expect(principal.definitionID == "claude")
        #expect(principal.ownerUID == 501)
        let record = SecretsAuditRecord.toolOutcome(
            executionID: SecretsExecutionID(),
            timestamp: Self.now,
            principal: principal,
            address: try address(),
            decision: .succeeded,
            correlationID: SecretsCorrelationID()
        )
        let line = try encode(record)
        #expect(line.contains("fs.read") == false)
        #expect(line.contains("abc123") == false)
    }

    @Test(
        arguments: [
            (SecretsAuditKind.secretResolve, "secretResolve"),
            (.toolDispatch, "toolDispatch"),
            (.toolApproval, "toolApproval"),
            (.toolOutcome, "toolOutcome"),
        ]
    )
    func factories_tagKind(kind: RVFileStore.SecretsAuditKind, _: String) throws {
        let ref = try SecretRef(provider: "file", item: "api-token")
        let address = try address()
        let executionID = SecretsExecutionID()
        let correlationID = SecretsCorrelationID()
        let built: SecretsAuditRecord
        switch kind {
        case .secretResolve:
            built = .secretResolve(
                executionID: executionID, timestamp: Self.now, principal: principal(),
                ref: ref, decision: .resolved, correlationID: correlationID
            )
        case .toolDispatch:
            built = .toolDispatch(
                executionID: executionID, timestamp: Self.now, principal: principal(),
                address: address, decision: .allowed, correlationID: correlationID
            )
        case .toolApproval:
            built = .toolApproval(
                executionID: executionID, timestamp: Self.now, principal: principal(),
                address: address, decision: .approved, correlationID: correlationID
            )
        case .toolOutcome:
            built = .toolOutcome(
                executionID: executionID, timestamp: Self.now, principal: principal(),
                address: address, decision: .succeeded, correlationID: correlationID
            )
        }
        #expect(built.kind == kind)
        #expect(built.executionID == executionID)
        #expect(built.correlationID == correlationID)
        #expect(built.cause == nil)
    }

    // MARK: - Cause redaction via the ReviewSanitizer rulebook

    @Test func cause_redactsBearerToken() {
        let cause = SecretsAuditCause(redacting: "provider said no: Bearer abc123-def456")
        #expect(cause.redacted.contains("abc123-def456") == false)
        #expect(cause.redacted.contains("[redacted]"))
    }

    @Test func cause_redactsPEMBlock() {
        let cause = SecretsAuditCause(redacting: "key was -----BEGIN PRIVATE KEY----- MIIB")
        #expect(cause.redacted == "[redacted]")
    }

    @Test(
        arguments: [
            "key ghp_abc123def456",
            "key sk-live-51H7x9Q2mZ8",
            "key AKIAIOSFODNN7EXAMPLE",
            "key github_pat_22AbCDeFgHiJk",
        ]
    )
    func cause_redactsSecretPrefixes(raw: String) {
        let token = raw.split(separator: " ").last.map(String.init) ?? raw
        let cause = SecretsAuditCause(redacting: raw)
        #expect(cause.redacted.contains(token) == false)
        #expect(cause.redacted.contains("[redacted]"))
    }

    @Test func cause_redactsAssignmentKeepingLabel() {
        let cause = SecretsAuditCause(redacting: "login failed password=hunter2")
        #expect(cause.redacted.contains("hunter2") == false)
        #expect(cause.redacted.contains("password=[redacted]"))
    }

    @Test func cause_keepsBenignTextVerbatim() {
        let raw = "connection refused by vault.example:8200 after 3 tries"
        #expect(SecretsAuditCause(redacting: raw).redacted == raw)
    }

    @Test(
        arguments: [
            (SecretsError.invalidRef("vault-http"), "invalidRef:vault-http"),
            (.notFound("file"), "notFound:file"),
            (.denied("keychain"), "denied:keychain"),
            (.identityRequired, "identityRequired"),
            (.leaseExpired("vault-http"), "leaseExpired:vault-http"),
            (.providerDown("vault-http"), "providerDown:vault-http"),
            (.oversized("file"), "oversized:file"),
            (.policyDenied, "policyDenied"),
            (.timeout("vault-http"), "timeout:vault-http"),
        ]
    )
    func cause_errorTaxonomyNamesProviderOnly(error: SecretsError, label: String) {
        let cause = SecretsAuditCause(error)
        #expect(cause.redacted == label)
        #expect(cause.redacted.contains("sekret-item") == false)
        #expect(cause.redacted.contains("sekret-field") == false)
    }

    @Test func cause_truncatesPastCapWithMarker() {
        let raw = String(repeating: "a", count: SecretsAuditCause.maxLength + 500)
        let cause = SecretsAuditCause(redacting: raw)
        #expect(cause.redacted.hasSuffix("...[truncated]"))
        #expect(cause.redacted.count == SecretsAuditCause.maxLength + "...[truncated]".count)
        let short = String(repeating: "b", count: SecretsAuditCause.maxLength)
        #expect(SecretsAuditCause(redacting: short).redacted == short)
    }

    @Test func cause_roundTripsVerbatim() throws {
        let cause = SecretsAuditCause(redacting: "denied by policy password=hunter2")
        let data = try JSONEncoder().encode(cause)
        #expect(try JSONDecoder().decode(SecretsAuditCause.self, from: data) == cause)
    }

    // MARK: - Opaque defect (REQ-015)

    @Test func opaqueDefect_roundTripsCorrelationID() {
        let id = SecretsCorrelationID()
        let message = SecretsAuditOpaqueDefect.message(correlationID: id)
        #expect(message == "Internal tool error [\(id.rawValue.uuidString)]")
        #expect(SecretsAuditOpaqueDefect.correlationID(from: message) == id)
    }

    @Test(
        arguments: [
            "",
            "Internal tool error",
            "Internal tool error []",
            "Internal tool error [not-a-uuid]",
            "Internal tool error [[22222222-2222-2222-2222-222222222222]]",
            "boom [22222222-2222-2222-2222-222222222222] extra [33333333-3333-3333-3333-333333333333]",
        ]
    )
    func opaqueDefect_rejectsMalformed(message: String) {
        #expect(SecretsAuditOpaqueDefect.correlationID(from: message) == nil)
    }

    // MARK: - Store: append, read, restart durability

    @Test func append_thenRecordsNewestFirst() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SecretsAuditStore(configDirectory: dir)
        let first = try record(timestamp: Self.now)
        let second = try record(timestamp: Self.now.addingTimeInterval(10))
        try store.append(first, now: Self.now)
        try store.append(second, now: Self.now)
        let rows = store.records(asOf: Self.now)
        #expect(rows.count == 2)
        #expect(rows[0] == second)
        #expect(rows[1] == first)
    }

    @Test func append_survivesRestart() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let executionID = SecretsExecutionID()
        try SecretsAuditStore(configDirectory: dir).append(
            record(executionID: executionID), now: Self.now
        )
        let reopened = SecretsAuditStore(configDirectory: dir)
        let rows = reopened.records(asOf: Self.now)
        #expect(rows.count == 1)
        #expect(rows[0].executionID == executionID)
    }

    @Test func records_forExecutionFilters() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SecretsAuditStore(configDirectory: dir)
        let wanted = SecretsExecutionID()
        try store.append(record(executionID: wanted), now: Self.now)
        try store.append(record(), now: Self.now)
        try store.append(record(executionID: wanted), now: Self.now)
        let rows = store.records(for: wanted, asOf: Self.now)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.executionID == wanted })
    }

    @Test func records_missingFileIsEmptyAndCreatesNothing() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-secrets-audit-\(UUID().uuidString)", isDirectory: true)
        let store = SecretsAuditStore(configDirectory: dir)
        #expect(store.records(asOf: Self.now) == [])
        #expect(FileManager.default.fileExists(atPath: dir.path) == false)
    }

    @Test func records_corruptFileReadsEmptyThenAppendPreserves() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SecretsAuditPaths(configDirectory: dir)
        try Data("not-json-at-all{{{".utf8).write(to: paths.fileURL)
        let store = SecretsAuditStore(configDirectory: dir)
        #expect(store.records(asOf: Self.now) == [])
        let row = try record()
        try store.append(row, now: Self.now)
        #expect(store.records(asOf: Self.now) == [row])
        // Hot appends never rewrite: the undecodable bytes survive.
        let text = try String(contentsOf: paths.fileURL, encoding: .utf8)
        #expect(text.contains("not-json-at-all{{{"))
    }

    @Test func load_skipsTornLinesKeepingValidRows() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SecretsAuditPaths(configDirectory: dir)
        let keeper = try record()
        var bytes = Data()
        bytes += Data((try encode(keeper) + "\n").utf8)
        bytes += Data("{\"truncated\": \n".utf8)
        bytes += Data([0xFF, 0xFE, 0x0A])
        bytes += Data("   \n".utf8)
        bytes += Data((try encode(record()) + "\n").utf8)
        try bytes.write(to: paths.fileURL)
        let rows = SecretsAuditStore(configDirectory: dir).records(asOf: Self.now)
        #expect(rows.count == 2)
        #expect(rows.contains(keeper))
    }

    @Test func load_skipsUnknownKindLine() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SecretsAuditPaths(configDirectory: dir)
        let keeper = try record()
        let bad =
            #"{"addressOrRef":{"item":"x","kind":"secret","provider":"file"},"correlationId":"22222222-2222-2222-2222-222222222222","decision":"resolved","executionId":"11111111-1111-1111-1111-111111111111","kind":"secret.read","principal":{"definitionID":"c","instanceID":"33333333-3333-3333-3333-333333333333","ownerUID":501},"timestamp":"2027-01-15T08:00:00Z"}"#
        try Data((try encode(keeper) + "\n" + bad + "\n").utf8).write(to: paths.fileURL)
        let rows = SecretsAuditStore(configDirectory: dir).records(asOf: Self.now)
        #expect(rows == [keeper])
    }

    @Test func append_unicodeAndHostileLabelsRoundTrip() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SecretsAuditStore(configDirectory: dir)
        let row = SecretsAuditRecord(
            executionID: SecretsExecutionID(),
            timestamp: Self.now,
            principal: principal(),
            kind: .secretResolve,
            addressOrRef: .secret(
                provider: "file",
                item: "tok\"en\n$(rm -rf ~)🔑'",
                field: "a\tb"
            ),
            decision: .resolved,
            correlationID: SecretsCorrelationID()
        )
        try store.append(row, now: Self.now)
        #expect(store.records(asOf: Self.now) == [row])
    }

    @Test func append_isSerializedAcrossConcurrentWriters() async throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SecretsAuditStore(configDirectory: dir)
        let count = 50
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<count {
                group.addTask {
                    try store.append(record(), now: Self.now)
                }
            }
            try await group.waitForAll()
        }
        #expect(store.records(asOf: Self.now).count == count)
    }

    @Test func append_blockedDirectoryFailsClosed() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let blocker = dir.appendingPathComponent("blocker", isDirectory: false)
        try Data("i am a file, not a directory".utf8).write(to: blocker)
        let store = SecretsAuditStore(configDirectory: blocker)
        #expect(throws: SecretsAuditError.ioFailed) {
            try store.append(record(), now: Self.now)
        }
    }

    @Test func append_lockPathIsDirectoryDeniesWithLockFailed() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: SecretsAuditPaths(configDirectory: dir).lockURL,
            withIntermediateDirectories: true
        )
        let store = SecretsAuditStore(configDirectory: dir)
        #expect(throws: SecretsAuditError.lockFailed) {
            try store.append(record(), now: Self.now)
        }
        #expect(store.records(asOf: Self.now) == [])
    }

    @Test func rotate_blockedDirectoryFailsClosed() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let blocker = dir.appendingPathComponent("blocker", isDirectory: false)
        try Data("i am a file, not a directory".utf8).write(to: blocker)
        #expect(throws: SecretsAuditError.ioFailed) {
            try SecretsAuditStore(configDirectory: blocker).rotate()
        }
    }

    @Test func purgeExpired_blockedDirectoryFailsClosed() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let blocker = dir.appendingPathComponent("blocker", isDirectory: false)
        try Data("i am a file, not a directory".utf8).write(to: blocker)
        #expect(throws: SecretsAuditError.ioFailed) {
            try SecretsAuditStore(configDirectory: blocker).purgeExpired(now: Self.now)
        }
    }

    @Test func purgeExpired_tempPathIsDirectoryFailsClosed() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SecretsAuditPaths(configDirectory: dir)
        let store = SecretsAuditStore(configDirectory: dir)
        let row = try record()
        try store.append(row, now: Self.now)
        try FileManager.default.createDirectory(at: paths.tempURL, withIntermediateDirectories: true)
        #expect(throws: SecretsAuditError.ioFailed) {
            try store.purgeExpired(now: Self.now)
        }
        #expect(store.records(asOf: Self.now) == [row])
    }

    // MARK: - Store: paths and owner-only permissions

    @Test func paths_layoutMatchesDenialLedgerConvention() {
        let root = URL(fileURLWithPath: "/tmp/rv-config", isDirectory: true)
        let paths = SecretsAuditPaths(configDirectory: root)
        #expect(paths.fileURL.lastPathComponent == "secrets-audit.jsonl")
        #expect(paths.lockURL.lastPathComponent == "secrets-audit.lock")
        #expect(paths.tempURL.lastPathComponent == "secrets-audit.jsonl.tmp")
        #expect(paths.rotatedURL(generation: 1).lastPathComponent == "secrets-audit.1.jsonl")
        #expect(paths.rotatedURL(generation: 3).lastPathComponent == "secrets-audit.3.jsonl")
        let names = paths.uninstallArtifacts.map(\.lastPathComponent)
        #expect(names.contains("secrets-audit.jsonl"))
        #expect(names.contains("secrets-audit.lock"))
        #expect(names.contains("secrets-audit.jsonl.tmp"))
    }

    @Test func store_configDirectoryInitPointsAtLedgerFile() {
        let dir = URL(fileURLWithPath: "/tmp/rv-config", isDirectory: true)
        #expect(SecretsAuditStore(configDirectory: dir).fileURL.lastPathComponent == "secrets-audit.jsonl")
    }

    @Test func append_setsOwnerOnlyPermissions() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SecretsAuditStore(configDirectory: dir)
        try store.append(record(), now: Self.now)
        #expect(store.hasOwnerOnlyPermissions())
        let fileMode = try #require(
            FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        )
        #expect(fileMode & 0o777 == 0o600)
        let dirMode = try #require(
            FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        )
        #expect(dirMode & 0o777 == 0o700)
        #expect(FileManager.default.fileExists(atPath: SecretsAuditPaths(configDirectory: dir).lockURL.path))
    }

    @Test func permissions_missingDirectoryReportsFalse() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-secrets-audit-\(UUID().uuidString)", isDirectory: true)
        #expect(SecretsAuditStore(configDirectory: dir).hasOwnerOnlyPermissions() == false)
    }

    @Test func permissions_looseDirectoryReportsFalse() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        #expect(SecretsAuditStore(configDirectory: dir).hasOwnerOnlyPermissions() == false)
    }

    @Test func permissions_looseHotFileReportsFalse() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SecretsAuditStore(configDirectory: dir)
        try store.append(record(), now: Self.now)
        #expect(store.hasOwnerOnlyPermissions())
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.fileURL.path)
        #expect(store.hasOwnerOnlyPermissions() == false)
    }

    @Test func permissions_widenedRotatedGenerationReportsFalse() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SecretsAuditPaths(configDirectory: dir)
        let store = SecretsAuditStore(configDirectory: dir)
        try store.append(record(), now: Self.now)
        #expect(try store.rotate() == true)
        #expect(store.hasOwnerOnlyPermissions())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: paths.rotatedURL(generation: 1).path
        )
        #expect(store.hasOwnerOnlyPermissions() == false)
    }

    // MARK: - Store: retention and pruning

    @Test func pruned_dropsOlderThanWindowAndCapsRows() throws {
        let retention = SecretsAuditRetention(maxRows: 3, maxAge: 100, maxBytes: 1_000_000, maxGenerations: 0)
        let store = SecretsAuditStore(
            fileURL: URL(fileURLWithPath: "/tmp/secrets-audit.jsonl"),
            retention: retention
        )
        var records: [SecretsAuditRecord] = [
            try record(timestamp: Self.now.addingTimeInterval(-10_000))
        ]
        for index in 0..<5 {
            records.append(try record(timestamp: Self.now.addingTimeInterval(TimeInterval(index))))
        }
        let kept = store.pruned(records, now: Self.now.addingTimeInterval(5))
        #expect(kept.count == 3)
        #expect(kept.allSatisfy { $0.timestamp >= Self.now.addingTimeInterval(5).addingTimeInterval(-100) })
        #expect(kept.map(\.timestamp) == kept.map(\.timestamp).sorted())
    }

    @Test func pruned_boundaryTimestampIsKept() throws {
        let retention = SecretsAuditRetention(maxRows: 10, maxAge: 100, maxBytes: 1_000_000, maxGenerations: 0)
        let store = SecretsAuditStore(
            fileURL: URL(fileURLWithPath: "/tmp/secrets-audit.jsonl"),
            retention: retention
        )
        let edge = try record(timestamp: Self.now.addingTimeInterval(-100))
        #expect(store.pruned([edge], now: Self.now) == [edge])
    }

    @Test func pruned_ordersTiesDeterministically() throws {
        let store = SecretsAuditStore(fileURL: URL(fileURLWithPath: "/tmp/secrets-audit.jsonl"))
        let first = SecretsExecutionID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let second = SecretsExecutionID(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
        let rows = [
            try record(executionID: second, timestamp: Self.now, kind: .toolOutcome),
            try record(executionID: first, timestamp: Self.now, kind: .toolOutcome),
            try record(executionID: first, timestamp: Self.now, kind: .secretResolve),
        ]
        let kept = store.pruned(rows, now: Self.now)
        #expect(kept.map(\.executionID) == [first, first, second])
        #expect(kept[0].kind == .secretResolve)
        #expect(kept[1].kind == .toolOutcome)
    }

    @Test func append_enforcesMaxRowsOnWrite() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let retention = SecretsAuditRetention(maxRows: 5, maxAge: 1_000_000, maxBytes: 1_000_000, maxGenerations: 0)
        let store = SecretsAuditStore(configDirectory: dir, retention: retention)
        for index in 0..<8 {
            try store.append(record(timestamp: Self.now.addingTimeInterval(TimeInterval(index))), now: Self.now)
        }
        let rows = store.records(asOf: Self.now)
        #expect(rows.count == 5)
        #expect(rows[0].timestamp == Self.now.addingTimeInterval(7))
        #expect(rows[4].timestamp == Self.now.addingTimeInterval(3))
    }

    @Test func append_backdatedRowThrowsRowExpired() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let retention = SecretsAuditRetention(maxRows: 100, maxAge: 100, maxBytes: 1_000_000, maxGenerations: 0)
        let store = SecretsAuditStore(configDirectory: dir, retention: retention)
        #expect(throws: SecretsAuditError.rowExpired) {
            try store.append(record(timestamp: Self.now.addingTimeInterval(-101)), now: Self.now)
        }
        #expect(store.records(asOf: Self.now) == [])
        let edge = try record(timestamp: Self.now.addingTimeInterval(-100))
        try store.append(edge, now: Self.now)
        #expect(store.records(asOf: Self.now) == [edge])
    }

    @Test func append_rowDisplacedByNewerRowsThrowsRowExpired() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let retention = SecretsAuditRetention(maxRows: 2, maxAge: 1_000_000, maxBytes: 1_000_000, maxGenerations: 0)
        let store = SecretsAuditStore(configDirectory: dir, retention: retention)
        try store.append(record(timestamp: Self.now.addingTimeInterval(1)), now: Self.now)
        try store.append(record(timestamp: Self.now.addingTimeInterval(2)), now: Self.now)
        #expect(throws: SecretsAuditError.rowExpired) {
            try store.append(record(timestamp: Self.now), now: Self.now)
        }
        #expect(store.records(asOf: Self.now).count == 2)
    }

    @Test func append_exactFitBudgetSucceeds() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let row = try record()
        let line = try encode(row)
        let retention = SecretsAuditRetention(
            maxRows: 100, maxAge: 1_000_000, maxBytes: line.utf8.count + 1, maxGenerations: 0
        )
        let store = SecretsAuditStore(
            fileURL: SecretsAuditPaths(configDirectory: dir).fileURL, retention: retention
        )
        try store.append(row, now: Self.now)
        #expect(store.records(asOf: Self.now) == [row])
    }

    @Test func retention_validatedClampsFloors() {
        let clamped = SecretsAuditRetention(maxRows: 0, maxAge: 0, maxBytes: 0, maxGenerations: -2).validated()
        #expect(clamped.maxRows == 1)
        #expect(clamped.maxAge == 1)
        #expect(clamped.maxBytes == 64)
        #expect(clamped.maxGenerations == 0)
        #expect(SecretsAuditRetention.default.validated() == SecretsAuditRetention.default)
    }

    @Test func purgeExpired_dropsStaleRowsWithoutAppending() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let retention = SecretsAuditRetention(maxRows: 100, maxAge: 100, maxBytes: 1_000_000, maxGenerations: 0)
        let store = SecretsAuditStore(configDirectory: dir, retention: retention)
        try store.append(record(timestamp: Self.now), now: Self.now)
        try store.purgeExpired(now: Self.now.addingTimeInterval(10_000))
        #expect(store.records(asOf: Self.now.addingTimeInterval(10_000)) == [])
    }

    @Test func purgeExpired_emptyStoreSucceeds() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SecretsAuditStore(configDirectory: dir)
        try store.purgeExpired(now: Self.now)
        #expect(store.records(asOf: Self.now) == [])
    }

    @Test func maintenance_purgePreservesUndecodableLines() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SecretsAuditPaths(configDirectory: dir)
        let store = SecretsAuditStore(configDirectory: dir)
        let keeper = try record(timestamp: Self.now)
        try store.append(keeper, now: Self.now)
        // A newer producer's unknown kind plus a torn write, appended
        // raw as the file would carry them.
        let unknownKind =
            #"{"addressOrRef":{"item":"x","kind":"secret","provider":"file"},"correlationId":"22222222-2222-2222-2222-222222222222","decision":"resolved","executionId":"11111111-1111-1111-1111-111111111111","kind":"secret.read","principal":{"definitionID":"c","instanceID":"33333333-3333-3333-3333-333333333333","ownerUID":501},"timestamp":"2027-01-15T08:00:00Z"}"#
        let handle = try FileHandle(forWritingTo: paths.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((unknownKind + "\n").utf8))
        try handle.write(contentsOf: Data("{\"truncated\": \n".utf8))
        try handle.close()
        try store.purgeExpired(now: Self.now)
        #expect(store.records(asOf: Self.now) == [keeper])
        let text = try String(contentsOf: paths.fileURL, encoding: .utf8)
        #expect(text.contains(unknownKind))
        #expect(text.contains(#"{"truncated": "#))
    }

    // MARK: - Store: rotation and ledger-full deny

    @Test func rotate_movesHotToGenerationOne() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SecretsAuditPaths(configDirectory: dir)
        let store = SecretsAuditStore(configDirectory: dir)
        let row = try record()
        try store.append(row, now: Self.now)
        #expect(try store.rotate() == true)
        #expect(FileManager.default.fileExists(atPath: paths.fileURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: paths.rotatedURL(generation: 1).path))
        #expect(store.records(asOf: Self.now) == [])
        #expect(store.recordsIncludingRotated(asOf: Self.now) == [row])
        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: paths.rotatedURL(generation: 1).path)[.posixPermissions]
                as? Int
        )
        #expect(mode & 0o777 == 0o600)
    }

    @Test func rotate_shiftsGenerationsAndDeletesBeyondCap() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SecretsAuditPaths(configDirectory: dir)
        let retention = SecretsAuditRetention(maxRows: 100, maxAge: 1_000_000, maxBytes: 1_000_000, maxGenerations: 2)
        let store = SecretsAuditStore(configDirectory: dir, retention: retention)
        let first = try record(timestamp: Self.now)
        let second = try record(timestamp: Self.now.addingTimeInterval(1))
        let third = try record(timestamp: Self.now.addingTimeInterval(2))
        try store.append(first, now: Self.now)
        try store.rotate()
        try store.append(second, now: Self.now)
        try store.rotate()
        try store.append(third, now: Self.now)
        try store.rotate()
        #expect(FileManager.default.fileExists(atPath: paths.rotatedURL(generation: 3).path) == false)
        #expect(store.recordsIncludingRotated(asOf: Self.now) == [third, second])
    }

    @Test func rotate_disabledReturnsFalseWithoutTouchingDisk() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let retention = SecretsAuditRetention(maxRows: 100, maxAge: 1_000_000, maxBytes: 1_000_000, maxGenerations: 0)
        let store = SecretsAuditStore(configDirectory: dir, retention: retention)
        let row = try record()
        try store.append(row, now: Self.now)
        #expect(try store.rotate() == false)
        #expect(store.records(asOf: Self.now) == [row])
        let gen1 = SecretsAuditPaths(configDirectory: dir).rotatedURL(generation: 1)
        #expect(FileManager.default.fileExists(atPath: gen1.path) == false)
    }

    @Test func rotate_missingFileReturnsFalse() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try SecretsAuditStore(configDirectory: dir).rotate() == false)
    }

    @Test func append_rotatesAutomaticallyWhenOverBudget() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SecretsAuditPaths(configDirectory: dir)
        let first = try record(timestamp: Self.now)
        try SecretsAuditStore(configDirectory: dir).append(first, now: Self.now)
        let size = try #require(
            FileManager.default.attributesOfItem(atPath: paths.fileURL.path)[.size] as? Int
        )
        let tight = SecretsAuditRetention(maxRows: 100, maxAge: 1_000_000, maxBytes: size + 10, maxGenerations: 2)
        let store = SecretsAuditStore(configDirectory: dir, retention: tight)
        let second = try record(timestamp: Self.now.addingTimeInterval(1))
        try store.append(second, now: Self.now)
        #expect(FileManager.default.fileExists(atPath: paths.rotatedURL(generation: 1).path))
        #expect(store.records(asOf: Self.now) == [second])
        #expect(store.recordsIncludingRotated(asOf: Self.now) == [second, first])
    }

    @Test func append_ledgerFullWhenRotationDisabled() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SecretsAuditPaths(configDirectory: dir)
        let first = try record(timestamp: Self.now)
        try SecretsAuditStore(configDirectory: dir).append(first, now: Self.now)
        let size = try #require(
            FileManager.default.attributesOfItem(atPath: paths.fileURL.path)[.size] as? Int
        )
        let tight = SecretsAuditRetention(maxRows: 100, maxAge: 1_000_000, maxBytes: size + 10, maxGenerations: 0)
        let store = SecretsAuditStore(configDirectory: dir, retention: tight)
        #expect(throws: SecretsAuditError.ledgerFull) {
            try store.append(record(timestamp: Self.now.addingTimeInterval(1)), now: Self.now)
        }
        #expect(store.records(asOf: Self.now) == [first])
    }

    @Test func append_singleRowOverBudgetDeniesEvenWithRotation() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let retention = SecretsAuditRetention(maxRows: 100, maxAge: 1_000_000, maxBytes: 200, maxGenerations: 3)
        let store = SecretsAuditStore(configDirectory: dir, retention: retention)
        #expect(throws: SecretsAuditError.ledgerFull) {
            try store.append(record(), now: Self.now)
        }
        #expect(store.records(asOf: Self.now) == [])
    }

    @Test func ledgerFull_recoversAfterPurgeExpired() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SecretsAuditPaths(configDirectory: dir)
        try SecretsAuditStore(configDirectory: dir).append(record(timestamp: Self.now), now: Self.now)
        let size = try #require(
            FileManager.default.attributesOfItem(atPath: paths.fileURL.path)[.size] as? Int
        )
        let tight = SecretsAuditRetention(maxRows: 100, maxAge: 100, maxBytes: size + 10, maxGenerations: 0)
        let store = SecretsAuditStore(configDirectory: dir, retention: tight)
        #expect(throws: SecretsAuditError.ledgerFull) {
            try store.append(record(timestamp: Self.now.addingTimeInterval(50)), now: Self.now)
        }
        try store.purgeExpired(now: Self.now.addingTimeInterval(10_000))
        let fresh = try record(timestamp: Self.now.addingTimeInterval(10_000))
        try store.append(fresh, now: Self.now.addingTimeInterval(10_000))
        #expect(store.records(asOf: Self.now.addingTimeInterval(10_000)) == [fresh])
    }

    @Test func recordsIncludingRotated_respectsRetentionOnUnion() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let retention = SecretsAuditRetention(maxRows: 100, maxAge: 100, maxBytes: 1_000_000, maxGenerations: 2)
        let store = SecretsAuditStore(configDirectory: dir, retention: retention)
        try store.append(record(timestamp: Self.now), now: Self.now)
        try store.rotate()
        let fresh = try record(timestamp: Self.now.addingTimeInterval(50))
        try store.append(fresh, now: Self.now)
        let rows = store.recordsIncludingRotated(asOf: Self.now.addingTimeInterval(500))
        #expect(rows == [])
        let freshOnly = store.recordsIncludingRotated(asOf: Self.now.addingTimeInterval(60))
        #expect(freshOnly.count == 2)
    }

    @Test func recordsIncludingRotated_skipsTornLinesInGenerations() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SecretsAuditPaths(configDirectory: dir)
        let store = SecretsAuditStore(configDirectory: dir)
        let keeper = try record()
        try store.append(keeper, now: Self.now)
        #expect(try store.rotate() == true)
        let handle = try FileHandle(forWritingTo: paths.rotatedURL(generation: 1))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"truncated\": \n".utf8))
        try handle.close()
        #expect(store.recordsIncludingRotated(asOf: Self.now) == [keeper])
    }

    @Test func recordsIncludingRotated_ignoresGenerationsWhenDisabled() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SecretsAuditStore(configDirectory: dir)
        try store.append(record(), now: Self.now)
        #expect(try store.rotate() == true)
        let retention = SecretsAuditRetention(maxRows: 100, maxAge: 1_000_000, maxBytes: 1_000_000, maxGenerations: 0)
        let noGens = SecretsAuditStore(configDirectory: dir, retention: retention)
        #expect(noGens.recordsIncludingRotated(asOf: Self.now) == [])
    }

    @Test func recordsIncludingRotated_survivesRestart() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let row = try record()
        try SecretsAuditStore(configDirectory: dir).append(row, now: Self.now)
        #expect(try SecretsAuditStore(configDirectory: dir).rotate() == true)
        let reopened = SecretsAuditStore(configDirectory: dir)
        #expect(reopened.recordsIncludingRotated(asOf: Self.now) == [row])
    }

    @Test func rotate_skipsMissingMiddleGeneration() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SecretsAuditPaths(configDirectory: dir)
        let store = SecretsAuditStore(configDirectory: dir)
        let first = try record(timestamp: Self.now)
        let second = try record(timestamp: Self.now.addingTimeInterval(1))
        let third = try record(timestamp: Self.now.addingTimeInterval(2))
        try store.append(first, now: Self.now)
        #expect(try store.rotate() == true)
        try store.append(second, now: Self.now)
        #expect(try store.rotate() == true)
        try FileManager.default.removeItem(at: paths.rotatedURL(generation: 1))
        try store.append(third, now: Self.now)
        #expect(try store.rotate() == true)
        #expect(FileManager.default.fileExists(atPath: paths.rotatedURL(generation: 1).path))
        #expect(FileManager.default.fileExists(atPath: paths.rotatedURL(generation: 2).path) == false)
        #expect(FileManager.default.fileExists(atPath: paths.rotatedURL(generation: 3).path))
        #expect(store.recordsIncludingRotated(asOf: Self.now) == [third, first])
    }

    // MARK: - Pending-approval reuse (no second mechanism)

    @Test func approvalDecision_mapsEveryStoreState() throws {
        let awaiting = try Self.createdApproval()
        #expect(SecretsAuditRecord.approvalDecision(for: awaiting.record) == .pendingApproval)

        let allowed = try PendingApprovalLedger.resolve(
            records: awaiting.records, id: awaiting.record.id, decision: .allowOnce,
            fingerprint: Self.approvalFingerprint, identity: Self.approvalIdentity, now: Self.now
        )
        #expect(SecretsAuditRecord.approvalDecision(for: allowed.0) == .approved)

        let ruled = try Self.createdApproval(id: "ask-rule")
        let created = try PendingApprovalLedger.resolve(
            records: ruled.records, id: ruled.record.id, decision: .createRule,
            fingerprint: Self.approvalFingerprint, identity: Self.approvalIdentity, now: Self.now
        )
        #expect(SecretsAuditRecord.approvalDecision(for: created.0) == .approved)

        let denied = try Self.createdApproval(id: "ask-deny")
        let refused = try PendingApprovalLedger.resolve(
            records: denied.records, id: denied.record.id, decision: .deny,
            fingerprint: Self.approvalFingerprint, identity: Self.approvalIdentity, now: Self.now
        )
        #expect(SecretsAuditRecord.approvalDecision(for: refused.0) == .declined)
        let consumed = try PendingApprovalLedger.consume(
            records: refused.1, id: denied.record.id,
            fingerprint: Self.approvalFingerprint, identity: Self.approvalIdentity, now: Self.now
        )
        #expect(SecretsAuditRecord.approvalDecision(for: consumed.0.approval) == .consumed)

        let expiring = try Self.createdApproval(id: "ask-expire")
        let expired = try PendingApprovalLedger.expire(
            records: expiring.records, id: expiring.record.id, now: Self.now
        )
        #expect(SecretsAuditRecord.approvalDecision(for: expired.0) == .expired)

        let canceling = try Self.createdApproval(id: "ask-cancel")
        let canceled = try PendingApprovalLedger.cancel(
            records: canceling.records, id: canceling.record.id, now: Self.now
        )
        #expect(SecretsAuditRecord.approvalDecision(for: canceled.0) == .canceled)

        let timingOut = try Self.createdApproval(id: "ask-timeout")
        let swept = PendingApprovalLedger.sweep(timingOut.records, now: Self.now.addingTimeInterval(3600))
        let timedOut = try #require(swept.first)
        #expect(SecretsAuditRecord.approvalDecision(for: timedOut) == .timedOut)
    }

    @Test func approvalLink_joinsOnlyMatchingStoreKey() throws {
        let executionID = SecretsExecutionID()
        let matching = try Self.createdApproval(id: executionID.rawValue.uuidString)
        let link = SecretsAuditApprovalLink(executionID: executionID, approval: matching.record)
        #expect(link?.executionID == executionID)
        #expect(link?.approvalID == SecretsAuditApprovalLink.storeKey(for: executionID))

        let other = try Self.createdApproval(id: "ask-other")
        #expect(SecretsAuditApprovalLink(executionID: executionID, approval: other.record) == nil)
        #expect(SecretsAuditApprovalLink(executionID: SecretsExecutionID(), approval: matching.record) == nil)
    }

    @Test func approvalLink_storeKeyRoundTrips() {
        let executionID = SecretsExecutionID()
        let key = SecretsAuditApprovalLink.storeKey(for: executionID)
        #expect(key.rawValue == executionID.rawValue.uuidString)
        #expect(SecretsExecutionID(validating: key.rawValue) == executionID)
    }

    @Test func ledger_holdsNoSecondPendingMechanism() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SecretsAuditStore(configDirectory: dir)
        let executionID = SecretsExecutionID()
        let created = try Self.createdApproval(id: executionID.rawValue.uuidString)
        let resolved = try PendingApprovalLedger.resolve(
            records: created.records, id: created.record.id, decision: .allowOnce,
            fingerprint: Self.approvalFingerprint, identity: Self.approvalIdentity, now: Self.now
        )
        let row = SecretsAuditRecord.toolApproval(
            executionID: executionID,
            timestamp: Self.now,
            principal: principal(),
            address: try address(),
            decision: SecretsAuditRecord.approvalDecision(for: resolved.0),
            correlationID: SecretsCorrelationID()
        )
        try store.append(row, now: Self.now)
        let bytes = try Data(
            contentsOf: SecretsAuditPaths(configDirectory: dir).fileURL
        )
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(text.contains("tool.approval"))
        #expect(text.contains("awaitingHuman") == false)
        #expect(text.contains("timeoutPolicy") == false)
        #expect(text.contains("continuation") == false)
        #expect(text.contains("expiresAt") == false)
        #expect(text.contains("payloadDigest") == false)
    }

    // MARK: - Off-host ship planner

    @Test func ship_batchesOldestFirstAndAdvancesCursor() throws {
        var rows: [SecretsAuditRecord] = []
        for index in 0..<5 {
            rows.append(try record(timestamp: Self.now.addingTimeInterval(TimeInterval(index))))
        }
        let first = SecretsAuditShipper.plan(records: rows, after: nil, batchSize: 2)
        #expect(first.lines.count == 2)
        let firstCursor = try #require(first.nextCursor)
        #expect(firstCursor.timestamp == Self.now.addingTimeInterval(1))
        let second = SecretsAuditShipper.plan(records: rows, after: firstCursor, batchSize: 2)
        #expect(second.lines.count == 2)
        let secondCursor = try #require(second.nextCursor)
        let third = SecretsAuditShipper.plan(records: rows, after: secondCursor, batchSize: 2)
        #expect(third.lines.count == 1)
        let caughtUp = SecretsAuditShipper.plan(
            records: rows, after: third.nextCursor, batchSize: 2
        )
        #expect(caughtUp.lines == [])
        #expect(caughtUp.nextCursor == nil)
        let shipped = try (first.lines + second.lines + third.lines).map(decode)
        #expect(shipped.map(\.timestamp) == shipped.map(\.timestamp).sorted())
    }

    @Test func ship_skipsNothingAcrossSameTimestampCollisions() throws {
        let executionID = SecretsExecutionID()
        let rows = try SecretsAuditKind.allCases.map { kind in
            try record(executionID: executionID, timestamp: Self.now, kind: kind)
        }
        let shipment = SecretsAuditShipper.plan(records: rows, after: nil, batchSize: 10)
        #expect(shipment.lines.count == 4)
        let cursor = try #require(shipment.nextCursor)
        let caughtUp = SecretsAuditShipper.plan(records: rows, after: cursor, batchSize: 10)
        #expect(caughtUp.lines == [])
    }

    @Test func ship_shipsDuplicateKeyRowsAcrossBatches() throws {
        let executionID = SecretsExecutionID()
        let first = try record(executionID: executionID, timestamp: Self.now, decision: .resolved)
        let second = try record(executionID: executionID, timestamp: Self.now, decision: .denied)
        let rows = [first, second]
        let one = SecretsAuditShipper.plan(records: rows, after: nil, batchSize: 1)
        #expect(one.lines.count == 1)
        let cursor = try #require(one.nextCursor)
        #expect(cursor.duplicateIndex == 0)
        let two = SecretsAuditShipper.plan(records: rows, after: cursor, batchSize: 1)
        #expect(two.lines.count == 1)
        let shipped = try (one.lines + two.lines).map(decode)
        #expect(shipped == [first, second])
        let done = SecretsAuditShipper.plan(records: rows, after: two.nextCursor, batchSize: 1)
        #expect(done.lines == [])
        #expect(done.nextCursor == nil)
    }

    @Test func ship_sortsUnsortedInputOldestFirst() throws {
        var rows: [SecretsAuditRecord] = []
        for index in 0..<5 {
            rows.append(try record(timestamp: Self.now.addingTimeInterval(TimeInterval(index))))
        }
        let shipment = SecretsAuditShipper.plan(
            records: Array(rows.reversed()), after: nil, batchSize: 10
        )
        #expect(shipment.lines.count == 5)
        let shipped = try shipment.lines.map(decode)
        #expect(shipped.map(\.timestamp) == shipped.map(\.timestamp).sorted())
    }

    @Test func ship_legacyCursorWithoutDuplicateIndexDecodesAsZero() throws {
        let payload = """
            {"executionID":"11111111-1111-1111-1111-111111111111","kind":"secret.resolve","timestamp":1800000000}
            """
        let cursor = try JSONDecoder().decode(SecretsAuditShipCursor.self, from: Data(payload.utf8))
        #expect(cursor.duplicateIndex == 0)
        #expect(cursor.kind == .secretResolve)
    }

    @Test func ship_linesDecodeBackWithRedactedCausesOnly() throws {
        let raw = "vault login failed password=hunter2-live"
        let row = try record(cause: SecretsAuditCause(redacting: raw))
        let shipment = SecretsAuditShipper.plan(records: [row], after: nil, batchSize: 10)
        #expect(shipment.lines.count == 1)
        let line = try #require(shipment.lines.first)
        #expect(line.contains("hunter2-live") == false)
        #expect(line.contains("password=[redacted]"))
        #expect(try decode(line) == row)
    }

    @Test func ship_clampsBatchSize() throws {
        let rows = try [record(), record(), record()]
        #expect(SecretsAuditShipper.plan(records: rows, after: nil, batchSize: 0).lines.count == 1)
        #expect(SecretsAuditShipper.plan(records: rows, after: nil, batchSize: 5000).lines.count == 3)
    }

    @Test func ship_cursorRoundTrips() throws {
        let cursor = SecretsAuditShipCursor(record: try record())
        let data = try JSONEncoder().encode(cursor)
        #expect(try JSONDecoder().decode(SecretsAuditShipCursor.self, from: data) == cursor)
    }

    @Test func ship_cursorStableAcrossRotation() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SecretsAuditStore(configDirectory: dir)
        for index in 0..<4 {
            try store.append(
                record(timestamp: Self.now.addingTimeInterval(TimeInterval(index))),
                now: Self.now
            )
        }
        // Ship the first half from the hot file.
        let hot = Array(store.records(asOf: Self.now).reversed())
        let first = SecretsAuditShipper.plan(records: hot, after: nil, batchSize: 2)
        #expect(first.lines.count == 2)
        let cursor = try #require(first.nextCursor)
        // Rotate mid-stream and keep appending: the cursor resumes on
        // the union without skipping or duplicating a row.
        #expect(try store.rotate() == true)
        for index in 4..<6 {
            try store.append(
                record(timestamp: Self.now.addingTimeInterval(TimeInterval(index))),
                now: Self.now
            )
        }
        let union = Array(store.recordsIncludingRotated(asOf: Self.now).reversed())
        #expect(union.count == 6)
        let rest = SecretsAuditShipper.plan(records: union, after: cursor, batchSize: 10)
        let shipped = try rest.lines.map(decode)
        #expect(shipped.count == 4)
        let firstShipped = try first.lines.map(decode)
        #expect(Set(firstShipped + shipped).count == 6)
        let done = SecretsAuditShipper.plan(records: union, after: rest.nextCursor, batchSize: 10)
        #expect(done.lines == [])
        #expect(done.nextCursor == nil)
    }

    @Test func shipConfig_validatedClampsAndLocalOnlyHasNoEndpoint() {
        #expect(SecretsAuditShipConfig.localOnly.endpoint == nil)
        #expect(SecretsAuditShipConfig(endpoint: nil, batchSize: 0).validated().batchSize == 1)
        #expect(SecretsAuditShipConfig(endpoint: nil, batchSize: 5000).validated().batchSize == 1000)
        let endpoint = URL(string: "https://audit.example/ship")!
        let remote = SecretsAuditShipConfig(endpoint: endpoint, batchSize: 100).validated()
        #expect(remote.endpoint == endpoint)
        #expect(remote.batchSize == 100)
    }

    // MARK: - Stress: synthetic execution lifecycles

    @Test func stress_fullLifecyclesPersistAndOrderNewestFirst() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SecretsAuditStore(configDirectory: dir)
        let executions = (0..<10).map { _ in SecretsExecutionID() }
        let kinds: [SecretsAuditKind] = [.secretResolve, .toolDispatch, .toolApproval, .toolOutcome]
        var tick = 0
        for execution in executions {
            for round in 0..<50 {
                let kind = kinds[round % kinds.count]
                let decision: SecretsAuditDecision
                switch kind {
                case .secretResolve: decision = .resolved
                case .toolDispatch: decision = .pendingApproval
                case .toolApproval: decision = .approved
                case .toolOutcome: decision = .succeeded
                }
                try store.append(
                    record(
                        executionID: execution,
                        timestamp: Self.now.addingTimeInterval(TimeInterval(tick)),
                        kind: kind,
                        decision: decision
                    ),
                    now: Self.now
                )
                tick += 1
            }
        }
        let rows = store.records(asOf: Self.now)
        #expect(rows.count == 500)
        let stamps = rows.map(\.timestamp)
        #expect(stamps == stamps.sorted(by: >))
        for execution in executions {
            #expect(store.records(for: execution, asOf: Self.now).count == 50)
        }
        let reopened = SecretsAuditStore(configDirectory: dir)
        #expect(reopened.records(asOf: Self.now).count == 500)
    }
}

private extension SecretsAuditRecordsTests {
    static let approvalFingerprint = ActionFingerprint(rawValue: "shell:git.force-push:origin:main")
    static let approvalIdentity = ApprovalIdentity(
        session: SessionID(validating: "sess-1")!,
        agent: .pi
    )

    static func approvalAction() -> ProposedAction {
        .shell(
            ShellAction.effectOnly(
                EffectShell(
                    fingerprint: approvalFingerprint,
                    effects: ActionEffects(kinds: [.remoteSharedBranchMutation]),
                    resources: .git(
                        remote: RemoteName("origin"),
                        ref: .branch(BranchName("main"))
                    ),
                    scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/rv"))
                )
            )
        )
    }

    static func createdApproval(
        id: String = "ask-1",
        timeoutPolicy: ApprovalTimeoutPolicy = .autoDeny
    ) throws -> (record: PendingApproval, records: [PendingApproval]) {
        try PendingApprovalLedger.create(
            records: [],
            request: PendingApprovalRequest(
                id: ApprovalID(rawValue: id),
                identity: approvalIdentity,
                action: approvalAction(),
                reason: .mandatoryHuman,
                continuation: .hostNative,
                timeoutPolicy: timeoutPolicy,
                ttl: 60
            ),
            now: now
        )
    }

#if canImport(Darwin)
    // User-immutable files fail rename(2) with EPERM even for the owner, which
    // is the only deterministic trigger for the rotation-failure path:
    // withLock restores directory writability by design, so permission tricks
    // cannot work. Linux has no unprivileged immutable equivalent; the shared
    // code path is pinned here on macOS.
    @Test func rotate_immutableHotFileFailsClosed() throws {
        let dir = try makeDir(prefix: "rv-secrets-audit")
        let hot = SecretsAuditPaths(configDirectory: dir).fileURL
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: hot.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let retention = SecretsAuditRetention(maxRows: 100, maxAge: 1_000_000, maxBytes: 1_000_000, maxGenerations: 1)
        let store = SecretsAuditStore(configDirectory: dir, retention: retention)
        try store.append(record(timestamp: Self.now), now: Self.now)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: hot.path)
        #expect(throws: SecretsAuditError.ioFailed) {
            try store.rotate()
        }
        #expect(store.records(asOf: Self.now).count == 1)
    }
#endif
}
