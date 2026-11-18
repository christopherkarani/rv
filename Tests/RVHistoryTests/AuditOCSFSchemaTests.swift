import Foundation
import Testing
@testable import RVHistory

/// One event of every audit kind, each shaped as its production writer
/// shapes it, run through the real OCSF mapper and checked against the
/// vendored OCSF 1.3.0 schemas (`Fixtures/ocsf-1.3.0`).
enum AuditOCSFSamples {
    static let time = Date(timeIntervalSince1970: 1_791_826_700)

    static func event(
        _ kind: AuditEventKind, _ decision: AuditDecision, _ subject: String, reason: String? = nil,
        workspace: String? = nil, runtime: String? = nil, agent: String? = nil, source: String = "audit.jsonl",
        detail: [String: String] = [:]
    ) -> AuditEvent {
        AuditEvent(
            time: time, kind: kind, decision: decision, subject: subject, reason: reason, workspace: workspace,
            runtime: runtime, agent: agent, source: source, detail: detail)
    }

    static let all: [AuditEvent] = [
        event(.commandDenied, .denied, "core.git:reset-hard", agent: "claude",
              detail: ["host": "claude", "tool": "Bash", "category": "core.git"]),
        event(.commandDenied, .denied, "core.git:reset-hard", source: "blocks.jsonl",
              detail: ["tool": "Bash", "category": "core.git"]),
        event(.commandDenied, .denied, "core.secrets:read", agent: "codex",
              detail: ["host": "codex", "tool": "Bash", "category": "ssh", "path": "~/.ssh/id_ed25519"]),
        event(.commandDenied, .denied, "core.judge:laya-block", agent: "claude",
              detail: ["host": "claude", "tool": "Bash", "category": "core.judge"]),
        event(.commandObserved, .info, "core.git:reset-hard", agent: "claude",
              detail: ["host": "claude", "tool": "Bash", "category": "core.git", "would_be": "ask"]),
        event(.commandOverride, .allowed, "core.git:reset-hard", reason: "allowOnce", workspace: "~/repo",
              agent: "claude", detail: ["host": "claude", "override": "allowOnce"]),
        event(.egressDenied, .denied, "evil.example:443", reason: "denied-policy", source: "egress-denials.jsonl"),
        event(.egressDenied, .denied, "evil.example", reason: "sni-mismatch", source: "rv mcp serve",
              detail: ["server": "fs", "suppressed": "3"]),
        event(.egressObserved, .info, "evil.example:443", reason: "denied-policy", source: "rv mcp serve",
              detail: [
                  "server": "fs", "rule": "sandbox.hosts", "enforcement": "audit", "would_be": "deny",
                  "because": "evil.example is not in fs sandbox.hosts",
              ]),
        event(.admission, .denied, "https://api.example.com/", reason: "denied", workspace: "W1", runtime: "R1",
              source: "runtime-admission.jsonl",
              detail: ["authorization": "denied", "method": "GET", "executionAttempted": "false"]),
        event(.admission, .allowed, "action", reason: "executed:0", runtime: "R1", source: "runtime-admission.jsonl",
              detail: ["authorization": "allowed", "executionAttempted": "true"]),
        event(.runtimeSession, .info, "/repo", workspace: "W1", runtime: "R1", source: "runtime-sessions.jsonl",
              detail: ["backend": "seatbelt"]),
        event(.runtimeStarted, .info, "/repo", workspace: "W1", runtime: "R1", source: "workspace-sessions.jsonl",
              detail: ["disk": "/dev/disk136s1", "processGroup": "91274"]),
        event(.runtimeEnded, .info, "/repo", reason: "timeout", workspace: "W1", runtime: "R1",
              source: "workspace-sessions.jsonl"),
        event(.workspace("created"), .info, "/repo", workspace: "W1", source: "workspace-sessions.jsonl"),
        event(.workspace("recoveryBlocked"), .failed, "/repo", reason: "busy", workspace: "W1",
              source: "workspace-sessions.jsonl"),
        event(.agent("finished"), .denied, "claude", reason: "refused:permit", workspace: "W1", runtime: "R1",
              agent: "claude", source: "agent-instances.jsonl", detail: ["instance": "I1", "revision": "r1"]),
        event(.secretUse, .info, "OPENAI_API_KEY", reason: "staged for launch", runtime: "R1",
              source: "secret-gateway", detail: ["event": "launch"]),
        event(.secretUse, .denied, "OPENAI_API_KEY", reason: "outside the secret's allow rules", runtime: "R1",
              source: "secret-gateway",
              detail: ["event": "request", "activity": "blocked", "refusal": "outsideAllowRules", "method": "POST"]),
        event(.secretMisuse, .denied, "OPENAI_API_KEY", runtime: "R1", source: "secret-gateway",
              detail: ["refusal": "foreignPlaceholder", "method": "GET", "path": "/v1", "severity": "high"]),
        event(.mcpCall, .allowed, "fs/read", source: "mcp-gateway",
              detail: ["server": "fs", "tool": "read", "policy": "allow", "argumentKeys": "path", "isError": "false"]),
    ] + MCPGatewayDenial.allCases.map {
        event(.mcpCall, .denied, "fs/write", reason: $0.reason(server: "fs", tool: "write"), source: "mcp-gateway",
              detail: ["server": "fs", "tool": "write", "policy": "deny", "argumentKeys": "", "isError": "true"])
    } + [
        event(.mcpCall, .denied, "fs/write", reason: "declined by the user", source: "mcp-gateway",
              detail: ["server": "fs", "tool": "write", "policy": "ask", "argumentKeys": "path", "isError": "true"]),
        event(.mcpCall, .pending, "fs/write", source: "mcp-gateway",
              detail: ["server": "fs", "tool": "write", "policy": "ask", "argumentKeys": "path", "isError": "false"]),
        event(.mcpApproval, .denied, "fs/write", reason: MCPAuditVocabulary.forgedGrant, source: "mcp-gateway",
              detail: ["approval": "A1"]),
        event(.mcpApproval, .allowed, "mcp.json", source: "rv mcp trust"),
        event(.mcpToolChanged, .pending, "fs", source: "mcp-gateway", detail: ["tools": "write"]),
        event(.mcpHostsUngoverned, .info, "mcp-hosts", reason: "2 servers outside the gateway", source: "rv mcp serve"),
        ConfigChangeAudit.policy(
            layer: "machine", change: "save", revision: 3, hash: "abc", ruleCount: 4,
            prior: (revision: 2, hash: "def", ruleCount: 3), direction: .loosening, time: time),
        event(.policyManaged, .failed, "organization", reason: "signature did not verify",
              detail: ["change": "invalid", "authorized_by": "none"]),
        ConfigChangeAudit.setting("safety", from: "strict", to: "standard", direction: .loosening, time: time),
        event(.ownerAction, .denied, "rv allow core.git:reset-hard", detail: ["outcome": "refused", "caller": "cli"]),
    ]
}

