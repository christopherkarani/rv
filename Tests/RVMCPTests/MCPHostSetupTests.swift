#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVIsolation
import Testing
@testable import RVMCP

@Suite("MCPImport")
struct MCPImportTests {
    private func entry(
        _ name: String, host: MCPHost = .cursor, transport: MCPTransport, environment: [String: String] = [:]
    ) -> MCPHostEntry {
        MCPHostEntry(
            host: host, scope: .user, configPath: "~/.cursor/mcp.json", name: name, transport: transport,
            environment: environment)
    }

    @Test func credentialsBecomeKeychainSecretsAndReferences() throws {
        let plan = MCPImport.plan(
            entries: [
                entry(
                    "context7",
                    transport: .stdio(command: "npx", args: ["-y", "@upstash/context7-mcp", "--api-key", "ctx7sk-11112222333344445555"]),
                    environment: ["GITHUB_TOKEN": "ghp_abcdefghijklmnopqrstuvwxyz0123456789", "LOG_LEVEL": "info", "PROXY": "${PROXY}"]),
                entry("bare", transport: .stdio(command: "srv", args: ["sk-proj-abcdefghijklmnop1234", "--port=8080"])),
                entry("db", transport: .stdio(command: "psql", args: ["postgres://user:secret@db.example/app"])),
            ],
            configuration: MCPConfiguration(), secrets: SecretsConfiguration(), allowTools: false)

        let context7 = try #require(plan.servers.first { $0.name == "context7" })
        #expect(context7.command == "npx")
        #expect(context7.args == ["-y", "@upstash/context7-mcp", "--api-key", "${secret:CONTEXT7_API_KEY}"])
        #expect(context7.secrets == ["GITHUB_TOKEN": "GITHUB_TOKEN"])
        #expect(context7.environment == ["LOG_LEVEL": "info"])
        #expect(context7.tools.defaultDecision == .ask)
        #expect(plan.notes.contains { $0.contains("PROXY") })

        let bare = try #require(plan.servers.first { $0.name == "bare" })
        #expect(bare.args == ["${secret:BARE_ARG_1}", "--port=8080"])

        let db = try #require(plan.servers.first { $0.name == "db" })
        #expect(db.args == ["${secret:DB_ARG_1}"])
        #expect(plan.secrets.map(\.definition.name).sorted() == ["BARE_ARG_1", "CONTEXT7_API_KEY", "DB_ARG_1", "GITHUB_TOKEN"])
        #expect(plan.secrets.allSatisfy {
            $0.definition.source == .keychain(service: SecretKeychain.service, account: $0.definition.name)
        })
        let encoded = MCPConfiguration(servers: plan.servers).encoded().prettyText
        #expect(encoded.contains("ctx7sk") == false && encoded.contains("ghp_") == false && encoded.contains("sk-proj") == false)
        #expect(encoded.contains("secret@") == false)
        #expect(try MCPConfiguration.decode(Data(encoded.utf8)).get().servers.count == 3)
    }

    @Test func askImportStoresAskEvenWhenTheFileAllows() throws {
        var configuration = MCPConfiguration(defaultDecision: .allow, servers: [
            MCPServerDefinition(name: "kept", command: "safe-bin")
        ])
        let plan = MCPImport.plan(
            entries: [
                entry(
                    "notes", transport: .stdio(command: "git", args: ["status"]),
                    environment: [
                        "PATH": "/tmp/evil", "GIT_SSH_COMMAND": "evil-ssh", "LD_PRELOAD": "/tmp/p.so",
                        "GITHUB_TOKEN": "ghp_abcdefghijklmnopqrstuvwxyz0123456789",
                    ])
            ],
            configuration: configuration, secrets: SecretsConfiguration(), allowTools: false)
        let notes = try #require(plan.servers.first { $0.name == "notes" })
        #expect(notes.tools.defaultDecision == .ask)
        #expect(notes.environment == ["PATH": "/tmp/evil", "GIT_SSH_COMMAND": "evil-ssh", "LD_PRELOAD": "/tmp/p.so"])
        #expect(notes.secrets == ["GITHUB_TOKEN": "GITHUB_TOKEN"])
        configuration.servers.append(notes)
        #expect(configuration.defaultDecision == .allow)
        #expect(configuration.decision(server: notes, tool: "status") == .ask)
        let kept = try #require(configuration.server(named: "kept"))
        #expect(kept.tools.defaultDecision == nil)
        #expect(configuration.decision(server: kept, tool: "anything") == .allow)
    }

    @Test func skipsGovernedRemoteExistingAndAvoidsSecretNameCollisions() {
        let configuration = MCPConfiguration(servers: [MCPServerDefinition(name: "existing", command: "x")])
        let secrets = SecretsConfiguration(secrets: [
            SecretDefinition(name: "API_TOKEN", source: .hostEnvironment(variable: "A"), delivery: .environment)
        ])
        let plan = MCPImport.plan(
            entries: [
                entry("governed", transport: .stdio(command: "/usr/local/bin/rv", args: ["mcp", "serve", "--server", "governed"])),
                entry("remote", transport: .remote(url: "https://mcp.example.com")),
                entry("existing", transport: .stdio(command: "x", args: [])),
                entry("svc", transport: .stdio(command: "svc", args: []), environment: ["API_TOKEN": "tok_live_abcdefghijklmnop"]),
            ],
            configuration: configuration, secrets: secrets, allowTools: true)
        #expect(plan.skipped.map(\.name) == ["governed", "remote", "existing"])
        #expect(plan.servers.map(\.name) == ["svc"])
        #expect(plan.servers.first?.secrets == ["API_TOKEN": "SVC_API_TOKEN"])
        #expect(plan.servers.first?.tools.defaultDecision == .allow)
    }

    @Test func secretReferencesParseAndValidate() throws {
        #expect(MCPSecretReference.names(in: "--key=${secret:A}:${secret:B_2}") == ["A", "B_2"])
        #expect(MCPSecretReference.names(in: "plain") == [])
        #expect(MCPSecretReference.names(in: "${secret:A") == nil)
        #expect(MCPSecretReference.names(in: "${secret:}") == nil)
        #expect(MCPSecretReference.substitute("k=${secret:A}", values: ["A": "v"]) == "k=v")
        let malformed = MCPConfiguration.decode(Data(#"{"version":1,"servers":{"s":{"command":"x","args":["${secret:bad name}"]}}}"#.utf8))
        #expect((try? malformed.get()) == nil)
    }

    @Test func plannerSubstitutesArgSecretsAndScrubsThem() throws {
        let configuration = MCPConfiguration(servers: [
            MCPServerDefinition(name: "s", command: "srv", args: ["--api-key", "${secret:S_KEY}"])
        ])
        let secrets = SecretsConfiguration(secrets: [
            SecretDefinition(name: "S_KEY", source: .hostEnvironment(variable: "UNUSED"), delivery: .environment)
        ])
        let resolver = SecretResolver { _ in .success(SecretValue("tok_arg_value_123")!) }
        let planned = try MCPLaunchPlanner.plan(
            servers: ["s"], configuration: configuration, secrets: secrets, resolver: resolver, baseEnvironment: [:]
        ).get()
        #expect(planned[0].1.arguments == ["srv", "--api-key", "tok_arg_value_123"])
        #expect(planned[0].0.secretValues.map(\.name) == ["S_KEY"])

        if case .failure(let error) = MCPLaunchPlanner.plan(
            servers: ["s"], configuration: configuration, secrets: SecretsConfiguration(), resolver: resolver,
            baseEnvironment: [:])
        {
            #expect(error == .secretUndefined(server: "s", secret: "S_KEY"))
        } else {
            Issue.record("undefined arg secret must refuse to launch")
        }
    }

    @Test func sandboxedLaunchDropsHostCredentialsButKeepsSecrets() throws {
        var definition = MCPServerDefinition(
            name: "s", command: "srv", environment: ["LOG_LEVEL": "info"], secrets: ["TOKEN": "S_KEY"])
        definition.sandbox = MCPSandboxPolicy(network: false)
        let secrets = SecretsConfiguration(secrets: [
            SecretDefinition(name: "S_KEY", source: .hostEnvironment(variable: "UNUSED"), delivery: .environment)
        ])
        let resolver = SecretResolver { _ in .success(SecretValue("injected-secret")!) }
        let base = [
            "PATH": "/usr/bin", "HOME": "/home/me", "TMPDIR": "/tmp", "LANG": "en_US.UTF-8", "LC_ALL": "C",
            "AWS_SECRET_ACCESS_KEY": "aws-secret", "GITHUB_TOKEN": "ghp_from_host",
        ]
        let planned = try MCPLaunchPlanner.plan(
            servers: ["s"], configuration: MCPConfiguration(servers: [definition]), secrets: secrets, resolver: resolver,
            baseEnvironment: base
        ).get()
        let environment = planned[0].1.environment
        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["HOME"] == "/home/me")
        #expect(environment["TMPDIR"] == "/tmp")
        #expect(environment["LANG"] == "en_US.UTF-8")
        #expect(environment["LC_ALL"] == "C")
        #expect(environment["LOG_LEVEL"] == "info")
        #expect(environment["TOKEN"] == "injected-secret")
        #expect(environment["AWS_SECRET_ACCESS_KEY"] == nil)
        #expect(environment["GITHUB_TOKEN"] == nil)
        #expect(planned[0].0.secretValues.map(\.name) == ["S_KEY"])
        #expect(planned[0].0.secretValues.map(\.value) == ["injected-secret"])

        var plain = definition
        plain.sandbox = nil
        let inherited = try MCPLaunchPlanner.plan(
            servers: ["s"], configuration: MCPConfiguration(servers: [plain]), secrets: secrets, resolver: resolver,
            baseEnvironment: base
        ).get()
        #expect(inherited[0].1.environment["AWS_SECRET_ACCESS_KEY"] == "aws-secret")
    }
}

