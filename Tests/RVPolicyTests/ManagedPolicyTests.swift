#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import Testing
@testable import RVPolicy

@Suite("ManagedPolicy")
struct ManagedPolicyTests {
    static let full = """
        {"version": 1, "organization": "Acme", "serial": 7,
         "mcp": {"blocked": ["shell-*"], "allowDirect": false, "requireSandbox": true,
                 "deny": ["*/delete_*"], "ask": ["github/create_*"], "allow": ["github/*"],
                 "defaultDecision": "ask"},
         "secrets": {"allowedSources": ["keychain", "vault"], "allowEnvironmentDelivery": false},
         "audit": {"forward": {"url": "https://siem.example.com/rv", "headers": {"Authorization": "${secret:SIEM}"}}}}
        """

    @Test func decodesEveryField() throws {
        let policy = try ManagedPolicy.decode(Data(Self.full.utf8)).get()
        #expect(policy.organization == "Acme")
        #expect(policy.serial == 7)
        #expect(policy.mcp.blocked == ["shell-*"])
        #expect(policy.mcp.allowDirect == false)
        #expect(policy.mcp.requireSandbox)
        #expect(policy.mcp.defaultDecision == .ask)
        #expect(policy.secrets.allowedSources == ["keychain", "vault"])
        #expect(policy.secrets.allowEnvironmentDelivery == false)
        #expect(policy.auditForward == .init(url: "https://siem.example.com/rv", headers: ["Authorization": "${secret:SIEM}"]))

        let empty = try ManagedPolicy.decode(Data(#"{"version": 1}"#.utf8)).get()
        #expect(empty == ManagedPolicy())
        #expect(empty.mcpDecision(server: "any", tool: "thing") == .allow)
        #expect(empty.allowsSecretSource("hostEnvironment"))
    }

    @Test func rejectsTyposAndBadValues() {
        func message(_ json: String) -> String? {
            if case .failure(let error) = ManagedPolicy.decode(Data(json.utf8)) { return error.message }
            return nil
        }
        #expect(message(#"{"version": 1, "mpc": {}}"#) == "unknown key \"mpc\" in policy")
        #expect(message(#"{"version": 1, "mcp": {"denied": ["x"]}}"#) == "unknown key \"denied\" in mcp")
        #expect(message(#"{"version": 2}"#) == "policy \"version\" must be 1")
        #expect(message(#"{"version": 1, "secrets": {"allowedSources": ["keychian"]}}"#)
            == "unknown secret source \"keychian\" in secrets.allowedSources")
        #expect(message(#"{"version": 1, "mcp": {"defaultDecision": "maybe"}}"#)
            == "\"mcp.defaultDecision\" must be allow, ask, or deny")
        #expect(message(#"{"version": 1, "mcp": {"deny": [""]}}"#) != nil)
        #expect(message(#"{"version": 1, "audit": {"forward": {}}}"#) == "\"audit.forward.url\" is required")
        #expect(message("[]") == "policy.json is not a JSON object")
        #expect(message(#"{"version":1,"mcp":{"defaultDecision":"deny"},"mcp":{"defaultDecision":"allow"}}"#) != nil)
        #expect(message(#"{"version":1,"serial":1,"serial":2}"#) != nil)
        if case .success(let policy) = ManagedPolicy.decode(
            Data(#"{"version":1,"mcp":{"defaultDecision":"deny"},"mcp":{"defaultDecision":"allow"}}"#.utf8))
        {
            Issue.record("a repeated mcp key applied \(policy.mcp.defaultDecision)")
        }
    }

    @Test func decisionOrderIsDenyAskAllowDefault() throws {
        let policy = try ManagedPolicy.decode(Data(Self.full.utf8)).get()
        #expect(policy.mcpDecision(server: "github", tool: "delete_repo") == .deny)
        #expect(policy.mcpDecision(server: "github", tool: "create_issue") == .ask)
        #expect(policy.mcpDecision(server: "github", tool: "get_issue") == .allow)
        #expect(policy.mcpDecision(server: "fs", tool: "read") == .ask)
        #expect(policy.isServerBlocked("shell-runner"))
        #expect(policy.isServerBlocked("github") == false)
        #expect(policy.allowsSecretSource("keychain"))
        #expect(policy.allowsSecretSource("hostEnvironment") == false)
    }

    @Test func argumentRulesSitBesideGlobsAndTheStrictestWins() throws {
        let text = """
            {"version": 1, "mcp": {
              "allow": ["db/*"],
              "ask": [{"tool": "db/query", "when": {"/database": {"==": "prod"}}}],
              "deny": [{"tool": "*/query", "when": {"/sql": {"glob": "DROP *"}}}]}}
            """
        let policy = try ManagedPolicy.decode(Data(text.utf8)).get()
        func args(_ json: String) throws -> JSONValue {
            try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        }
        #expect(policy.mcp.allow == ["db/*"])
        #expect(policy.mcp.rules.map(\.decision) == [.ask, .deny])
        #expect(policy.mcpDecision(server: "db", tool: "query", arguments: try args(#"{"database":"test"}"#)) == .allow)
        #expect(policy.mcpDecision(server: "db", tool: "query", arguments: try args(#"{"database":"prod"}"#)) == .ask)
        #expect(policy.mcpDecision(
            server: "db", tool: "query", arguments: try args(#"{"database":"test","sql":"DROP TABLE x"}"#)) == .deny)
        #expect(policy.mcpDecision(server: "db", tool: "query") == .allow)
        #expect(policy.mcpHasArgumentRules(server: "db", tool: "query"))
        #expect(policy.mcpHasArgumentRules(server: "db", tool: "list") == false)

        func message(_ json: String) -> String? {
            if case .failure(let error) = ManagedPolicy.decode(Data(json.utf8)) { return error.message }
            return nil
        }
        #expect(message(#"{"version": 1, "mcp": {"deny": [{"tool": "x/y", "when": {"/a": {"~": 1}}}]}}"#)?
            .hasPrefix("mcp.deny: unknown operator") == true)
        #expect(message(#"{"version": 1, "mcp": {"deny": [3]}}"#) == "\"mcp.deny\" must hold non-empty strings or rule objects")
    }
}

@Suite("ManagedPolicyLocation")
struct ManagedPolicyLocationTests {
    final class Bundle {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rv-managed-\(UUID().uuidString)")
        var directory: URL { root.appendingPathComponent("managed") }

        init() throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            chmod(root.path, 0o755)
            chmod(directory.path, 0o755)
        }

        func write(_ name: String, _ data: Data, mode: mode_t = 0o644) throws {
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            chmod(url.path, mode)
        }

        func location(owner: uid_t = getuid()) -> ManagedPolicyLocation {
            ManagedPolicyLocation(directory: directory, requiredOwner: owner, trustRoot: root.path)
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private let policy = Data(ManagedPolicyTests.full.utf8)

    @Test func missingDirectoryOrPolicyIsNone() throws {
        let missing = ManagedPolicyLocation(
            directory: URL(fileURLWithPath: "/nonexistent-rv-managed-\(UUID().uuidString)"), requiredOwner: 0, trustRoot: "/")
        #expect(missing.load() == .none)
        let bundle = try Bundle()
        #expect(bundle.location().load() == .none)
    }

    @Test func unsignedPolicyIsActive() throws {
        let bundle = try Bundle()
        try bundle.write("policy.json", policy)
        guard case .active(let active) = bundle.location().load() else {
            Issue.record("expected active")
            return
        }
        #expect(active.isSigned == false)
        #expect(active.policy.organization == "Acme")
        #expect(active.sha256.count == 64)
    }

    @Test func untrustedOwnershipModeOrSymlinkIsInvalid() throws {
        let bundle = try Bundle()
        try bundle.write("policy.json", policy)
        #expect(bundle.location(owner: getuid() == 0 ? 1 : 0).load().invalidReason != nil)

        chmod(bundle.directory.appendingPathComponent("policy.json").path, 0o666)
        #expect(bundle.location().load().invalidReason?.contains("policy.json") == true)
        chmod(bundle.directory.appendingPathComponent("policy.json").path, 0o644)

        chmod(bundle.directory.path, 0o775)
        #expect(bundle.location().load().invalidReason?.contains("must be a directory") == true)
        chmod(bundle.directory.path, 0o755)

        let elsewhere = bundle.root.appendingPathComponent("elsewhere.json")
        try policy.write(to: elsewhere)
        try FileManager.default.removeItem(at: bundle.directory.appendingPathComponent("policy.json"))
        try FileManager.default.createSymbolicLink(
            at: bundle.directory.appendingPathComponent("policy.json"), withDestinationURL: elsewhere)
        #expect(bundle.location().load().invalidReason != nil)
    }

    @Test func pinnedKeyRequiresAValidSignature() throws {
        let bundle = try Bundle()
        let pair = ManagedPolicyVerifier.generateKeyPair()
        try bundle.write("policy.json", policy)
        try bundle.write("org-key.pub", Data((pair.publicKey + "\n").utf8))
        #expect(bundle.location().load().invalidReason?.contains("policy.json.sig is missing") == true)

        let signature = try #require(ManagedPolicyVerifier.sign(policy, privateKey: Data(pair.privateKey.utf8)))
        try bundle.write("policy.json.sig", Data(signature.utf8))
        guard case .active(let active) = bundle.location().load() else {
            Issue.record("a correctly signed policy must be active")
            return
        }
        #expect(active.isSigned)

        var tampered = policy
        tampered.append(contentsOf: Array(" ".utf8))
        try bundle.write("policy.json", tampered)
        #expect(bundle.location().load().invalidReason?.contains("does not verify") == true)

        let other = ManagedPolicyVerifier.generateKeyPair()
        try bundle.write("policy.json", policy)
        let foreign = try #require(ManagedPolicyVerifier.sign(policy, privateKey: Data(other.privateKey.utf8)))
        try bundle.write("policy.json.sig", Data(foreign.utf8))
        #expect(bundle.location().load().invalidReason?.contains("does not verify") == true)

        try bundle.write("org-key.pub", Data("not a key".utf8))
        #expect(bundle.location().load().invalidReason?.contains("not a base64 Ed25519 public key") == true)
    }

    @Test func anyPinnedKeyVerifiesSoKeysCanRotate() throws {
        let bundle = try Bundle()
        let old = ManagedPolicyVerifier.generateKeyPair()
        let new = ManagedPolicyVerifier.generateKeyPair()
        try bundle.write("policy.json", policy)
        try bundle.write("org-key.pub", Data("# Acme policy keys\n\(old.publicKey)\n\n# next\n  \(new.publicKey)  \n".utf8))
        let signature = try #require(ManagedPolicyVerifier.sign(policy, privateKey: Data(new.privateKey.utf8)))
        try bundle.write("policy.json.sig", Data(signature.utf8))
        guard case .active(let active) = bundle.location().load() else {
            Issue.record("a policy signed by the second pinned key must be active")
            return
        }
        #expect(active.isSigned)
        #expect(active.signingKey == 2)

        let stranger = ManagedPolicyVerifier.generateKeyPair()
        let foreign = try #require(ManagedPolicyVerifier.sign(policy, privateKey: Data(stranger.privateKey.utf8)))
        try bundle.write("policy.json.sig", Data(foreign.utf8))
        #expect(bundle.location().load().invalidReason == "policy.json.sig does not verify against any key in org-key.pub")

        try bundle.write("org-key.pub", Data("\(old.publicKey)\n# comment\nnot-a-key\n".utf8))
        #expect(bundle.location().load().invalidReason == "org-key.pub line 3 is not a base64 Ed25519 public key")
        try bundle.write("org-key.pub", Data("# no keys yet\n\n".utf8))
        #expect(bundle.location().load().invalidReason == "org-key.pub holds no key")
        let many = (0...ManagedPolicyVerifier.maximumKeys).map { _ in ManagedPolicyVerifier.generateKeyPair().publicKey }
        try bundle.write("org-key.pub", Data(many.joined(separator: "\n").utf8))
        #expect(bundle.location().load().invalidReason
            == "org-key.pub holds more than \(ManagedPolicyVerifier.maximumKeys) keys")
    }

    @Test func malformedPolicyIsInvalidNotIgnored() throws {
        let bundle = try Bundle()
        try bundle.write("policy.json", Data(#"{"version": 1, "mcp": {"block": ["x"]}}"#.utf8))
        #expect(bundle.location().load() == .invalid("unknown key \"block\" in mcp"))
    }
}

@Suite("ManagedSerialRecord")
struct ManagedSerialRecordTests {
    func active(serial: Int?, directory: String = "/etc/rv/managed") throws -> ManagedPolicyState {
        var policy = try ManagedPolicy.decode(Data(#"{"version": 1}"#.utf8)).get()
        policy.serial = serial
        return .active(ManagedPolicyBundle(policy: policy, sha256: "x", isSigned: true, directory: directory))
    }

    @Test func aHigherSerialIsRememberedAndALowerOneIsARollback() throws {
        let first = try active(serial: 5).checkedForRollback(against: ManagedSerialRecord())
        #expect(first.raised == ManagedSerialRecord(highest: ["/etc/rv/managed": 5]))
        guard case .active(let bundle) = first.state else {
            Issue.record("the first serial must be accepted")
            return
        }
        #expect(bundle.highestSerial == 5)
        let record = try #require(first.raised)

        let same = try active(serial: 5).checkedForRollback(against: record)
        #expect(same.raised == nil)
        #expect(same.state.policy != nil)

        let newer = try active(serial: 9).checkedForRollback(against: record)
        #expect(newer.raised == ManagedSerialRecord(highest: ["/etc/rv/managed": 9]))

        let older = try active(serial: 4).checkedForRollback(against: record)
        #expect(older.raised == nil)
        #expect(older.state.invalidReason
            == "rollback: policy.json serial 4 is lower than serial 5 already accepted from /etc/rv/managed")

        let unnumbered = try active(serial: nil).checkedForRollback(against: record)
        #expect(unnumbered.state.invalidReason
            == "rollback: policy.json has no serial but serial 5 was already accepted from /etc/rv/managed")
    }

    @Test func directoriesAreTrackedSeparatelyAndOtherStatesPassThrough() throws {
        let record = ManagedSerialRecord(highest: ["/etc/rv/managed": 5])
        let elsewhere = try active(serial: 1, directory: "/other").checkedForRollback(against: record)
        #expect(elsewhere.raised == ManagedSerialRecord(highest: ["/etc/rv/managed": 5, "/other": 1]))
        let unnumbered = try active(serial: nil, directory: "/fresh").checkedForRollback(against: record)
        #expect(unnumbered.raised == nil)
        #expect(unnumbered.state.policy != nil)
        #expect(ManagedPolicyState.none.checkedForRollback(against: record).state == .none)
        #expect(ManagedPolicyState.invalid("x").checkedForRollback(against: record).state == .invalid("x"))
    }

    @Test func serialsAboveTwoToTheFiftyThreeStayExact() throws {
        let high = 9_007_199_254_740_995
        let low = 9_007_199_254_740_994
        let decoded = try ManagedPolicy.decode(Data(#"{"version": 1, "serial": \#(high)}"#.utf8)).get()
        #expect(decoded.serial == high)
        #expect(throws: (any Error).self) { try ManagedPolicy.decode(Data(#"{"version": 1, "serial": 1.5}"#.utf8)).get() }
        #expect(throws: (any Error).self) { try ManagedPolicy.decode(Data(#"{"version": 1, "serial": 1e2}"#.utf8)).get() }
        #expect(throws: (any Error).self) { try ManagedPolicy.decode(Data(#"{"version": 1, "serial": "5"}"#.utf8)).get() }

        let remembered = ManagedSerialRecord(highest: ["/etc/rv/managed": low])
        let newer = try active(serial: high).checkedForRollback(against: remembered)
        #expect(newer.raised == ManagedSerialRecord(highest: ["/etc/rv/managed": high]))
        let older = try active(serial: low).checkedForRollback(against: ManagedSerialRecord(highest: ["/etc/rv/managed": high]))
        #expect(older.state.invalidReason?.contains("serial \(low) is lower than serial \(high)") == true)

        let record = ManagedSerialRecord(highest: ["/etc/rv/managed": high])
        #expect(try ManagedSerialRecord.decode(record.encoded()).get() == record)
        let legacy = Data(#"{"version":1,"highest":{"/etc/rv/managed":\#(low)}}"#.utf8)
        #expect(try ManagedSerialRecord.decode(legacy).get().highest["/etc/rv/managed"] == low)
    }

    @Test func recordRoundTripsAndRejectsGarbage() throws {
        let record = ManagedSerialRecord(highest: ["/etc/rv/managed": 12])
        #expect(try ManagedSerialRecord.decode(record.encoded()).get() == record)
        #expect(throws: (any Error).self) { try ManagedSerialRecord.decode(Data("[]".utf8)).get() }
        #expect(throws: (any Error).self) {
            try ManagedSerialRecord.decode(Data(#"{"version": 1, "highest": {"/a": -1}}"#.utf8)).get()
        }
    }
}