@Suite("AuditOCSF schema")
struct AuditOCSFSchemaTests {
    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func ocsf(_ event: AuditEvent) throws -> JSONValue {
        try JSONValue.parse(try #require(AuditOCSF.jsonLine(event, hostName: "build-host")))
    }

    @Test func everyFixedKindAndFamilyHasASample() {
        let sampled = Set(AuditOCSFSamples.all.map(\.kind))
        for kind in AuditEventKind.allCases {
            #expect(sampled.contains(kind), "no OCSF sample for \(kind.rawValue)")
        }
        #expect(sampled.contains { $0.matches("workspace") })
        #expect(sampled.contains { $0.matches("agent") })
    }

    /// `allCases` is a hand-kept list: read the declarations so a new
    /// `static let` kind that is not listed (and so has no sample) fails.
    @Test func allCasesListsEveryDeclaredKind() throws {
        let source = try String(
            contentsOf: Self.repository.appendingPathComponent("Sources/RVHistory/AuditEvent.swift"), encoding: .utf8)
        let pattern = try Regex(#"static let \w+ = AuditEventKind\(rawValue: "([^"]+)"\)"#)
        let declared = Set(source.matches(of: pattern).compactMap { $0.output[1].substring.map(String.init) })
        #expect(declared.isEmpty == false)
        #expect(declared == Set(AuditEventKind.allCases.map(\.rawValue)))
        #expect(AuditEventKind.allCases.count == declared.count)
    }

    /// Kinds are declared in one place, so the two checks above see them all.
    @Test func noKindIsMintedOutsideItsDeclaration() throws {
        let sources = Self.repository.appendingPathComponent("Sources", isDirectory: true)
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let file as URL in files where file.pathExtension == "swift" {
            guard file.lastPathComponent != "AuditEvent.swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("AuditEventKind(rawValue: \"") { offenders.append(file.lastPathComponent) }
        }
        #expect(offenders.isEmpty, "declare these kinds in AuditEvent.swift: \(offenders)")
    }

    /// Top-level attributes rv emitted before this check existed that
    /// OCSF 1.3.0 does not define for the class: 1.3.0 applies the
    /// `security_control` profile (`action`, `disposition`) to fewer classes,
    /// and API Activity has no `device`. They stay because SIEM rules read
    /// them; nothing else may appear outside the schema.
    static let knownDeviations: [String: Set<String>] = [
        "api_activity@host": ["device", "action", "action_id", "disposition", "disposition_id"],
        "application_lifecycle@host": ["action", "action_id", "disposition", "disposition_id"],
        "device_config_state_change@host": ["action", "action_id", "disposition", "disposition_id"],
        "detection_finding@host+security_control": ["is_alert"],
    ]

    static func isKnownDeviation(_ violation: OCSFSchemaValidator.Violation, stem: String) -> Bool {
        let attribute = violation.path.dropFirst()
        guard violation.path.hasPrefix("/"), attribute.contains("/") == false else { return false }
        return violation.message.hasPrefix("is not defined by the schema")
            && knownDeviations[stem]?.contains(String(attribute)) == true
    }

    @Test func everySampleValidatesAgainstTheVendoredSchema() throws {
        let validator = try OCSFSchemaValidator()
        for event in AuditOCSFSamples.all {
            let object = try ocsf(event)
            let stem = validator.schema(for: object)?.stem ?? "none"
            let violations = validator.validate(object).filter { Self.isKnownDeviation($0, stem: stem) == false }
            #expect(violations.isEmpty, "\(event.kind.rawValue) \(event.decision.rawValue): \(violations)")
        }
    }

    /// The deviation list only shrinks: an entry the mapper no longer
    /// needs fails here.
    @Test func everyKnownDeviationIsStillEmitted() throws {
        let validator = try OCSFSchemaValidator()
        var seen: [String: Set<String>] = [:]
        for event in AuditOCSFSamples.all {
            let object = try ocsf(event)
            guard let stem = validator.schema(for: object)?.stem else { continue }
            for violation in validator.validate(object) where Self.isKnownDeviation(violation, stem: stem) {
                seen[stem, default: []].insert(String(violation.path.dropFirst()))
            }
        }
        #expect(seen == Self.knownDeviations)
    }

    @Test func everyEmittedClassHasAVendoredSchema() throws {
        let validator = try OCSFSchemaValidator()
        let used = Set(try AuditOCSFSamples.all.map { try #require(validator.schema(for: try ocsf($0))?.stem) })
        #expect(used == Set(validator.schemas.keys), "vendored but unused, or used but missing: \(used)")
    }
}

/// The validator must reject what it claims to check, or a pass means nothing.
@Suite("OCSF schema validator")
struct OCSFSchemaValidatorTests {
    func sample() throws -> [String: JSONValue] {
        let line = try #require(AuditOCSF.jsonLine(AuditOCSFSamples.all[0], hostName: "h"))
        guard case .object(let fields) = try JSONValue.parse(line) else {
            Issue.record("OCSF line is not a JSON object")
            return [:]
        }
        return fields
    }

    func violations(_ fields: [String: JSONValue]) throws -> [String] {
        try OCSFSchemaValidator().validate(.object(fields)).map(\.description)
    }

    @Test func validSampleHasNoViolations() throws {
        #expect(try violations(try sample()) == [])
    }

    @Test func rejectsMissingRequiredAttribute() throws {
        var fields = try sample()
        fields["severity_id"] = nil
        #expect(try violations(fields).contains { $0.hasPrefix("/severity_id: is required") })
    }

    @Test func rejectsWrongType() throws {
        var fields = try sample()
        fields["time"] = .string("yesterday")
        #expect(try violations(fields).contains { $0.hasPrefix("/time: is not of type integer") })
    }

    @Test func rejectsEnumOutOfRange() throws {
        var fields = try sample()
        fields["severity_id"] = .integer(42)
        #expect(try violations(fields).contains { $0.hasPrefix("/severity_id: is not one of the enumerated values") })
    }

    @Test func rejectsUndefinedAttribute() throws {
        var fields = try sample()
        fields["rv_extra"] = .string("x")
        #expect(try violations(fields).contains { $0.hasPrefix("/rv_extra: is not defined by the schema") })
    }

    @Test func rejectsInconsistentTypeUID() throws {
        var fields = try sample()
        fields["type_uid"] = .integer(100_799)
        #expect(try violations(fields).contains { $0.hasPrefix("/type_uid: is not class_uid * 100 + activity_id") })
    }

    @Test func rejectsWrongCategoryForClass() throws {
        var fields = try sample()
        fields["category_uid"] = .integer(4)
        #expect(try violations(fields).contains { $0.hasPrefix("/category_uid: is not the constant") })
    }

    @Test func rejectsUnvendoredClassOrProfiles() throws {
        var fields = try sample()
        fields["class_uid"] = .integer(3002)
        #expect(try violations(fields).contains { $0.hasPrefix("/class_uid: no vendored OCSF 1.3.0 schema") })
    }

    @Test func rejectsNestedAtLeastOneViolation() throws {
        var fields = try sample()
        fields["device"] = .object(["type_id": .integer(0)])
        #expect(try violations(fields).contains { $0.hasPrefix("/device: satisfies none of the anyOf branches") })
    }
}