@Suite("MCPHostSetup")
struct MCPHostSetupTests {
    final class Sandbox {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rv-mcp-setup-\(UUID().uuidString)")
        var home: URL { root.appendingPathComponent("home") }
        var config: URL { root.appendingPathComponent("config") }

        func write(_ relative: String, _ text: String) throws -> URL {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            return url
        }

        func files(_ host: MCPHost) -> [MCPHostFile] {
            MCPHostFile.all(home: home, project: nil, environment: [:]).filter { $0.host == host }
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private let configuration = MCPConfiguration(servers: [
        MCPServerDefinition(name: "wax", command: "wax-mcp"),
        MCPServerDefinition(name: "oc", command: "bun"),
    ])

    @Test func setupThenUndoRoundTripsAndKeepsOtherKeys() throws {
        let box = Sandbox()
        let original = """
            {"numStartups": 3, "mcpServers": {"wax": {"type": "stdio", "command": "wax-mcp", "args": []}, "other": {"command": "o"}}}
            """
        let file = try box.write(".claude.json", original)
        chmod(file.path, 0o600)

        let result = try MCPHostSetup.setup(
            files: box.files(.claudeCode), configuration: configuration, servers: nil, rvPath: "/opt/rv",
            configDirectory: box.config
        ).get()
        #expect(result.changed.count == 1)
        #expect(result.skipped == ["other (claude-code): not in mcp.json; `rv mcp import` it first"])

        let rewritten = try JSONValue.parse(Data(contentsOf: file), maximumDepth: 64)
        #expect(rewritten["numStartups"] == .int(3))
        #expect(rewritten["mcpServers"]?["wax"] == .object([
            "type": .string("stdio"), "command": .string("/opt/rv"),
            "args": .array(["mcp", "serve", "--server", "wax"].map(JSONValue.string)),
        ]))
        #expect(rewritten["mcpServers"]?["other"]?["command"] == .string("o"))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let inventory = MCPInventory.discover(home: box.home, project: nil, environment: [:])
        #expect(inventory.entries.first { $0.name == "wax" }?.governedServer == "wax")

