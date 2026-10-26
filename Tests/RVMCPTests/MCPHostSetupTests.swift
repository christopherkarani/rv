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
        _ name: String, host: MCPHost = .cursor, transport: MCPTransport, environment: [String: String] = [:],
        headers: [String: String] = [:], remoteTransport: MCPRemoteTransport? = nil
    ) -> MCPHostEntry {
        var entry = MCPHostEntry(
            host: host, scope: .user, configPath: "~/.cursor/mcp.json", name: name, transport: transport,
            environment: environment, headers: headers)
        entry.remoteTransport = remoteTransport
        return entry
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
            configuration: MCPConfiguration(), secrets: SecretsConfiguration())

        let context7 = try #require(plan.servers.first { $0.name == "context7" })
        #expect(context7.command == "npx")
        #expect(context7.args == ["-y", "@upstash/context7-mcp", "--api-key", "${secret:CONTEXT7_API_KEY}"])
        #expect(context7.secrets == ["GITHUB_TOKEN": "GITHUB_TOKEN"])
        #expect(context7.environment == ["LOG_LEVEL": "info"])
        #expect(context7.tools.defaultDecision == nil)
        #expect(context7.tools.ask == ["*"])
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
            configuration: configuration, secrets: SecretsConfiguration())
        let notes = try #require(plan.servers.first { $0.name == "notes" })
        #expect(notes.tools.defaultDecision == nil)
        #expect(notes.tools.ask == ["*"])
        #expect(notes.environment == ["PATH": "/tmp/evil", "GIT_SSH_COMMAND": "evil-ssh", "LD_PRELOAD": "/tmp/p.so"])
        #expect(notes.secrets == ["GITHUB_TOKEN": "GITHUB_TOKEN"])
        configuration.servers.append(notes)
        #expect(configuration.defaultDecision == .allow)
        #expect(configuration.decision(server: notes, tool: "status") == .ask)
        let kept = try #require(configuration.server(named: "kept"))
        #expect(kept.tools.defaultDecision == nil)
        #expect(configuration.decision(server: kept, tool: "anything") == .deny)
    }

    @Test func skipsGovernedRemoteExistingAndAvoidsSecretNameCollisions() {
        let configuration = MCPConfiguration(servers: [MCPServerDefinition(name: "existing", command: "x")])
        let secrets = SecretsConfiguration(secrets: [
            SecretDefinition(name: "API_TOKEN", source: .hostEnvironment(variable: "A"), delivery: .environment)
        ])
        let plan = MCPImport.plan(
            entries: [
                entry("governed", transport: .stdio(command: "/usr/local/bin/rv", args: ["mcp", "serve", "--server", "governed"])),
                entry("remote", transport: .remote(url: "http://mcp.example.com")),
                entry("existing", transport: .stdio(command: "x", args: [])),
                entry("svc", transport: .stdio(command: "svc", args: []), environment: ["API_TOKEN": "tok_live_abcdefghijklmnop"]),
            ],
            configuration: configuration, secrets: secrets)
        #expect(plan.skipped.map(\.name) == ["governed", "remote", "existing"])
        #expect(plan.servers.map(\.name) == ["svc"])
        #expect(plan.servers.first?.secrets == ["API_TOKEN": "SVC_API_TOKEN"])
        #expect(plan.servers.first?.tools.defaultDecision == nil)
        #expect(plan.servers.first?.tools.ask == ["*"])
    }

    @Test func remoteEntriesImportWithHeaderCredentialsAsSecrets() throws {
        let plan = MCPImport.plan(
            entries: [
                entry(
                    "linear", transport: .remote(url: "https://mcp.linear.app/mcp"),
                    headers: [
                        "Authorization": "Bearer lin_api_abcdefghijklmnopqrstuvwx", "X-Team": "eng", "X-Env": "${LINEAR_ENV}",
                        "Mcp-Session-Id": "abc",
                    ]),
                entry(
                    "legacy", transport: .remote(url: "https://legacy.example/sse"),
                    headers: ["X-API-Key": "k_0123456789abcdefghijklmnop"], remoteTransport: .sse),
                entry("leaky", transport: .remote(url: "https://a.example/mcp?api_key=0123456789abcdefghijklmnop")),
                entry("plain", transport: .remote(url: "http://a.example/mcp")),
            ],
            configuration: MCPConfiguration(), secrets: SecretsConfiguration())

        let linear = try #require(plan.servers.first { $0.name == "linear" }?.remote)
        #expect(linear.url.absoluteString == "https://mcp.linear.app/mcp" && linear.transport == .http)
        #expect(linear.headers == ["Authorization": "Bearer ${secret:LINEAR_AUTHORIZATION}", "X-Team": "eng"])
        #expect(plan.notes.contains { $0.contains("linear: header X-Env referenced ${LINEAR_ENV}") })
        #expect(plan.notes.contains { $0.contains("linear: dropped header Mcp-Session-Id") })
        let legacy = try #require(plan.servers.first { $0.name == "legacy" }?.remote)
        #expect(legacy.transport == .sse && legacy.headers == ["X-API-Key": "${secret:LEGACY_X_API_KEY}"])
        #expect(plan.secrets.map(\.definition.name).sorted() == ["LEGACY_X_API_KEY", "LINEAR_AUTHORIZATION"])
        #expect(plan.secrets.first { $0.definition.name == "LINEAR_AUTHORIZATION" }?.value == "lin_api_abcdefghijklmnopqrstuvwx")

        #expect(plan.skipped.first { $0.name == "leaky" }?.reason.contains("secret in its query") == true)
        #expect(plan.skipped.first { $0.name == "plain" }?.reason == "url must be https (http only to localhost)")
        let encoded = MCPConfiguration(servers: plan.servers).encoded().prettyText
        #expect(encoded.contains("lin_api_") == false && encoded.contains("k_0123") == false)
        #expect(try MCPConfiguration.decode(Data(encoded.utf8)).get().servers.count == 2)
    }

    @Test func hostRemoteEntriesCarryTheirTransport() throws {
        func remote(_ host: MCPHost, _ fields: [String: String]) -> MCPRemoteTransport? {
            var object = JSONObject()
            for (key, value) in fields { object[key] = .string(value) }
            let file = MCPHostFile(
                host: host, scope: .user, path: URL(fileURLWithPath: "/x.json"), format: .json(keyPath: ["mcpServers"], lenient: true, opencode: false))
            return MCPInventory.standardEntry(name: "s", object: object, file: file)?.remoteTransport
        }
        #expect(remote(.cursor, ["url": "https://a.example/sse", "type": "sse"]) == .sse)
        #expect(remote(.vscode, ["url": "https://a.example/mcp", "type": "http"]) == .http)
        #expect(remote(.claudeCode, ["url": "https://a.example/mcp"]) == nil)
        #expect(remote(.gemini, ["url": "https://a.example/sse"]) == .sse)
        #expect(remote(.gemini, ["httpUrl": "https://a.example/mcp"]) == .http)
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
            MCPServerDefinition(
                name: "s", command: "srv", args: ["--api-key", "${secret:S_KEY}"],
                sandbox: MCPSandboxPolicy(network: false))
        ])
        let secrets = SecretsConfiguration(secrets: [
            SecretDefinition(name: "S_KEY", source: .hostEnvironment(variable: "UNUSED"), delivery: .environment)
        ])
        let resolver = SecretResolver { _ in .success(SecretValue("tok_arg_value_123")!) }
        let planned = try MCPLaunchPlanner.plan(
            servers: ["s"], configuration: configuration, secrets: secrets, resolver: resolver, baseEnvironment: [:]
        ).get()
        #expect(planned[0].1.process?.arguments == ["srv", "--api-key", "tok_arg_value_123"])
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
        let environment = try #require(planned[0].1.process).environment
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
        guard case .failure(.sandbox) = MCPLaunchPlanner.plan(
            servers: ["s"], configuration: MCPConfiguration(servers: [plain]), secrets: secrets, resolver: resolver,
            baseEnvironment: base, requireSandbox: true
        ) else {
            Issue.record("launch without a sandbox must be refused where the cage is enforced")
            return
        }
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

    @Test func setupEscapesTheConfigPathAndTheRvPath() throws {
        let sentence = "ok: every MCP server is governed by rv, allowed direct, or disabled"
        let raw = "\u{1B}[2J\u{1B}[H" + sentence
        let broken = "\u{2028}" + sentence
        let reversed = "\u{202E}" + sentence
        func escaped(_ text: String) {
            #expect(text.unicodeScalars.contains { $0.value == 0x1B } == false)
            #expect(text.unicodeScalars.contains { $0.value == 0x2028 } == false)
            #expect(text.unicodeScalars.contains { $0.value == 0x202E } == false)
            let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\u{2028}" || $0 == "\u{2029}" }).map(String.init)
            #expect(lines.contains(sentence) == false)
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-setup-path-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("proj" + broken, isDirectory: true)
        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let hostFile = project.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.createDirectory(at: hostFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = #"{"mcpServers":{"wax":{"command":"wax-mcp"}}}"#
        try Data(body.utf8).write(to: hostFile)
        let file = MCPHostFile(
            host: .cursor, scope: .project(project.path), path: hostFile,
            format: .json(keyPath: ["mcpServers"], lenient: false, opencode: false))
        let changed = try MCPHostSetup.setup(
            files: [file], configuration: configuration, servers: nil, rvPath: "/opt/rv",
            configDirectory: config
        ).get()
        let changedText = changed.changed.joined(separator: "\n")
        escaped(changedText)
        #expect(changedText.contains("wax"))
        #expect(changedText.contains("\\u2028"))

        let unread = project.appendingPathComponent("broken" + raw, isDirectory: true)
        try FileManager.default.createDirectory(at: unread, withIntermediateDirectories: true)
        let bad = unread.appendingPathComponent("mcp.json")
        try Data("{".utf8).write(to: bad)
        let failed = MCPHostSetup.setup(
            files: [MCPHostFile(
                host: .cursor, scope: .project(unread.path), path: bad,
                format: .json(keyPath: ["mcpServers"], lenient: true, opencode: false))],
            configuration: configuration, servers: nil, rvPath: "/opt/rv",
            configDirectory: config)
        guard case .failure(let error) = failed else {
            Issue.record("unreadable setup was accepted")
            return
        }
        escaped(error.message)
        #expect(error.message.contains("could not read"))
        #expect(error.message.contains("\\u001b[2J"))

        let record = MCPSetupRecord(
            host: MCPHost.cursor.rawValue, configPath: project.path + reversed, keyPath: ["mcpServers"],
            name: "wax", original: .object([:]), written: .object([:]))
        #expect(MCPHostSetup.saveManifest([record], config))
        let undo = try MCPHostSetup.undo(host: .cursor, servers: nil, configDirectory: config).get()
        let undoText = undo.skipped.joined(separator: "\n")
        escaped(undoText)
        #expect(undoText.contains("missing or unreadable"))
        #expect(undoText.contains("\\u202e"))

        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try Data("[mcp_servers.wax]\ncommand = \"npx\"\n".utf8).write(to: codexHome.appendingPathComponent(".codex/config.toml"))
        let codex = try MCPHostSetup.setup(
            files: MCPHostFile.all(home: codexHome, project: nil, environment: [:]).filter { $0.host == .codex },
            configuration: configuration, servers: nil, rvPath: raw,
            configDirectory: config
        ).get()
        let manual = codex.manualSteps.joined(separator: "\n")
        escaped(manual)
        #expect(manual.contains("--"))
        #expect(manual.contains("\\u001b[2J"))
        #expect(manual.contains("'wax'"))
    }
}

#if os(macOS)
@Suite("MCPSandbox (live sandbox-exec)")
struct MCPSandboxLiveTests {
    @Test func cagedServerCannotReadCredentialsOrWriteOutsideScratch() throws {
        // Not under a temp directory: those stay writable inside the cage by
        // design — and not under the checkout either, since a checkout in
        // /tmp is under a temp root. The real home directory is outside every
        // writable prefix the profile grants.
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".rv-cage-test-\(UUID().uuidString)")
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
        // Built from profile() directly: apply() refuses a home that is not
        // the passwd home, and this fixture's home is deliberately fake.
        let scratch = home.appendingPathComponent("Library/Caches/rv-mcp/caged", isDirectory: true)
        #expect(MCPSandbox.createCheckedDirectory(scratch.path))
        let text = try MCPSandbox.profile(
            policy: try #require(definition.sandbox), scratch: scratch.path, home: home.path,
            configDirectory: config.path, temporaryDirectory: NSTemporaryDirectory()).get()
        var caged = launch
        caged.executable = MCPSandbox.sandboxExec
        caged.arguments = ["-p", text, launch.executable] + launch.arguments
        caged.workingDirectory = scratch.path

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
