#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
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

    @Test func malformedPolicyIsInvalidNotIgnored() throws {
        let bundle = try Bundle()
        try bundle.write("policy.json", Data(#"{"version": 1, "mcp": {"block": ["x"]}}"#.utf8))
        #expect(bundle.location().load() == .invalid("unknown key \"block\" in mcp"))
    }
}