        let again = try MCPHostSetup.setup(
            files: box.files(.claudeCode), configuration: configuration, servers: ["wax"], rvPath: "/opt/rv",
            configDirectory: box.config
        ).get()
        #expect(again.changed.isEmpty)

        let undone = try MCPHostSetup.undo(host: .claudeCode, servers: nil, configDirectory: box.config).get()
        #expect(undone.changed.count == 1)
        #expect(try JSONValue.parse(Data(contentsOf: file), maximumDepth: 64) == JSONValue.parse(Data(original.utf8), maximumDepth: 64))
        #expect(try MCPHostSetup.undo(host: .claudeCode, servers: nil, configDirectory: box.config).get().changed.isEmpty)
    }

    @Test func undoLeavesEntriesTheUserChanged() throws {
        let box = Sandbox()
        let file = try box.write(".cursor/mcp.json", #"{"mcpServers": {"wax": {"command": "wax-mcp"}}}"#)
        _ = try MCPHostSetup.setup(
            files: box.files(.cursor), configuration: configuration, servers: nil, rvPath: "/opt/rv",
            configDirectory: box.config
        ).get()
        try Data(#"{"mcpServers": {"wax": {"command": "hand-edited"}}}"#.utf8).write(to: file)

        let undone = try MCPHostSetup.undo(host: .cursor, servers: nil, configDirectory: box.config).get()
        #expect(undone.changed.isEmpty)
        #expect(undone.skipped == ["wax (cursor): changed since setup; left as is"])
        #expect(try JSONValue.parse(Data(contentsOf: file), maximumDepth: 64)["mcpServers"]?["wax"]?["command"] == .string("hand-edited"))
    }

    @Test func refusesFilesWhoseCommentsWouldBeLost() throws {
        let box = Sandbox()
        let text = "{\"mcpServers\": {\"wax\": {\"command\": \"wax-mcp\"}}, // keep me\n}"
        let file = try box.write(".cursor/mcp.json", text)
        let outcome = MCPHostSetup.setup(
            files: box.files(.cursor), configuration: configuration, servers: nil, rvPath: "/opt/rv",
            configDirectory: box.config)
        #expect(outcome == .failure(.hasComments(file.path)))
        #expect(try String(contentsOf: file, encoding: .utf8) == text)
    }

    @Test func rewritesOpencodeShapeAndPrintsCodexSteps() throws {
        let box = Sandbox()
        let file = try box.write(
            ".config/opencode/opencode.json",
            #"{"mcp": {"oc": {"type": "local", "command": ["bun", "run", "srv.ts"], "enabled": true}}}"#)
        _ = try box.write(".codex/config.toml", "[mcp_servers.wax]\ncommand = \"wax-mcp\"\n")

        _ = try MCPHostSetup.setup(
            files: box.files(.opencode), configuration: configuration, servers: nil, rvPath: "/opt/rv",
            configDirectory: box.config
        ).get()
        #expect(try JSONValue.parse(Data(contentsOf: file), maximumDepth: 64)["mcp"]?["oc"] == .object([
            "type": .string("local"), "command": .array(["/opt/rv", "mcp", "serve", "--server", "oc"].map(JSONValue.string)),
            "enabled": .bool(true),
        ]))

        let codex = try MCPHostSetup.setup(
            files: box.files(.codex), configuration: configuration, servers: nil, rvPath: "/opt/rv",
            configDirectory: box.config
        ).get()
        #expect(codex.manualSteps == ["codex mcp remove 'wax' && codex mcp add 'wax' -- '/opt/rv' mcp serve --server 'wax'"])
        let quoted = try MCPHostSetup.setup(
            files: box.files(.codex), configuration: configuration, servers: nil, rvPath: "/opt/my rv/o'reilly",
            configDirectory: box.config
        ).get()
        #expect(quoted.manualSteps == [
            "codex mcp remove 'wax' && codex mcp add 'wax' -- '/opt/my rv/o'\\''reilly' mcp serve --server 'wax'",
        ])
        #expect(codex.changed.isEmpty)
    }
}

