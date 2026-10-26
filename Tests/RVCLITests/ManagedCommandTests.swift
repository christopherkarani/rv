import Foundation
import RVIsolation
import RVMCP
import RVPolicy
import Testing
@testable import RVCLI

@Suite("rv managed / rv report / org policy in the CLI")
struct ManagedCommandTests {
    final class Scratch {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rv-managed-cli-\(UUID().uuidString)")
        var home: URL { root.appendingPathComponent("home") }
        var config: URL { home.appendingPathComponent(".config/rv") }

        @discardableResult
        func write(_ relative: String, _ text: String) throws -> URL {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            return url
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private func active(_ json: String) throws -> ManagedPolicyState {
        .active(ManagedPolicyBundle(
            policy: try ManagedPolicy.decode(Data(json.utf8)).get(), sha256: "abc", isSigned: true, directory: "/managed"))
    }

    private func failure<T>(_ result: Result<T, CommandFailure>) -> String? {
        if case .failure(let failure) = result { return failure.message }
        return nil
    }

    @Test func keygenSignVerifyRoundTripAndTamperDetection() throws {
        let scratch = Scratch()
        let keys = scratch.root.appendingPathComponent("keys")
        let bundle = scratch.root.appendingPathComponent("bundle")
        #expect(try ManagedRun.keygen(directory: keys).get().contains("org-key.pub"))
        #expect(failure(ManagedRun.keygen(directory: keys))?.contains("refusing to overwrite") == true)
        let attributes = try FileManager.default.attributesOfItem(atPath: keys.appendingPathComponent("org-key.private").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        try scratch.write("bundle/policy.json", #"{"version": 1, "organization": "Acme", "mcp": {"blocked": ["shell-*"]}}"#)
        try FileManager.default.copyItem(
            at: keys.appendingPathComponent("org-key.pub"), to: bundle.appendingPathComponent("org-key.pub"))
        #expect(failure(ManagedRun.verify(directory: bundle))?.contains("policy.json.sig is missing") == true)

        _ = try ManagedRun.sign(
            policy: bundle.appendingPathComponent("policy.json"), key: keys.appendingPathComponent("org-key.private"),
            output: nil
        ).get()
        let status = try ManagedRun.verify(directory: bundle).get()
        #expect(status.state == "active")
        #expect(status.signed == true)
        #expect(status.organization == "Acme")
        #expect(ManagedRun.statusText(status).contains("mcp blocked servers: shell-*"))

        try scratch.write("bundle/policy.json", #"{"version": 1, "organization": "Acme"}"#)
        #expect(failure(ManagedRun.verify(directory: bundle))?.contains("does not verify") == true)

        try scratch.write("bundle/bad.json", #"{"version": 1, "oops": true}"#)
        #expect(failure(ManagedRun.sign(
            policy: bundle.appendingPathComponent("bad.json"), key: keys.appendingPathComponent("org-key.private"),
            output: nil))?.contains("not signed") == true)
    }

    @Test func statusNamesTheSigningKeyAndTheHighestSerial() throws {
        let policy = try ManagedPolicy.decode(Data(#"{"version": 1, "organization": "Acme", "serial": 8}"#.utf8)).get()
        let status = ManagedRun.status(
            .active(ManagedPolicyBundle(
                policy: policy, sha256: "abc", isSigned: true, directory: "/managed", signingKey: 2, highestSerial: 8)),
            directory: "/managed")
        #expect(status.signingKey == 2)
        #expect(status.highestSerial == 8)
        let text = ManagedRun.statusText(status)
        #expect(text.contains("organization policy active: Acme serial 8\n"))
        #expect(text.contains("  signed by key 2 in org-key.pub sha256 abc\n"))
        #expect(text.contains("  anti-rollback: highest serial accepted here is 8\n"))

        let rollback = ManagedRun.statusText(ManagedRun.status(
            .invalid("rollback: policy.json serial 2 is lower than serial 8 already accepted from /managed"),
            directory: "/managed"))
        #expect(rollback.hasPrefix("organization policy INVALID: rollback: policy.json serial 2"))
    }

    @Test func restrictionsAlwaysNameTheSandboxRequirement() throws {
        let legacy = try ManagedPolicy.decode(Data(#"{"version":1,"mcp":{"requireSandbox":true}}"#.utf8)).get()
        let plain = try ManagedPolicy.decode(Data(#"{"version":1}"#.utf8)).get()
        #if os(macOS)
        let sandbox = "mcp: every local server must be sandboxed (remote servers are exempt)"
        #else
        let sandbox = "mcp: sandboxes need macOS; sandboxed servers are refused here (remote servers are exempt)"
        #endif
        // The policy flag is legacy: the hard flip requires sandboxes either way.
        #expect(ManagedRun.restrictions(legacy) == [sandbox])
        #expect(ManagedRun.restrictions(plain) == [sandbox])
    }

    @Test func mcpCommandsFollowTheOrganization() async throws {
        let scratch = Scratch()
        var environment = MCPEnvironment(
            configDirectory: scratch.config, home: scratch.home, processEnvironment: [:], keychain: FakeKeychain().writer,
            approvalKeys: .file(configDirectory: scratch.config), presence: UserPresence { _, _ in .confirmed(method: "test") })
        let signer = try #require(environment.approvalKeys.loadOrCreate())
        _ = MCPConfiguration(servers: [MCPServerDefinition(name: "github", command: "gh-mcp")])
            .write(configDirectory: scratch.config, signer: signer)

        environment.managed = .invalid("bad signature")
        #expect(failure(MCPRun.configuration(environment))
            == "organization policy is invalid, so MCP is disabled: bad signature")

        environment.managed = try active(#"{"version": 1, "mcp": {"ask": ["github/create_*"]}}"#)
        let ticket = try #require(
            environment.approvals.request(server: "github", tool: "create_issue", argumentsHash: "h", argumentKeys: []))
        #expect(failure(await MCPRun.approve(id: ticket.id, always: true, environment: environment))
            == "organization policy says ask for github/create_issue; approve it once instead")
        let code = try #require(ticket.code)
        environment.presence = UserPresence { _, challenge in
            switch challenge {
            case .printedCode(let check):
                guard check(code) else { return .refused("wrong confirmation code") }
                return .confirmed(method: "terminal confirmation code")
            case .deviceOwner:
                return .confirmed(method: "device owner authentication")
            }
        }
        #expect(try await MCPRun.approve(id: ticket.id, always: false, environment: environment).get().contains("once"))

        environment.managed = try active(#"""
            {"version": 1, "mcp": {"deny": [{"tool": "github/merge_*", "when": {"/branch": {"==": "main"}}}]}}
            """#)
        let merge = try #require(
            environment.approvals.request(server: "github", tool: "merge_pr", argumentsHash: "h", argumentKeys: []))
        #expect(failure(await MCPRun.approve(id: merge.id, always: true, environment: environment))?
            .contains("has argument rules") == true)
        #if os(macOS)
        let sandbox = "mcp: every local server must be sandboxed (remote servers are exempt)"
        #else
        let sandbox = "mcp: sandboxes need macOS; sandboxed servers are refused here (remote servers are exempt)"
        #endif
        #expect(ManagedRun.restrictions(try #require(environment.managed.policy))
            == [sandbox, #"mcp deny: github/merge_* when /branch == "main""#])

        try scratch.write("home/.cursor/mcp.json", """
            {"mcpServers": {"svc": {"command": "svc", "env": {"API_TOKEN": "tok_live_abcdefghijklmnopqrstu"}}}}
            """)
        environment.managed = try active(#"{"version": 1, "secrets": {"allowedSources": ["vault"]}}"#)
        #expect(failure(await MCPRun.importServers(
            host: .cursor, names: [], project: nil, dryRun: false, environment: environment))?
            .contains("keychain source, which is not allowed") == true)
    }

    @Test func secretsSetAndCheckFollowTheOrganization() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        var environment = fixture.environment()
        environment.managed = try active(#"{"version": 1, "secrets": {"allowEnvironmentDelivery": false}}"#)
        let refused = SecretsRun.set(
            name: "GH_TOKEN", value: Data("ghp_x".utf8), definition: .environment, agents: [], description: nil,
            environment: environment)
        #expect(failure(refused)?.contains("environment variable, which is not allowed") == true)
        #expect(fixture.keychain.items.withLock { $0.isEmpty })
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("secrets.json").path) == false)
    }

    @Test func reportIsNotCompliantWhileMCPJSONIsUntrusted() throws {
        let scratch = Scratch()
        let mcp = try scratch.write("home/.config/rv/mcp.json", #"{"version":1,"servers":[]}"#)
        chmod(mcp.path, 0o600)
        chmod(scratch.config.path, 0o700)
        let keys = MCPApprovalKeyStore.file(configDirectory: scratch.config)
        func build() -> ReportRun.Report {
            ReportRun.build(ReportRun.Inputs(
                configDirectory: scratch.config, home: scratch.home, processEnvironment: [:], managed: .none,
                managedDirectory: "/managed", now: Date(), hostName: "h", userName: "dev", userID: 501,
                fileExists: { _ in false }, approvalKeys: keys))
        }
        let untrusted = build()
        #expect(untrusted.compliant == false)
        #expect(untrusted.mcp.error?.contains("edited outside rv") == true)
        #expect(ReportRun.text(untrusted).contains("edited outside rv"))

        let signer = try #require(keys.loadOrCreate())
        #expect(MCPIntegrity.signCurrent(configDirectory: scratch.config, signer: signer))
        #expect(build().compliant)
    }

    @Test func reportSummarizesPostureWithoutSecretValues() throws {
        let scratch = Scratch()
        try scratch.write("home/.cursor/mcp.json", #"{"mcpServers": {"loose": {"command": "x", "env": {"GITHUB_TOKEN": "ghp_abcdefghijklmnopqrstuvwxyz0123456789"}}}}"#)
        let secrets = try scratch.write("home/.config/rv/secrets.json", """
            {"version":1,"secrets":[{"name":"GH","source":{"hostEnvironment":{"variable":"GH"}},"delivery":{"environment":{}}}]}
            """)
        chmod(secrets.path, 0o600)
        chmod(scratch.config.path, 0o700)
        func inputs(_ managed: ManagedPolicyState) -> ReportRun.Inputs {
            ReportRun.Inputs(
                configDirectory: scratch.config, home: scratch.home, processEnvironment: [:], managed: managed,
                managedDirectory: "/managed", now: Date(), hostName: "host-1", userName: "dev", userID: 501,
                fileExists: { _ in true })
        }

        let plain = ReportRun.build(inputs(.none))
        #expect(plain.schema == "rv.report.v1")
        #expect(plain.mcp.counts == ["unreviewed": 1])
        #expect(plain.mcp.plaintextCredentials == 1)
        #expect(plain.secrets.items == [.init(name: "GH", source: "hostEnvironment", delivery: "environment")])
        #expect(plain.config.first { $0.file == "secrets.json" }?.sha256?.count == 64)
        #expect(plain.compliant == false)
        let json = ReportRun.json(plain)
        #expect(json.contains("ghp_") == false)
        #expect(ReportRun.text(plain).contains("NOT compliant"))

        let governed = ReportRun.build(inputs(try active(#"{"version": 1, "secrets": {"allowEnvironmentDelivery": false}}"#)))
        #expect(governed.managed.state == "active")
        #expect(governed.secrets.items.first?.policyViolation?.contains("not allowed") == true)

        let broken = ReportRun.build(inputs(.invalid("bad owner")))
        #expect(broken.managed.state == "invalid")
        #expect(broken.mcp.ok == false)
        #expect(broken.mcp.error?.contains("bad owner") == true)
    }

    @Test func managedPolicyTextEscapesControlsInHumanAndRobotOutput() throws {
        let sentence = "ok: every MCP server is governed by rv, allowed direct, or disabled"
        let scratch = Scratch()
        let bundle = scratch.root.appendingPathComponent("bundle")
        let carrier = "\\u001b[2J\\u001b[H\(sentence)\\u2028\(sentence)\\u202e\(sentence)"
        let json = """
        {"version":1,"organization":"\(carrier)","mcp":{"blocked":["\(carrier)"],"deny":["\(carrier)"],"ask":["\(carrier)"],"allow":["\(carrier)"]},"audit":{"forward":{"url":"\(carrier)"}}}
        """
        try scratch.write("bundle/policy.json", json)
        let status = try ManagedRun.verify(directory: bundle).get()
        let text = ManagedRun.statusText(status)
        #expect(text.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(text.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(text.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(text.contains("\\u001b[2J"))
        #expect(text.contains("\\u2028"))
        #expect(text.contains("\\u202e"))
        #expect(text.contains("\\\\u001b") == false)
        #expect(text.contains("mcp blocked servers:"))
        #expect(text.contains("mcp deny:"))
        #expect(text.contains("mcp ask:"))
        #expect(text.contains("mcp allow:"))
        #expect(text.contains("organization policy active:"))
        #expect(text.contains("audit forwarded to"))
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\u{2028}" || $0 == "\u{2029}" }).map(String.init)
        #expect(lines.contains(sentence) == false)

        let robot = ManagedRun.robotJSON(status)
        #expect(robot.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(robot.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(robot.unicodeScalars.contains { $0.value == 0x2029 } == false)
        #expect(robot.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(robot.contains("\\u001b"))
        #expect(robot.contains("\\\\u001b") == false)
        #expect(robot.contains("\\u2028"))
        #expect(robot.contains("\\u202e"))
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(robot.utf8)) as? [String: Any])
        let organization = try #require(parsed["organization"] as? String)
        #expect(organization.unicodeScalars.contains { $0.value == 0x1B })
        #expect(organization.unicodeScalars.contains { $0.value == 0x2028 })
        #expect(organization.unicodeScalars.contains { $0.value == 0x202E })
        let restrictions = try #require(parsed["restrictions"] as? [String])
        #expect(restrictions.contains { $0.contains("mcp blocked servers:") && $0.unicodeScalars.contains { $0.value == 0x202E } })
    }

    @Test func unknownSecretSourceIsEscapedOnThePolicyError() throws {
        let sentence = "ok: every MCP server is governed by rv, allowed direct, or disabled"
        let carrier = "\\u001b[2J\\u001b[H\(sentence)\\u2028\(sentence)\\u202e\(sentence)"
        let json = "{\"version\":1,\"secrets\":{\"allowedSources\":[\"\(carrier)\"]}}"
        guard case .failure(let error) = ManagedPolicy.decode(Data(json.utf8)) else {
            Issue.record("unknown secret source was accepted")
            return
        }
        #expect(error.message.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(error.message.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(error.message.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(error.message.contains("\\u001b[2J"))
        #expect(error.message.contains("\\u2028"))
        #expect(error.message.contains("\\u202e"))
        #expect(error.message.contains("\\\\u001b") == false)
        #expect(error.message.contains("unknown secret source"))
        let listed = "organization policy is invalid, so MCP is disabled: \(error.message)"
        #expect(listed.unicodeScalars.contains { $0.value == 0x2028 } == false)
        let forwarded = "organization policy is invalid: \(error.message)"
        #expect(forwarded.unicodeScalars.contains { $0.value == 0x202E } == false)
    }

    @Test func managedPathArgumentEscapesControlsOnVerifyKeygenAndSign() throws {
        let sentence = "ok: every MCP server is governed by rv, allowed direct, or disabled"
        let hostile = "/tmp/p\u{1B}[2J\u{1B}[H\u{2028}\(sentence)\u{202E}\(sentence)"
        let directory = URL(fileURLWithPath: hostile, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func spelled(_ text: String) {
            #expect(text.unicodeScalars.contains { $0.value == 0x1B } == false)
            #expect(text.unicodeScalars.contains { $0.value == 0x2028 } == false)
            #expect(text.unicodeScalars.contains { $0.value == 0x202E } == false)
            #expect(text.contains("\\u001b[2J"))
            #expect(text.contains("\\u2028"))
            #expect(text.contains("\\u202e"))
            #expect(text.contains("\\\\u001b") == false)
            let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\u{2028}" || $0 == "\u{2029}" }).map(String.init)
            #expect(lines.contains(sentence) == false)
        }

        let missing = failure(ManagedRun.verify(directory: directory)) ?? ""
        #expect(missing.contains("has no policy.json"))
        spelled(missing)

        let wrote = try ManagedRun.keygen(directory: directory).get()
        #expect(wrote.contains("wrote "))
        #expect(wrote.contains("org-key.pub"))
        spelled(wrote)

        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("rv-keygen-blocker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: blocker) }
        try Data("x".utf8).write(to: blocker)
        let blocked = blocker.appendingPathComponent("p\u{1B}[2J\u{1B}[H\u{2028}\(sentence)\u{202E}\(sentence)")
        let unwritable = failure(ManagedRun.keygen(directory: blocked)) ?? ""
        #expect(unwritable.contains("could not write keys to "))
        spelled(unwritable)

        let scratch = Scratch()
        let policy = try scratch.write("bundle/policy.json", #"{"version": 1}"#)
        let unsigned = failure(ManagedRun.sign(policy: policy, key: directory, output: nil)) ?? ""
        #expect(unsigned.contains("is not a base64 Ed25519 private key"))
        spelled(unsigned)
    }
}