#if os(macOS)
@Suite("MCPSandbox (live sandbox-exec)")
struct MCPSandboxLiveTests {
    @Test func cagedServerCannotReadCredentialsOrWriteOutsideScratch() throws {
        // Not under a temp directory: those stay writable inside the cage by design.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/rv-mcp-cage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let config = home.appendingPathComponent(".config/rv")
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data("PRIVATE".utf8).write(to: ssh.appendingPathComponent("id_ed25519"))
        try Data("{}".utf8).write(to: config.appendingPathComponent("mcp.json"))
        let outside = home.appendingPathComponent("Documents/escape.txt")
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)

        let script = """
            cat \(ssh.path)/id_ed25519 >/dev/null 2>&1 && echo READ_SSH
            cat \(config.path)/mcp.json >/dev/null 2>&1 && echo READ_RV
            echo x > \(outside.path) 2>/dev/null && echo WROTE_OUTSIDE
            echo x > "$PWD/ok.txt" 2>/dev/null && echo WROTE_SCRATCH
            echo done
            """
        var definition = MCPServerDefinition(name: "caged", command: "/bin/sh", args: ["-c", script])
        definition.sandbox = MCPSandboxPolicy(network: false)
        let launch = MCPUpstreamLaunch(
            server: "caged", executable: "/usr/bin/env", arguments: ["/bin/sh", "-c", script], environment: [:])
        let hook = MCPSandbox.apply(configDirectory: config, home: home)
        let caged = try hook(definition, launch).get()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: caged.executable)
        process.arguments = caged.arguments
        process.environment = caged.environment
        if let directory = caged.workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        #expect(output.contains("done"))
        #expect(output.contains("READ_SSH") == false)
        #expect(output.contains("READ_RV") == false)
        #expect(output.contains("WROTE_OUTSIDE") == false)
        #expect(FileManager.default.fileExists(atPath: outside.path) == false)
        #expect(output.contains("WROTE_SCRATCH"))
    }
}
#endif
