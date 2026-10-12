#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import Testing
@testable import RVPolicy

@Suite("MCP integration store")
struct MCPIntegrationStoreTests {
    @Test func validRemoteLoadsWithEveryField() throws {
        var remote = Self.validRemote()
        remote["remoteTransport"] = "sse"
        remote["namespace"] = "github"
        remote["queryParams"] = [
            "plain": "value",
            "token": "secret-public-ref:file/ci-token",
        ]
        remote["headers"] = [
            "X-Literal": "yes",
            "X-Secret": [
                "secret": ["provider": "keychain", "item": "svc/acct", "field": "token"],
                "prefix": "Bearer ",
            ] as [String: Any],
        ]
        remote["auth"] = [
            "kind": "header",
            "headerName": "Authorization",
            "secret": ["provider": "vault-http", "item": "deploy/api", "field": "key"],
            "prefix": "Bearer ",
        ]
        let loaded = try MCPIntegrationStore.decode(try Self.documentData([remote])).get()
        #expect(loaded.integrations.count == 1)
        let config = try #require(loaded.integrations.first)
        guard case .remote(let integration) = config else {
            Issue.record("expected remote integration")
            return
        }
        #expect(integration.name == "GitHub")
        #expect(integration.endpoint == "https://api.example.com/mcp")
        #expect(integration.remoteTransport == .sse)
        #expect(integration.namespace == "github")
        #expect(integration.resolvedNamespace == "github")
        #expect(integration.queryParams?["plain"] == .literal("value"))
        #expect(
            integration.queryParams?["token"]
                == .secret(MCPSecretSelector(provider: "file", item: "ci-token"), prefix: nil)
        )
        #expect(integration.headers?["X-Literal"] == .literal("yes"))
        #expect(
            integration.headers?["X-Secret"]
                == .secret(
                    MCPSecretSelector(provider: "keychain", item: "svc/acct", field: "token"),
                    prefix: "Bearer "
                )
        )
        #expect(
            integration.auth
                == .header(
                    headerName: "Authorization",
                    secret: MCPSecretSelector(provider: "vault-http", item: "deploy/api", field: "key"),
                    prefix: "Bearer "
                )
        )
        #expect(config.name == "GitHub")
        #expect(config.explicitNamespace == "github")
        #expect(config.resolvedNamespace == "github")
        #expect(loaded.integration(namespace: "github") == config)
    }

    @Test func validStdioLoadsWithEveryField() throws {
        var stdio = Self.validStdio()
        stdio["args"] = ["serve", "--port", "8080"]
        stdio["env"] = ["LOG_LEVEL": "debug", "WORKERS": "4"]
        stdio["cwd"] = "/tmp/work"
        stdio["namespace"] = "helper"
        let loaded = try MCPIntegrationStore.decode(try Self.documentData([stdio])).get()
        #expect(loaded.integrations.count == 1)
        let config = try #require(loaded.integrations.first)
        guard case .stdio(let integration) = config else {
            Issue.record("expected stdio integration")
            return
        }
        #expect(integration.name == "Helper")
        #expect(integration.command == "/usr/local/bin/mcp-helper")
        #expect(integration.args == ["serve", "--port", "8080"])
        #expect(integration.env == ["LOG_LEVEL": "debug", "WORKERS": "4"])
        #expect(integration.cwd == "/tmp/work")
        #expect(integration.namespace == "helper")
        #expect(integration.resolvedNamespace == "helper")
        #expect(config.name == "Helper")
        #expect(config.explicitNamespace == "helper")
    }

    @Test func minimalDocumentsLoadWithDefaults() throws {
        let loaded = try MCPIntegrationStore.decode(
            try Self.documentData([Self.validRemote(), Self.validStdio()])
        ).get()
        #expect(loaded.integrations.count == 2)
        guard case .remote(let remote) = loaded.integrations[0] else {
            Issue.record("expected remote first")
            return
        }
        #expect(remote.remoteTransport == .auto)
        #expect(remote.namespace == nil)
        #expect(remote.queryParams == nil)
        #expect(remote.headers == nil)
        #expect(remote.auth == .none)
        #expect(remote.resolvedNamespace == "github")
        guard case .stdio(let stdio) = loaded.integrations[1] else {
            Issue.record("expected stdio second")
            return
        }
        #expect(stdio.args == nil)
        #expect(stdio.env == nil)
        #expect(stdio.cwd == nil)
        #expect(stdio.namespace == nil)
        #expect(stdio.resolvedNamespace == "helper")
    }

    @Test func emptyIntegrationsLoad() throws {
        let loaded = try MCPIntegrationStore.decode(try Self.documentData([])).get()
        #expect(loaded == .empty)
        #expect(loaded.integrations.isEmpty)
        #expect(loaded.integration(namespace: "anything") == nil)
        #expect(MCPIntegrationSet.empty.integrations.isEmpty)
    }

    @Test func missingFileLoadsEmpty() throws {
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try MCPIntegrationStore.load(from: directory).get() == .empty)
    }

    @Test func missingDirectoryLoadsEmpty() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-mcp-integrations-missing-\(UUID().uuidString)")
        #expect(MCPIntegrationStore.load(from: directory) == .success(.empty))
    }

    @Test func fileAsDirectoryIsUnsafeLocation() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-mcp-integrations-fileasdir-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(MCPIntegrationStore.load(from: file) == .failure(.unsafeLocation))
    }

    @Test func onlyOwnerFilesWithoutSymlinksAreLoaded() throws {
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Self.writeConfigFile(
            try Self.documentData([Self.validRemote()]),
            named: MCPIntegrationStore.fileName,
            in: directory
        )
        #expect(try MCPIntegrationStore.load(from: directory).get().integrations.count == 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(MCPIntegrationStore.load(from: directory) == .failure(.unsafeLocation))
        try FileManager.default.removeItem(at: file)
        let target = directory.appendingPathComponent("target.json")
        try Self.documentData([Self.validRemote()]).write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        #expect(MCPIntegrationStore.load(from: directory) == .failure(.unsafeLocation))
        try FileManager.default.removeItem(at: file)
        try Self.documentData([Self.validRemote()]).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
        #expect(MCPIntegrationStore.load(from: directory) == .failure(.unsafeLocation))
    }

    @Test func symlinkedDirectoryAndNonRegularFileAreRejected() throws {
        let base = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(
            at: real, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = try Self.writeConfigFile(
            try Self.documentData([Self.validRemote()]),
            named: MCPIntegrationStore.fileName,
            in: real
        )
        #expect(try MCPIntegrationStore.load(from: real).get().integrations.count == 1)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(MCPIntegrationStore.load(from: link) == .failure(.unsafeLocation))
        let impostor = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: impostor) }
        try FileManager.default.createDirectory(
            at: impostor.appendingPathComponent(MCPIntegrationStore.fileName, isDirectory: true),
            withIntermediateDirectories: true
        )
        #expect(MCPIntegrationStore.load(from: impostor) == .failure(.unsafeLocation))
    }

    @Test func oversizedDocumentsAreRejected() throws {
        #expect(
            MCPIntegrationStore.decode(Data(repeating: 0, count: 65_537)) == .failure(.oversized)
        )
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Self.writeConfigFile(
            Data(repeating: 0x20, count: 65_537),
            named: MCPIntegrationStore.fileName,
            in: directory
        )
        #expect(file.lastPathComponent == "mcp-integrations.json")
        #expect(MCPIntegrationStore.load(from: directory) == .failure(.oversized))
    }

    @Test func byteCapBoundaryIsInclusive() {
        // Exactly 64KB passes the size gate (and then fails as JSON, which
        // proves the oversized arm did not fire).
        #expect(
            MCPIntegrationStore.decode(Data(repeating: 0x20, count: 65_536)) == .failure(.invalidDocument)
        )
    }

    @Test func unsupportedVersionsFailClosed() throws {
        for version in [0, 2, 99] {
            #expect(
                MCPIntegrationStore.decode(
                    try Self.documentData([Self.validRemote()], version: version)
                ) == .failure(.unsupportedVersion)
            )
        }
        #expect(
            MCPIntegrationStore.decode(
                try Self.documentData([Self.validRemote()], version: "1")
            ) == .failure(.invalidDocument)
        )
    }

    @Test func malformedDocumentsFailClosed() throws {
        #expect(MCPIntegrationStore.decode(Data("not json".utf8)) == .failure(.invalidDocument))
        #expect(MCPIntegrationStore.decode(Data()) == .failure(.invalidDocument))
        #expect(MCPIntegrationStore.decode(Data("[]".utf8)) == .failure(.invalidDocument))
        #expect(MCPIntegrationStore.decode(Data("{}".utf8)) == .failure(.invalidDocument))
        #expect(
            MCPIntegrationStore.decode(Data("null".utf8)) == .failure(.invalidDocument)
        )
        for document: [String: Any] in [
            ["version": 1],
            ["integrations": [Self.validRemote()]],
            ["version": 1, "integrations": NSNull()],
            ["version": 1, "integrations": "nope"],
            ["version": 1, "integrations": ["name": "x"]],
            ["version": 1, "integrations": ["nope"]],
            ["version": 1, "integrations": [42]],
            ["version": 1, "integrations": [["name": "x", "endpoint": "https://h"]]],
            ["version": 1, "integrations": [["kind": 42]]],
            ["version": 1, "integrations": [["kind": NSNull()]]],
            ["version": NSNull(), "integrations": [Self.validRemote()]],
            ["version": 1.5, "integrations": [Self.validRemote()]],
        ] {
            #expect(
                MCPIntegrationStore.decode(try JSONSerialization.data(withJSONObject: document))
                    == .failure(.invalidDocument)
            )
        }
    }

    @Test(
        "unknown integration kind rejected",
        arguments: ["mcp", "openapi", "graphql", "remote", "stdio", "MCP-REMOTE", "", "mcp_remote"]
    )
    func unknownKind_rejected(kind: String) throws {
        var remote = Self.validRemote()
        remote["kind"] = kind
        #expect(
            MCPIntegrationStore.decode(try Self.documentData([remote])) == .failure(.invalidDocument)
        )
    }

    @Test func unknownKeysFailClosed() throws {
        let top = try JSONSerialization.data(
            withJSONObject: [
                "version": 1, "integrations": [Self.validRemote()], "future": true,
            ]
        )
        #expect(MCPIntegrationStore.decode(top) == .failure(.invalidDocument))
        // Remote-level smuggled fields, including Executor-only members that
        // must not silently ride along (transport/family/appServer).
        for key in ["mystery", "secretValue", "apiKey", "token", "transport", "family", "appServer"] {
            var remote = Self.validRemote()
            remote[key] = "hunter2"
            #expect(
                MCPIntegrationStore.decode(try Self.documentData([remote]))
                    == .failure(.invalidDocument)
            )
        }
        for key in ["mystery", "secretValue", "spawnPerCall", "family", "versionNegotiation"] {
            var stdio = Self.validStdio()
            stdio[key] = "hunter2"
            #expect(
                MCPIntegrationStore.decode(try Self.documentData([stdio]))
                    == .failure(.invalidDocument)
            )
        }
        // Auth-level extras: none takes nothing, header/oauth2 take theirs.
        for auth in [
            ["kind": "none", "connectionId": "x"],
            ["kind": "header", "headerName": "X", "secret": ["provider": "file", "item": "x"], "connectionId": "y"],
            ["kind": "oauth2", "connectionId": "x", "secret": "y"],
            ["kind": "oauth2", "connectionId": "x", "prefix": "Bearer "],
        ] as [[String: Any]] {
            var remote = Self.validRemote()
            remote["auth"] = auth
            #expect(
                MCPIntegrationStore.decode(try Self.documentData([remote]))
                    == .failure(.invalidDocument)
            )
        }
        // Executor's {value, prefix} header form is deliberately rejected:
        // a literal needs no prefix wrapper, and a ref uses the secret form.
        var executorForm = Self.validRemote()
        executorForm["headers"] = ["X-T": ["value": "secret-public-ref:file/x", "prefix": "Bearer "]]
        #expect(
            MCPIntegrationStore.decode(try Self.documentData([executorForm]))
                == .failure(.invalidDocument)
        )
        var secretExtra = Self.validRemote()
        secretExtra["headers"] = [
            "X-T": ["secret": ["provider": "file", "item": "x"], "prefix": "B", "extra": 1] as [String: Any]
        ]
        #expect(
            MCPIntegrationStore.decode(try Self.documentData([secretExtra]))
                == .failure(.invalidDocument)
        )
        var selectorExtra = Self.validRemote()
        selectorExtra["headers"] = [
            "X-T": ["secret": ["provider": "file", "item": "x", "purpose": "y"]] as [String: Any]
        ]
        #expect(
            MCPIntegrationStore.decode(try Self.documentData([selectorExtra]))
                == .failure(.invalidDocument)
        )
    }

    @Test func integrationCountCapEnforced() throws {
        func entry(_ index: Int) -> [String: Any] {
            var remote = Self.validRemote(name: "Service \(index)")
            remote["namespace"] = "service-\(index)"
            return remote
        }
        let thirtyTwo = try MCPIntegrationStore.decode(
            try Self.documentData((0..<32).map(entry))
        ).get()
        #expect(thirtyTwo.integrations.count == 32)
        #expect(
            MCPIntegrationStore.decode(try Self.documentData((0..<33).map(entry)))
                == .failure(.invalidDocument)
        )
        // Mixed kinds count together.
        var mixed = (0..<31).map(entry)
        var stdio = Self.validStdio(name: "Helper 31")
        stdio["namespace"] = "service-31"
        mixed.append(stdio)
        #expect(try MCPIntegrationStore.decode(try Self.documentData(mixed)).get().integrations.count == 32)
    }

    @Test func nameRules() throws {
        for name in ["a", String(repeating: "n", count: 256), "GitHub MCP", " x ", "tökén-🔑-名前"] {
            for entry in [Self.validRemote(name: name), Self.validStdio(name: name)] {
                let loaded = try MCPIntegrationStore.decode(try Self.documentData([entry])).get()
                #expect(loaded.integrations[0].name == name)
            }
        }
        for name in ["", String(repeating: "n", count: 257), "has\0nul", "has\nnewline", "has\rcarriage"] {
            for entry in [Self.validRemote(name: name), Self.validStdio(name: name)] {
                #expect(
                    MCPIntegrationStore.decode(try Self.documentData([entry]))
                        == .failure(.invalidDocument)
                )
            }
        }
        // Mistyped names are malformed, not merely invalid values.
        for entry in [
            Self.validRemote(extra: ["name": 42]), Self.validStdio(extra: ["name": ["nested"]]),
        ] {
            #expect(
                MCPIntegrationStore.decode(try Self.documentData([entry])) == .failure(.invalidDocument)
            )
        }
    }

    @Test func namespaceRules() throws {
        for namespace in ["a", String(repeating: "b", count: 64), "a-b_c.d9", "0", "UPPER"] {
            for entry in [
                Self.validRemote(extra: ["namespace": namespace]),
                Self.validStdio(extra: ["namespace": namespace]),
            ] {
                let loaded = try MCPIntegrationStore.decode(try Self.documentData([entry])).get()
                #expect(loaded.integrations[0].explicitNamespace == namespace)
            }
        }
        for namespace in [
            "", String(repeating: "b", count: 65), "has space", "has/slash", "has:colon",
            "tökén", "has\nnewline", "has\0nul", "under/score_ok?", "semi;colon",
        ] {
            for entry in [
                Self.validRemote(extra: ["namespace": namespace]),
                Self.validStdio(extra: ["namespace": namespace]),
            ] {
                #expect(
                    MCPIntegrationStore.decode(try Self.documentData([entry]))
                        == .failure(.invalidDocument)
                )
            }
        }
        #expect(
            MCPIntegrationStore.decode(
                try Self.documentData([Self.validRemote(extra: ["namespace": 42])])
            ) == .failure(.invalidDocument)
        )
    }

    @Test func duplicateResolvedNamespacesFailClosed() throws {
        // Explicit duplicates.
        #expect(
            MCPIntegrationStore.decode(
                try Self.documentData([
                    Self.validRemote(extra: ["namespace": "dup"]),
                    Self.validRemote(extra: ["namespace": "dup", "name": "Other"]),
                ])
            ) == .failure(.invalidDocument)
        )
        // Derived duplicates: same blank-namespace name twice.
        #expect(
            MCPIntegrationStore.decode(
                try Self.documentData([
                    Self.validRemote(name: "Same Name"),
                    Self.validStdio(name: "Same Name"),
                ])
            ) == .failure(.invalidDocument)
        )
        // Explicit-vs-derived collision.
        #expect(
            MCPIntegrationStore.decode(
                try Self.documentData([
                    Self.validRemote(extra: ["namespace": "github_mcp", "name": "Other"]),
                    Self.validRemote(name: "GitHub MCP"),
                ])
            ) == .failure(.invalidDocument)
        )
        // Distinct namespaces load, and matching is case-sensitive.
        let loaded = try MCPIntegrationStore.decode(
            try Self.documentData([
                Self.validRemote(extra: ["namespace": "Ab"]),
                Self.validStdio(extra: ["namespace": "ab"]),
            ])
        ).get()
        #expect(loaded.integrations.count == 2)
    }

    @Test func remoteTransportMatrix() throws {
        for raw in ["streamable-http", "sse", "auto"] {
            let loaded = try MCPIntegrationStore.decode(
                try Self.documentData([Self.validRemote(extra: ["remoteTransport": raw])])
            ).get()
            guard case .remote(let remote) = loaded.integrations[0] else {
                Issue.record("expected remote")
                return
            }
            #expect(remote.remoteTransport.rawValue == raw)
        }
        for raw in ["", "STDIO", "http", "stdio", " auto", "auto ", "streamable_http", "poll"] {
            #expect(
                MCPIntegrationStore.decode(
                    try Self.documentData([Self.validRemote(extra: ["remoteTransport": raw])])
                ) == .failure(.invalidDocument)
            )
        }
        #expect(
            MCPIntegrationStore.decode(
                try Self.documentData([Self.validRemote(extra: ["remoteTransport": 42])])
            ) == .failure(.invalidDocument)
        )
        // Null reads as absent, which reads as auto.
        let nulled = try MCPIntegrationStore.decode(
            try Self.documentData([Self.validRemote(extra: ["remoteTransport": NSNull()])])
        ).get()
        guard case .remote(let remote) = nulled.integrations[0] else {
            Issue.record("expected remote")
            return
        }
        #expect(remote.remoteTransport == .auto)
    }

    @Test func endpointRules() throws {
        for endpoint in [
            "http://h", "https://h", "https://h/", "HTTP://EXAMPLE.COM",
            "http://192.168.1.1:8080/", "http://[::1]/", "https://tökén.example/mcp",
            "https://h/" + String(repeating: "p", count: 2038),
        ] {
            let loaded = try MCPIntegrationStore.decode(
                try Self.documentData([Self.validRemote(endpoint: endpoint)])
            ).get()
            guard case .remote(let remote) = loaded.integrations[0] else {
                Issue.record("expected remote")
                return
            }
            #expect(remote.endpoint == endpoint)
        }
        for endpoint in [
            "", "ftp://h", "ws://h", "wss://h", "example.com", "/relative", "http://",
            "https://", "https://h/a b", "https://h\ta", "https://h\0", "https://h\n", "https://h\r",
            "https://h/\u{7F}", "https://h/\u{80}", "https://user@h/", "https://user:pass@h/",
            "https://h:8443/p?q=1#f", "https://h/p?x=1", "https://h/p#f", "https://h?", "https://h#",
            "https://h/" + String(repeating: "p", count: 2039),
        ] {
            #expect(
                MCPIntegrationStore.decode(
                    try Self.documentData([Self.validRemote(endpoint: endpoint)])
                ) == .failure(.invalidDocument)
            )
        }
        #expect(
            MCPIntegrationStore.decode(
                try Self.documentData([Self.validRemote(extra: ["endpoint": 42])])
            ) == .failure(.invalidDocument)
        )
        var missing = Self.validRemote()
        missing.removeValue(forKey: "endpoint")
        #expect(
            MCPIntegrationStore.decode(try Self.documentData([missing])) == .failure(.invalidDocument)
        )
    }

    @Test func commandRules() throws {
        for command in ["/x", "/usr/local/bin/mcp-helper", "/tökén/bin", "/" + String(repeating: "c", count: 1023)] {
            let loaded = try MCPIntegrationStore.decode(
                try Self.documentData([Self.validStdio(command: command)])
            ).get()
            guard case .stdio(let stdio) = loaded.integrations[0] else {
                Issue.record("expected stdio")
                return
            }
            #expect(stdio.command == command)
        }
        for command in [
            "", "/", "relative", "bin/x", "/" + String(repeating: "c", count: 1024), "//", "/a//b",
            "/a/./b", "/a/../b", "/a/", "/a\0", "/a\n", "/a\r",
        ] {
            #expect(
                MCPIntegrationStore.decode(
                    try Self.documentData([Self.validStdio(command: command)])
                ) == .failure(.invalidDocument)
            )
        }
        #expect(
            MCPIntegrationStore.decode(
                try Self.documentData([Self.validStdio(extra: ["command": 42])])
            ) == .failure(.invalidDocument)
        )
        var missing = Self.validStdio()
        missing.removeValue(forKey: "command")
        #expect(
            MCPIntegrationStore.decode(try Self.documentData([missing])) == .failure(.invalidDocument)
        )
    }

    @Test func cwdRules() throws {
        let loaded = try MCPIntegrationStore.decode(
            try Self.documentData([Self.validStdio(extra: ["cwd": "/tmp/work"])])
        ).get()
        guard case .stdio(let stdio) = loaded.integrations[0] else {
            Issue.record("expected stdio")
            return
        }
        #expect(stdio.cwd == "/tmp/work")
        for cwd in ["relative", "", "/", "/a/../b"] as [Any] {
            #expect(
                MCPIntegrationStore.decode(
                    try Self.documentData([Self.validStdio(extra: ["cwd": cwd])])
                ) == .failure(.invalidDocument)
            )
        }
        #expect(
            MCPIntegrationStore.decode(
                try Self.documentData([Self.validStdio(extra: ["cwd": 42])])
            ) == .failure(.invalidDocument)
        )
        let nulled = try MCPIntegrationStore.decode(
            try Self.documentData([Self.validStdio(extra: ["cwd": NSNull()])])
        ).get()
        guard case .stdio(let nulledStdio) = nulled.integrations[0] else {
            Issue.record("expected stdio")
            return
        }
        #expect(nulledStdio.cwd == nil)
    }

    @Test func argsRules() throws {
        for args in [
            [], ["serve"], ["--port", "8080", "with space"], ["tökén"], [String(repeating: "a", count: 1024)],
            (0..<64).map { "arg-\($0)" },
        ] as [[String]] {
            let loaded = try MCPIntegrationStore.decode(
                try Self.documentData([Self.validStdio(extra: ["args": args])])
            ).get()
            guard case .stdio(let stdio) = loaded.integrations[0] else {
                Issue.record("expected stdio")
                return
            }
            #expect(stdio.args == args)
        }
        for args in [
            [""], ["ok", ""], [String(repeating: "a", count: 1025)], ["has\0nul"],
            ["has\nnewline"], ["has\rcarriage"], (0..<65).map { "arg-\($0)" },
        ] as [[String]] {
            #expect(
                MCPIntegrationStore.decode(
                    try Self.documentData([Self.validStdio(extra: ["args": args])])
                ) == .failure(.invalidDocument)
            )
        }
        for mistyped: Any in ["serve", 42, ["ok", NSNull()], ["ok", 42]] {
            #expect(
                MCPIntegrationStore.decode(
                    try Self.documentData([Self.validStdio(extra: ["args": mistyped])])
                ) == .failure(.invalidDocument)
            )
        }
        let nulled = try MCPIntegrationStore.decode(
            try Self.documentData([Self.validStdio(extra: ["args": NSNull()])])
        ).get()
        guard case .stdio(let stdio) = nulled.integrations[0] else {
            Issue.record("expected stdio")
            return
        }
        #expect(stdio.args == nil)
    }

    @Test func envRules() throws {
        for env in [
            [:], ["LOG_LEVEL": "debug"], ["EMPTY_OK": "x y", "UNI": "tökén"],
            ["MAX": String(repeating: "v", count: 1024)],
            Dictionary(uniqueKeysWithValues: (0..<32).map { ("VAR_\($0)", "v") }),
        ] as [[String: String]] {
            let loaded = try MCPIntegrationStore.decode(
                try Self.documentData([Self.validStdio(extra: ["env": env])])
            ).get()
            guard case .stdio(let stdio) = loaded.integrations[0] else {
                Issue.record("expected stdio")
                return
            }
            #expect(stdio.env == env)
        }
        // A secret-ref value fails closed: refs are meaningless to execve
        // and would leak the marker into the child environment.
        let refLeak = ["API_KEY": "secret-public-ref:file/api-key"]
        #expect(
            MCPIntegrationStore.decode(
                try Self.documentData([Self.validStdio(extra: ["env": refLeak])])
            ) == .failure(.invalidDocument)
        )
        // The marker is prefix-anchored: mid-string occurrences are inert.
        let midMarker = try MCPIntegrationStore.decode(
            try Self.documentData([
                Self.validStdio(extra: ["env": ["NOTE": "xxsecret-public-ref:file/x"]])
            ])
        ).get()
        guard case .stdio(let midStdio) = midMarker.integrations[0] else {
            Issue.record("expected stdio")
            return
        }
        #expect(midStdio.env == ["NOTE": "xxsecret-public-ref:file/x"])
        for env in [
            ["9LIVES": "x"], ["has-dash": "x"], ["has.dot": "x"], ["": "x"],
            [String(repeating: "V", count: 65): "x"], ["OK": ""], ["OK": String(repeating: "v", count: 1025)],
            ["OK": "has\0nul"], ["OK": "has\nnewline"], ["OK": "has\rcarriage"],
            Dictionary(uniqueKeysWithValues: (0..<33).map { ("VAR_\($0)", "v") }),
        ] as [[String: String]] {
            #expect(
                MCPIntegrationStore.decode(
                    try Self.documentData([Self.validStdio(extra: ["env": env])])
                ) == .failure(.invalidDocument)
            )
        }
        for mistyped: Any in [["A", "B"], 42, ["A": NSNull()], ["A": 42]] {
            #expect(
                MCPIntegrationStore.decode(
                    try Self.documentData([Self.validStdio(extra: ["env": mistyped])])
                ) == .failure(.invalidDocument)
            )
        }
        let nulled = try MCPIntegrationStore.decode(
            try Self.documentData([Self.validStdio(extra: ["env": NSNull()])])
        ).get()
        guard case .stdio(let stdio) = nulled.integrations[0] else {
            Issue.record("expected stdio")
            return
        }
        #expect(stdio.env == nil)
    }

    @Test func headerNameRules() throws {
        // Every tchar symbol is load-bearing for the token classifier, so
        // each appears as a single-character name plus realistic compounds.
        for name in ["X", "X-Custom-Token", "x1", "A9"] + ["!", "#", "$", "%", "&", "'", "*", "+", "-", ".", "^", "_", "`", "|", "~"].map({ "X\($0)Y" }) + [String(repeating: "h", count: 128)] {
            for entry in [
                Self.validRemote(extra: ["headers": [name: "v"]]),
                Self.validRemote(extra: ["auth": ["kind": "header", "headerName": name, "secret": ["provider": "file", "item": "x"]]]),
            ] {
                let loaded = try MCPIntegrationStore.decode(try Self.documentData([entry])).get()
                #expect(loaded.integrations.count == 1)
            }
        }
        for name in [
            "", String(repeating: "h", count: 129), "has space", "X:colon", "X(paren)", "X[bracket]",
            "X{brace}", "X\"quote\"", "X,comma", "X;semi", "X/slash", "X?query", "X@at", "X<angle>",
            "X=equals", "X\\back", "tökén", "X\0", "X\n", "X\r", "X\u{7F}",
        ] {
            for entry in [
                Self.validRemote(extra: ["headers": [name: "v"]]),
                Self.validRemote(extra: ["auth": ["kind": "header", "headerName": name, "secret": ["provider": "file", "item": "x"]]]),
            ] {
                #expect(
                    MCPIntegrationStore.decode(try Self.documentData([entry]))
                        == .failure(.invalidDocument)
                )
            }
        }
        // Auth header names must be strings.
        #expect(
            MCPIntegrationStore.decode(
                try Self.documentData([
                    Self.validRemote(extra: ["auth": ["kind": "header", "headerName": 42, "secret": ["provider": "file", "item": "x"]]])
                ])
            ) == .failure(.invalidDocument)
        )
    }

    @Test func queryKeyRules() throws {
        for key in ["q", "a:b", "a.b-c_d", "Q1", "tökén", String(repeating: "k", count: 128)] {
            let loaded = try MCPIntegrationStore.decode(
                try Self.documentData([Self.validRemote(extra: ["queryParams": [key: "v"]])])
            ).get()
            #expect(loaded.integrations.count == 1)
        }
        for key in [
            "", String(repeating: "k", count: 129), "has space", "a&b", "a=b", "a#b", "a?b",
            "a\0", "a\n", "a\r", "a\u{7F}", "a\tb",
        ] {
            #expect(
                MCPIntegrationStore.decode(
                    try Self.documentData([Self.validRemote(extra: ["queryParams": [key: "v"]])])
                ) == .failure(.invalidDocument)
            )
        }
    }

    @Test func headerValueMatrix() throws {
        // Literals in both positions.
        for map in ["headers", "queryParams"] {
            let loaded = try MCPIntegrationStore.decode(
                try Self.documentData([
                    Self.validRemote(extra: [map: ["K": "v", "Uni": "tökén 🔑", "Max": String(repeating: "v", count: 1024)]])
                ])
            ).get()
            guard case .remote(let remote) = loaded.integrations[0] else {
                Issue.record("expected remote")
                return
            }
            let values = map == "headers" ? remote.headers : remote.queryParams
            #expect(values?["K"] == .literal("v"))
            #expect(values?["Max"] == .literal(String(repeating: "v", count: 1024)))
        }
        // The bare marker without its colon is an ordinary literal.
        let bareMarker = try MCPIntegrationStore.decode(
            try Self.documentData([Self.validRemote(extra: ["headers": ["K": "secret-public-ref"]])])
        ).get()
        guard case .remote(let bareRemote) = bareMarker.integrations[0] else {
            Issue.record("expected remote")
            return
        }
        #expect(bareRemote.headers?["K"] == .literal("secret-public-ref"))
        // Secret string forms (field-less, prefix-less) in both positions.
        for map in ["headers", "queryParams"] {
            let loaded = try MCPIntegrationStore.decode(
                try Self.documentData([
                    Self.validRemote(extra: [map: ["K": "secret-public-ref:file/ci-token"]])
                ])
            ).get()
            guard case .remote(let remote) = loaded.integrations[0] else {
                Issue.record("expected remote")
                return
            }
            let values = map == "headers" ? remote.headers : remote.queryParams
            #expect(
                values?["K"]
                    == .secret(MCPSecretSelector(provider: "file", item: "ci-token"), prefix: nil)
            )
        }
        // Secret object forms: string or object selector, optional prefix.
        let objects = try MCPIntegrationStore.decode(
            try Self.documentData([
                Self.validRemote(extra: ["headers": [
                    "A": ["secret": "secret-public-ref:keychain/svc", "prefix": "Bearer "],
                    "B": ["secret": ["provider": "env", "item": "TOKEN"]],
                    "C": ["secret": ["provider": "file", "item": "rec", "field": "f"], "prefix": NSNull()],
                ]])
            ])
        ).get()
        guard case .remote(let objectRemote) = objects.integrations[0] else {
            Issue.record("expected remote")
            return
        }
        #expect(
            objectRemote.headers?["A"]
                == .secret(MCPSecretSelector(provider: "keychain", item: "svc"), prefix: "Bearer ")
        )
        #expect(
            objectRemote.headers?["B"]
                == .secret(MCPSecretSelector(provider: "env", item: "TOKEN"), prefix: nil)
        )
        #expect(
            objectRemote.headers?["C"]
                == .secret(MCPSecretSelector(provider: "file", item: "rec", field: "f"), prefix: nil)
        )
        // Rejections: bad literals, malformed ref strings, mistyped values.
        for value: Any in [
            "", String(repeating: "v", count: 1025), "has\0nul", "has\nnewline",
            "secret-public-ref:", "secret-public-ref:noslash", "secret-public-ref:/x",
            "secret-public-ref:file/", "secret-public-ref:file",
            42, true, ["array"], NSNull(),
            ["secret": "secret-public-ref:oops"], ["secret": 42], ["secret": NSNull()],
            ["prefix": "x"], ["secret": ["provider": "file", "item": "x"], "prefix": 42],
        ] {
            #expect(
                MCPIntegrationStore.decode(
                    try Self.documentData([Self.validRemote(extra: ["headers": ["K": value]])])
                ) == .failure(.invalidDocument)
            )
        }
        // Mistyped maps.
        for mistyped: Any in ["nope", 42, ["array"]] {
            for map in ["headers", "queryParams"] {
                #expect(
                    MCPIntegrationStore.decode(
                        try Self.documentData([Self.validRemote(extra: [map: mistyped])])
                    ) == .failure(.invalidDocument)
                )
            }
        }
        // Nulls read as absent.
        let nulled = try MCPIntegrationStore.decode(
            try Self.documentData([
                Self.validRemote(extra: ["headers": NSNull(), "queryParams": NSNull()])
            ])
        ).get()
        guard case .remote(let remote) = nulled.integrations[0] else {
            Issue.record("expected remote")
            return
        }
        #expect(remote.headers == nil)
        #expect(remote.queryParams == nil)
    }

    @Test func headerMapCountCapEnforced() throws {
        for map in ["headers", "queryParams"] {
            let thirtyTwo = Dictionary(uniqueKeysWithValues: (0..<32).map { ("K\($0)", "v") })
            let loaded = try MCPIntegrationStore.decode(
                try Self.documentData([Self.validRemote(extra: [map: thirtyTwo])])
            ).get()
            #expect(loaded.integrations.count == 1)
            let thirtyThree = Dictionary(uniqueKeysWithValues: (0..<33).map { ("K\($0)", "v") })
            #expect(
                MCPIntegrationStore.decode(
                    try Self.documentData([Self.validRemote(extra: [map: thirtyThree])])
                ) == .failure(.invalidDocument)
            )
        }
        // Present-but-empty maps load as empty (and stay empty on roundtrip).
        let emptied = try MCPIntegrationStore.decode(
            try Self.documentData([Self.validRemote(extra: ["headers": [:], "queryParams": [:]])])
        ).get()
        guard case .remote(let remote) = emptied.integrations[0] else {
            Issue.record("expected remote")
            return
        }
        #expect(remote.headers == [:])
        #expect(remote.queryParams == [:])
    }

    @Test func authKindMatrix() throws {
        // none loads both explicitly and (see below) by default.
        let none = try MCPIntegrationStore.decode(
            try Self.documentData([Self.validRemote(extra: ["auth": ["kind": "none"]])])
        ).get()
        guard case .remote(let noneRemote) = none.integrations[0] else {
            Issue.record("expected remote")
            return
        }
        #expect(noneRemote.auth == .none)
        // header with string and object secrets.
        for secret: Any in [
            "secret-public-ref:file/api-key",
            ["provider": "vault-http", "item": "a/b", "field": "k"],
        ] {
            let header = try MCPIntegrationStore.decode(
                try Self.documentData([
                    Self.validRemote(extra: ["auth": ["kind": "header", "headerName": "X-Auth", "secret": secret]])
                ])
            ).get()
            guard case .remote(let headerRemote) = header.integrations[0] else {
                Issue.record("expected remote")
                return
            }
            guard case .header(let name, _, let prefix) = headerRemote.auth else {
                Issue.record("expected header auth")
                return
            }
            #expect(name == "X-Auth")
            #expect(prefix == nil)
        }
        // oauth2.
        let oauth = try MCPIntegrationStore.decode(
            try Self.documentData([
                Self.validRemote(extra: ["auth": ["kind": "oauth2", "connectionId": "github.user.main"]])
            ])
        ).get()
        guard case .remote(let oauthRemote) = oauth.integrations[0] else {
            Issue.record("expected remote")
            return
        }
        #expect(oauthRemote.auth == .oauth2(connectionId: "github.user.main"))
        // Unknown kinds and mistyped auth blocks.
        for auth: Any in [
            ["kind": "bearer"], ["kind": "apiKey"], ["kind": ""], ["kind": "NONE"], ["kind": 42],
            ["noKind": true], "none", 42, ["array"],
            ["kind": "header", "headerName": "X"], ["kind": "header", "secret": "secret-public-ref:file/x"],
            ["kind": "header", "headerName": "X", "secret": NSNull()],
            ["kind": "header", "headerName": "X", "secret": 42],
            ["kind": "oauth2"], ["kind": "oauth2", "connectionId": 42],
        ] {
            #expect(
                MCPIntegrationStore.decode(
                    try Self.documentData([Self.validRemote(extra: ["auth": auth])])
                ) == .failure(.invalidDocument)
            )
        }
    }

    @Test func authAbsentAndNullDefaultToNone() throws {
        let absent = try MCPIntegrationStore.decode(
            try Self.documentData([Self.validRemote()])
        ).get()
        guard case .remote(let absentRemote) = absent.integrations[0] else {
            Issue.record("expected remote")
            return
        }
        #expect(absentRemote.auth == .none)
        let nulled = try MCPIntegrationStore.decode(
            try Self.documentData([Self.validRemote(extra: ["auth": NSNull()])])
        ).get()
        guard case .remote(let nulledRemote) = nulled.integrations[0] else {
            Issue.record("expected remote")
            return
        }
        #expect(nulledRemote.auth == .none)
    }

    @Test func prefixRules() throws {
        for prefix in ["Bearer ", "Token", "tökén", String(repeating: "p", count: 128)] {
            for entry in [
                Self.validRemote(extra: [
                    "auth": ["kind": "header", "headerName": "X", "secret": ["provider": "file", "item": "x"], "prefix": prefix],
                    "headers": ["K": ["secret": ["provider": "file", "item": "x"], "prefix": prefix]],
                ]),
            ] {
                let loaded = try MCPIntegrationStore.decode(try Self.documentData([entry])).get()
                guard case .remote(let remote) = loaded.integrations[0] else {
                    Issue.record("expected remote")
                    return
                }
                guard case .header(_, _, let authPrefix) = remote.auth else {
                    Issue.record("expected header auth")
                    return
                }
                #expect(authPrefix == prefix)
                #expect(
                    remote.headers?["K"]
                        == .secret(MCPSecretSelector(provider: "file", item: "x"), prefix: prefix)
                )
            }
        }
        for prefix in ["", String(repeating: "p", count: 129), "has\0nul", "has\nnewline", "has\rcarriage"] {
            for extra in [
                ["auth": ["kind": "header", "headerName": "X", "secret": ["provider": "file", "item": "x"], "prefix": prefix]],
                ["headers": ["K": ["secret": ["provider": "file", "item": "x"], "prefix": prefix]]],
            ] as [[String: Any]] {
                var entry = Self.validRemote()
                for (key, value) in extra { entry[key] = value }
                #expect(
                    MCPIntegrationStore.decode(try Self.documentData([entry]))
                        == .failure(.invalidDocument)
                )
            }
        }
    }

    @Test func connectionIdRules() throws {
        // References must resolve: every accepted id parses as a dotted
        // connection handle, so the oauth2 arm names a real connection row.
        for id in ["github.user.main", "acme.org.widget1", "9aBc_-x.user._crm$1"] {
            let loaded = try MCPIntegrationStore.decode(
                try Self.documentData([
                    Self.validRemote(extra: ["auth": ["kind": "oauth2", "connectionId": id]])
                ])
            ).get()
            guard case .remote(let remote) = loaded.integrations[0] else {
                Issue.record("expected remote")
                return
            }
            #expect(remote.auth == .oauth2(connectionId: id))
        }
        for id in [
            "", "conn-1", "550e8400-e29b-41d4-a716-446655440000",
            String(repeating: "c", count: 64), "a.b", "a.b.c.d", "github.bogus.main",
            ".user.main", "github.user.", "github..main", "has space", "has/slash",
            "tökén", "has\0nul",
        ] {
            #expect(
                MCPIntegrationStore.decode(
                    try Self.documentData([
                        Self.validRemote(extra: ["auth": ["kind": "oauth2", "connectionId": id]])
                    ])
                ) == .failure(.invalidDocument)
            )
        }
    }

    @Test func connectionIdRoundTripsThroughParse() throws {
        // Every accepted connectionId parses and formats back to itself.
        for id in ["github.user.main", "acme.org.widget1", "9aBc_-x.user._crm$1"] {
            let loaded = try MCPIntegrationStore.decode(
                try Self.documentData([
                    Self.validRemote(extra: ["auth": ["kind": "oauth2", "connectionId": id]])
                ])
            ).get()
            guard case .remote(let remote) = loaded.integrations[0],
                case .oauth2(let accepted) = remote.auth
            else {
                Issue.record("expected oauth2 remote")
                return
            }
            #expect(try MCPConnectionID.parse(accepted).description == accepted)
        }
    }

    @Test func dottedNamespacesStayAllowed() throws {
        // Dotted EXPLICIT namespaces are file-identity keys, not references:
        // they stay allowed while connectionIds must parse.
        let loaded = try MCPIntegrationStore.decode(
            try Self.documentData([
                Self.validRemote(extra: ["namespace": "a.b.c"]),
                Self.validStdio(extra: ["namespace": "x.y"]),
            ])
        ).get()
        #expect(loaded.integrations.count == 2)
        #expect(loaded.integrations[0].resolvedNamespace == "a.b.c")
        #expect(loaded.integrations[1].resolvedNamespace == "x.y")
    }

    @Test func operatorTextRejectsInvisibleFormatAndSeparators() throws {
        // boundedText delegates to OperatorText: zero-width joiners and
        // line/paragraph separators fail closed everywhere bounded text
        // applies, while emoji (symbols, not format) still loads.
        for name in ["a\u{200D}b", "a\u{2028}b", "a\u{2029}b", "\u{FEFF}bom", "a\u{200E}b"] {
            #expect(
                MCPIntegrationStore.decode(
                    try Self.documentData([Self.validRemote(name: name)])
                ) == .failure(.invalidDocument)
            )
        }
        #expect(
            MCPIntegrationStore.decode(
                try Self.documentData([
                    Self.validRemote(extra: ["headers": ["X-Lit": "a\u{2028}b"]])
                ])
            ) == .failure(.invalidDocument)
        )
        #expect(
            MCPIntegrationStore.decode(
                try Self.documentData([
                    Self.validStdio(extra: ["args": ["a\u{200D}b"]])
                ])
            ) == .failure(.invalidDocument)
        )
        let loaded = try MCPIntegrationStore.decode(
            try Self.documentData([Self.validRemote(name: "🔥 Deploy")])
        ).get()
        #expect(loaded.integrations[0].name == "🔥 Deploy")
    }

    @Test func throwingInitsAcceptValidModels() throws {
        let remote = try MCPRemoteIntegration(
            name: "GitHub",
            endpoint: "https://api.example.com/mcp",
            remoteTransport: .sse,
            namespace: "github",
            queryParams: ["plain": .literal("value")],
            headers: ["X-Literal": .literal("yes")],
            auth: .oauth2(connectionId: "github.user.main")
        )
        #expect(remote.resolvedNamespace == "github")
        let stdio = try MCPStdioIntegration(
            name: "Helper",
            command: "/usr/local/bin/mcp-helper",
            args: ["serve"],
            env: ["LOG_LEVEL": "debug"],
            cwd: "/tmp/work",
            namespace: "helper"
        )
        #expect(stdio.resolvedNamespace == "helper")
    }

    @Test func throwingInitsRejectInvalidModels() {
        #expect(throws: MCPIntegrationStoreError.invalidDocument) {
            try MCPRemoteIntegration(name: "", endpoint: "https://h")
        }
        #expect(throws: MCPIntegrationStoreError.invalidDocument) {
            try MCPRemoteIntegration(name: "R", endpoint: "notaurl")
        }
        #expect(throws: MCPIntegrationStoreError.invalidDocument) {
            try MCPRemoteIntegration(name: "R", endpoint: "https://h/p?x=1")
        }
        #expect(throws: MCPIntegrationStoreError.invalidDocument) {
            try MCPRemoteIntegration(name: "R", endpoint: "https://h", namespace: "has space")
        }
        #expect(throws: MCPIntegrationStoreError.invalidDocument) {
            try MCPRemoteIntegration(
                name: "R", endpoint: "https://h", auth: .oauth2(connectionId: "conn-1")
            )
        }
        #expect(throws: MCPIntegrationStoreError.invalidDocument) {
            try MCPStdioIntegration(name: "", command: "/bin/s")
        }
        #expect(throws: MCPIntegrationStoreError.invalidDocument) {
            try MCPStdioIntegration(name: "S", command: "relative/path")
        }
        #expect(throws: MCPIntegrationStoreError.invalidDocument) {
            try MCPStdioIntegration(name: "S", command: "/bin/a;b")
        }
        #expect(throws: MCPIntegrationStoreError.invalidDocument) {
            try MCPStdioIntegration(
                name: "S", command: "/bin/s",
                env: ["TOKEN": "secret-public-ref:file/x"]
            )
        }
    }

    @Test func endpointQueryBelongsInQueryParams() throws {
        // The same query the endpoint rejects loads fine as queryParams.
        #expect(
            MCPIntegrationStore.decode(
                try Self.documentData([Self.validRemote(endpoint: "https://h/mcp?x=1")])
            ) == .failure(.invalidDocument)
        )
        let loaded = try MCPIntegrationStore.decode(
            try Self.documentData([
                Self.validRemote(
                    endpoint: "https://h/mcp", extra: ["queryParams": ["x": "1"]]
                )
            ])
        ).get()
        guard case .remote(let remote) = loaded.integrations[0] else {
            Issue.record("expected remote")
            return
        }
        #expect(remote.queryParams?["x"] == .literal("1"))
    }

    @Test func validateReportsPerFieldReasons() throws {
        #expect(
            MCPIntegrationStore.validate(
                try Self.documentData([Self.validRemote(), Self.validStdio()])
            ).isEmpty
        )
        let endpoint = MCPIntegrationStore.validate(
            try Self.documentData([Self.validRemote(endpoint: "notaurl")])
        )
        #expect(endpoint.count == 1)
        #expect(endpoint.first?.index == 0)
        #expect(endpoint.first?.reason == "endpoint")
        let connection = MCPIntegrationStore.validate(
            try Self.documentData([
                Self.validRemote(extra: ["auth": ["kind": "oauth2", "connectionId": "conn-1"]])
            ])
        )
        #expect(connection.map(\.reason) == ["auth.connectionId"])
        let both = MCPIntegrationStore.validate(
            try Self.documentData([
                Self.validRemote(name: ""),
                Self.validStdio(extra: ["command": "relative"]),
            ])
        )
        #expect(both.map(\.index) == [0, 1])
        #expect(both.map(\.reason) == ["name", "command"])
        let duplicate = MCPIntegrationStore.validate(
            try Self.documentData([
                Self.validRemote(extra: ["namespace": "same"]),
                Self.validRemote(extra: ["namespace": "same"]),
            ])
        )
        #expect(duplicate.map(\.index) == [1])
        #expect(duplicate.map(\.reason) == ["duplicateNamespace"])
        #expect(
            MCPIntegrationStore.validate(
                try Self.documentData([Self.validRemote()], version: 2)
            ).map(\.reason) == ["unsupportedVersion"]
        )
        #expect(
            MCPIntegrationStore.validate(Data("{\"version\":}".utf8)).map(\.reason)
                == ["invalidDocument"]
        )
        #expect(
            MCPIntegrationStore.validate(
                Data(repeating: 0x61, count: MCPIntegrationStore.maximumBytes + 1)
            ).map(\.reason) == ["oversized"]
        )
        let many = MCPIntegrationStore.validate(
            try Self.documentData(
                (0...MCPIntegrationStore.maximumIntegrations).map { _ in Self.validRemote() }
            )
        )
        #expect(many.map(\.reason) == ["tooManyIntegrations"])
    }

    @Test func validateAgreesWithDecode() throws {
        // validate is empty exactly when decode succeeds.
        let documents: [Data] = try [
            Self.documentData([Self.validRemote(), Self.validStdio()]),
            Self.documentData([]),
            Self.documentData([Self.validRemote(endpoint: "notaurl")]),
            Self.documentData([Self.validStdio(extra: ["command": "relative"])]),
            Self.documentData(
                [Self.validRemote(extra: ["namespace": "dup"]), Self.validRemote(extra: ["namespace": "dup"])]
            ),
            Data("not json".utf8),
        ]
        for document in documents {
            let valid: Bool
            switch MCPIntegrationStore.decode(document) {
            case .success: valid = true
            case .failure: valid = false
            }
            #expect(MCPIntegrationStore.validate(document).isEmpty == valid)
        }
    }

    @Test(
        "every allowed provider loads",
        arguments: ["file", "keychain", "vault-http", "env", "exec"]
    )
    func allowedProvider_loads(provider: String) throws {
        // Object position (auth secret) and string position (header value).
        let objected = try MCPIntegrationStore.decode(
            try Self.documentData([
                Self.validRemote(extra: [
                    "auth": ["kind": "header", "headerName": "X", "secret": ["provider": provider, "item": "x"]]
                ])
            ])
        ).get()
        guard case .remote(let objectRemote) = objected.integrations[0],
            case .header(_, let selector, _) = objectRemote.auth
        else {
            Issue.record("expected header auth")
            return
        }
        #expect(selector.provider == provider)
        let stringed = try MCPIntegrationStore.decode(
            try Self.documentData([
                Self.validRemote(extra: ["headers": ["K": "secret-public-ref:\(provider)/x"]])
            ])
        ).get()
        guard case .remote(let stringRemote) = stringed.integrations[0] else {
            Issue.record("expected remote")
            return
        }
        #expect(
            stringRemote.headers?["K"]
                == .secret(MCPSecretSelector(provider: provider, item: "x"), prefix: nil)
        )
    }

    @Test(
        "unknown provider rejected",
        arguments: [
            "vault", "s3", "1password", "FILE", "File", " file", "file ", "file\n",
            "", "vault-http-v2", "../file", "keychain;id", " ", "file\0", "a/b",
        ]
    )
    func unknownProvider_rejected(provider: String) throws {
        // Object position.
        #expect(
            MCPIntegrationStore.decode(
                try Self.documentData([
                    Self.validRemote(extra: [
                        "auth": ["kind": "header", "headerName": "X", "secret": ["provider": provider, "item": "x"]]
                    ])
                ])
            ) == .failure(.invalidDocument)
        )
        // Selector object inside a header value.
        #expect(
            MCPIntegrationStore.decode(
                try Self.documentData([
                    Self.validRemote(extra: ["headers": ["K": ["secret": ["provider": provider, "item": "x"]]]])
                ])
            ) == .failure(.invalidDocument)
        )
    }

    @Test func itemAndFieldRules() throws {
        for item in ["x", String(repeating: "i", count: 256), "tökén-🔑-名前", "github/token", "a b", "x#y"] {
            let loaded = try MCPIntegrationStore.decode(
                try Self.documentData([
                    Self.validRemote(extra: [
                        "auth": ["kind": "header", "headerName": "X", "secret": ["provider": "file", "item": item]]
                    ])
                ])
            ).get()
            guard case .remote(let remote) = loaded.integrations[0],
                case .header(_, let selector, _) = remote.auth
            else {
                Issue.record("expected header auth")
                return
            }
            #expect(selector.item == item)
        }
        for item in ["", String(repeating: "i", count: 257), "has\nnewline", "has\rreturn", "has\0nul"] {
            #expect(
                MCPIntegrationStore.decode(
                    try Self.documentData([
                        Self.validRemote(extra: [
                            "auth": ["kind": "header", "headerName": "X", "secret": ["provider": "file", "item": item]]
                        ])
                    ])
                ) == .failure(.invalidDocument)
            )
        }
        for field in ["f", String(repeating: "f", count: 128), "clé-🔑"] {
            let loaded = try MCPIntegrationStore.decode(
                try Self.documentData([
                    Self.validRemote(extra: [
                        "auth": ["kind": "header", "headerName": "X", "secret": ["provider": "file", "item": "x", "field": field]]
                    ])
                ])
            ).get()
            guard case .remote(let remote) = loaded.integrations[0],
                case .header(_, let selector, _) = remote.auth
            else {
                Issue.record("expected header auth")
                return
            }
            #expect(selector.field == field)
        }
        for field in ["", String(repeating: "f", count: 129), "has\nnewline", "has\0nul"] {
            #expect(
                MCPIntegrationStore.decode(
                    try Self.documentData([
                        Self.validRemote(extra: [
                            "auth": ["kind": "header", "headerName": "X", "secret": ["provider": "file", "item": "x", "field": field]]
                        ])
                    ])
                ) == .failure(.invalidDocument)
            )
        }
        // Explicit null reads as absent.
        let nulled = try MCPIntegrationStore.decode(
            try Self.documentData([
                Self.validRemote(extra: [
                    "auth": ["kind": "header", "headerName": "X", "secret": ["provider": "file", "item": "x", "field": NSNull()]]
                ])
            ])
        ).get()
        guard case .remote(let remote) = nulled.integrations[0],
            case .header(_, let selector, _) = remote.auth
        else {
            Issue.record("expected header auth")
            return
        }
        #expect(selector.field == nil)
        // Mistyped selector members.
        for secret: Any in [
            ["provider": 42, "item": "x"], ["item": "x"], ["provider": "file"],
            ["provider": "file", "item": "x", "field": 42], ["provider": "file", "item": NSNull()],
        ] {
            #expect(
                MCPIntegrationStore.decode(
                    try Self.documentData([
                        Self.validRemote(extra: [
                            "auth": ["kind": "header", "headerName": "X", "secret": secret]
                        ])
                    ])
                ) == .failure(.invalidDocument)
            )
        }
    }

    @Test func nullsReadAsAbsent() throws {
        let remote = try MCPIntegrationStore.decode(
            try Self.documentData([Self.validRemote(extra: [
                "remoteTransport": NSNull(), "namespace": NSNull(), "queryParams": NSNull(),
                "headers": NSNull(), "auth": NSNull(),
            ])])
        ).get()
        guard case .remote(let r) = remote.integrations[0] else {
            Issue.record("expected remote")
            return
        }
        #expect(r.remoteTransport == .auto)
        #expect(r.namespace == nil)
        #expect(r.queryParams == nil)
        #expect(r.headers == nil)
        #expect(r.auth == .none)
        let stdio = try MCPIntegrationStore.decode(
            try Self.documentData([Self.validStdio(extra: [
                "args": NSNull(), "env": NSNull(), "cwd": NSNull(), "namespace": NSNull(),
            ])])
        ).get()
        guard case .stdio(let s) = stdio.integrations[0] else {
            Issue.record("expected stdio")
            return
        }
        #expect(s.args == nil)
        #expect(s.env == nil)
        #expect(s.cwd == nil)
        #expect(s.namespace == nil)
    }

    @Test func namespaceLookup() throws {
        let loaded = try MCPIntegrationStore.decode(
            try Self.documentData([
                Self.validRemote(extra: ["namespace": "present"]),
                Self.validStdio(name: "Derived Only"),
            ])
        ).get()
        #expect(loaded.integration(namespace: "present")?.resolvedNamespace == "present")
        #expect(loaded.integration(namespace: "derived_only")?.name == "Derived Only")
        #expect(loaded.integration(namespace: "absent") == nil)
        #expect(loaded.integration(namespace: "") == nil)
        #expect(loaded.integration(namespace: "PRESENT") == nil)
    }

    @Test func deriveNamespaceExecutorParity() {
        // Oracle: Executor plugin.test.ts "deriveMcpNamespace" cases.
        #expect(MCPIntegrationStore.deriveNamespace(name: "GitHub MCP", endpoint: nil, command: nil) == "github_mcp")
        #expect(
            MCPIntegrationStore.deriveNamespace(name: "", endpoint: "https://api.example.com/mcp", command: nil)
                == "api_example_com"
        )
        #expect(
            MCPIntegrationStore.deriveNamespace(name: "", endpoint: nil, command: "/usr/local/bin/my-mcp-server")
                == "my_mcp_server"
        )
        #expect(MCPIntegrationStore.deriveNamespace(name: "", endpoint: nil, command: nil) == "mcp")
    }

    @Test func deriveNamespaceEdges() {
        // Precedence: name beats endpoint beats command beats fallback.
        #expect(
            MCPIntegrationStore.deriveNamespace(
                name: "Name", endpoint: "https://example.com", command: "/bin/other"
            ) == "name"
        )
        #expect(
            MCPIntegrationStore.deriveNamespace(name: "  ", endpoint: "https://example.com/x", command: "/bin/other")
                == "example_com"
        )
        #expect(
            MCPIntegrationStore.deriveNamespace(name: "", endpoint: "  ", command: "/bin/other") == "other"
        )
        // Blank everything (including whitespace-only) falls back.
        for name in ["", " ", "\t\n"] {
            #expect(MCPIntegrationStore.deriveNamespace(name: name, endpoint: nil, command: nil) == "mcp")
            #expect(MCPIntegrationStore.deriveNamespace(name: name, endpoint: "  ", command: "  ") == "mcp")
        }
        // Empty slugs fall back per candidate.
        #expect(MCPIntegrationStore.deriveNamespace(name: "---", endpoint: nil, command: nil) == "mcp")
        #expect(MCPIntegrationStore.deriveNamespace(name: " _-.", endpoint: nil, command: nil) == "mcp")
        #expect(MCPIntegrationStore.deriveNamespace(name: "", endpoint: "https://.../", command: nil) == "mcp")
        // Host-less endpoints fall through to the command, then fallback.
        #expect(
            MCPIntegrationStore.deriveNamespace(name: "", endpoint: "notaurl", command: "/bin/tool") == "tool"
        )
        #expect(MCPIntegrationStore.deriveNamespace(name: "", endpoint: "notaurl", command: nil) == "mcp")
        // Userinfo does not leak into the derived host slug.
        #expect(
            MCPIntegrationStore.deriveNamespace(name: "", endpoint: "https://user:pass@hosts.example/", command: nil)
                == "hosts_example"
        )
        // Basenames: trailing separators, repeats, trims, Windows drives.
        #expect(MCPIntegrationStore.deriveNamespace(name: "", endpoint: nil, command: "/a/") == "mcp")
        #expect(MCPIntegrationStore.deriveNamespace(name: "", endpoint: nil, command: "///") == "mcp")
        #expect(MCPIntegrationStore.deriveNamespace(name: "", endpoint: nil, command: "  /a/b  ") == "b")
        #expect(
            MCPIntegrationStore.deriveNamespace(name: "", endpoint: nil, command: "C:\\Tools\\my-server.exe")
                == "my_server_exe"
        )
        #expect(MCPIntegrationStore.deriveNamespace(name: "", endpoint: nil, command: "bare") == "bare")
        // Slugify: folding, collapsing, digits kept, unicode dropped.
        #expect(MCPIntegrationStore.deriveNamespace(name: "Café Été", endpoint: nil, command: nil) == "caf_t")
        #expect(MCPIntegrationStore.deriveNamespace(name: "a  b", endpoint: nil, command: nil) == "a_b")
        #expect(MCPIntegrationStore.deriveNamespace(name: "_a_", endpoint: nil, command: nil) == "a")
        #expect(MCPIntegrationStore.deriveNamespace(name: "A1-._B2", endpoint: nil, command: nil) == "a1_b2")
        #expect(MCPIntegrationStore.deriveNamespace(name: "UPPER lower 09", endpoint: nil, command: nil) == "upper_lower_09")
    }

    @Test func resolvedNamespacePrefersExplicit() throws {
        // Explicit wins even when a name would derive differently.
        let explicit = MCPIntegrationConfig.remote(
            try MCPRemoteIntegration(name: "GitHub MCP", endpoint: "https://api.example.com", namespace: "custom")
        )
        #expect(explicit.explicitNamespace == "custom")
        #expect(explicit.resolvedNamespace == "custom")
        // Derived paths through the models (hand-built blanks exercise the
        // endpoint/command legs that validated models never reach, since
        // validation requires a non-empty name; hence the unchecked init).
        let fromEndpoint = MCPIntegrationConfig.remote(
            MCPRemoteIntegration(unchecked: "", endpoint: "https://api.example.com/x")
        )
        #expect(fromEndpoint.explicitNamespace == nil)
        #expect(fromEndpoint.resolvedNamespace == "api_example_com")
        let fromCommand = MCPIntegrationConfig.stdio(
            MCPStdioIntegration(unchecked: "", command: "/opt/bin/my-server")
        )
        #expect(fromCommand.resolvedNamespace == "my_server")
        let fallback = MCPIntegrationConfig.stdio(MCPStdioIntegration(unchecked: "", command: "///"))
        #expect(fallback.resolvedNamespace == "mcp")
    }

    @Test func unionAccessors() throws {
        let remote = MCPIntegrationConfig.remote(try MCPRemoteIntegration(name: "R", endpoint: "https://h"))
        #expect(remote.name == "R")
        #expect(remote.explicitNamespace == nil)
        #expect(remote.resolvedNamespace == "r")
        let stdio = MCPIntegrationConfig.stdio(
            try MCPStdioIntegration(name: "S", command: "/bin/s", namespace: "ess")
        )
        #expect(stdio.name == "S")
        #expect(stdio.explicitNamespace == "ess")
        #expect(stdio.resolvedNamespace == "ess")
    }

    @Test func executorRefRoundtrips() throws {
        for selector in [
            MCPSecretSelector(provider: "file", item: "x"),
            MCPSecretSelector(provider: "file", item: "github/token"),
            MCPSecretSelector(provider: "vault-http", item: "a b"),
            MCPSecretSelector(provider: "keychain", item: "svc", field: nil),
        ] {
            let encoded = try #require(selector.executorRef)
            #expect(encoded.hasPrefix("secret-public-ref:"))
            #expect(MCPSecretSelector(executorRef: encoded) == selector)
        }
        #expect(
            MCPSecretSelector(provider: "file", item: "github/token").executorRef
                == "secret-public-ref:file/github/token"
        )
        // The marker constant matches Executor's SECRET_REF_PREFIX.
        #expect(MCPSecretSelector.executorRefPrefix == "secret-public-ref:")
    }

    @Test func executorRefNilCases() {
        // Fields have no string form.
        #expect(MCPSecretSelector(provider: "file", item: "x", field: "f").executorRef == nil)
        // Invalid selectors fail closed.
        #expect(MCPSecretSelector(provider: "nope", item: "x").executorRef == nil)
        #expect(MCPSecretSelector(provider: "", item: "x").executorRef == nil)
        #expect(MCPSecretSelector(provider: "file", item: "").executorRef == nil)
        #expect(MCPSecretSelector(provider: "file", item: "has\0nul").executorRef == nil)
    }

    @Test func executorRefParseRejects() {
        for value in [
            "plain-literal", "secret-public-ref", "secret-public-ref:", "secret-public-ref:noslash",
            "secret-public-ref:/x", "secret-public-ref:file/", "secret-public-ref:file",
            "secret-public-ref:nope/x", "secret-public-ref:FILE/x", "secret-public-ref:file/",
            "secret-public-ref:file/has\0nul", "SECRET-PUBLIC-REF:file/x",
        ] {
            #expect(MCPSecretSelector(executorRef: value) == nil)
        }
        // Shape-valid but unknown providers fail here (validation layer).
        #expect(MCPSecretSelector(executorRef: "secret-public-ref:vault/x") == nil)
        // Item slashes split at the first one only.
        #expect(
            MCPSecretSelector(executorRef: "secret-public-ref:file/a/b")
                == MCPSecretSelector(provider: "file", item: "a/b")
        )
    }

    @Test func parseExecutorRefIsShapeOnly() {
        // Unknown providers parse: validation is the caller's job.
        #expect(MCPSecretSelector.parseExecutorRef("secret-public-ref:nope/x")?.provider == "nope")
        #expect(MCPSecretSelector.parseExecutorRef("secret-public-ref:file/a/b")?.item == "a/b")
        for value in ["literal", "", "secret-public-ref:", "secret-public-ref:x", "secret-public-ref:/x", "secret-public-ref:p/"] {
            #expect(MCPSecretSelector.parseExecutorRef(value) == nil)
        }
    }

    @Test func selectorRefProperty() throws {
        let valid = MCPSecretSelector(provider: "keychain", item: "svc/acct", field: "f")
        let expected = try SecretRef(provider: "keychain", item: "svc/acct", field: "f")
        #expect(valid.ref == expected)
        #expect(MCPSecretSelector(provider: "vault", item: "x").ref == nil)
        #expect(MCPSecretSelector(provider: "", item: "x").ref == nil)
        #expect(MCPSecretSelector(provider: "file", item: "").ref == nil)
    }

    @Test func stringFormNormalizesToObjectOnEncode() throws {
        let loaded = try MCPIntegrationStore.decode(
            try Self.documentData([
                Self.validRemote(extra: ["headers": ["K": "secret-public-ref:file/ci-token"]])
            ])
        ).get()
        guard case .remote(let remote) = loaded.integrations[0] else {
            Issue.record("expected remote")
            return
        }
        #expect(
            remote.headers?["K"]
                == .secret(MCPSecretSelector(provider: "file", item: "ci-token"), prefix: nil)
        )
        // Canonical encoding writes the object form, and decoding it again
        // is stable.
        let bytes = try MCPIntegrationStore.encode(loaded).get()
        let parsed = try #require(
            JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        )
        let integrations = try #require(parsed["integrations"] as? [[String: Any]])
        let headers = try #require(integrations[0]["headers"] as? [String: Any])
        let secret = try #require(headers["K"] as? [String: Any])
        #expect(secret["secret"] as? [String: String] == ["provider": "file", "item": "ci-token"])
        let reloaded = try MCPIntegrationStore.decode(bytes).get()
        #expect(reloaded == loaded)
    }

    @Test func hashInStringFormIsLiteralItem() throws {
        // `#` carries no field meaning in the string form: it stays literal.
        let selector = try #require(MCPSecretSelector(executorRef: "secret-public-ref:file/x#y"))
        #expect(selector.item == "x#y")
        #expect(selector.field == nil)
        let loaded = try MCPIntegrationStore.decode(
            try Self.documentData([
                Self.validRemote(extra: ["headers": ["K": "secret-public-ref:file/x#y"]])
            ])
        ).get()
        guard case .remote(let remote) = loaded.integrations[0] else {
            Issue.record("expected remote")
            return
        }
        #expect(
            remote.headers?["K"]
                == .secret(MCPSecretSelector(provider: "file", item: "x#y"), prefix: nil)
        )
    }

    @Test func fullRoundtrip() throws {
        let set = MCPIntegrationSet(integrations: [Self.maximalRemote(), Self.maximalStdio()])
        let bytes = try MCPIntegrationStore.encode(set).get()
        let reloaded = try MCPIntegrationStore.decode(bytes).get()
        #expect(reloaded == set)
        // Canonical bytes carry no whitespace and sorted keys.
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(!text.contains("\n"))
        #expect(!text.contains(": "))
        #expect(text.hasPrefix("{\"integrations\":"))
    }

    @Test func minimalRemoteEncodesExactly() throws {
        let set = MCPIntegrationSet(integrations: [
            .remote(try MCPRemoteIntegration(name: "H", endpoint: "https://h/mcp"))
        ])
        let bytes = try MCPIntegrationStore.encode(set).get()
        #expect(
            String(data: bytes, encoding: .utf8)
                == "{\"integrations\":[{\"endpoint\":\"https://h/mcp\",\"kind\":\"mcp-remote\",\"name\":\"H\"}],\"version\":1}"
        )
        // And the minimal bytes decode back to the same model.
        #expect(try MCPIntegrationStore.decode(bytes).get() == set)
    }

    @Test func explicitDefaultsNormalizeOnEncode() throws {
        let loaded = try MCPIntegrationStore.decode(
            try Self.documentData([
                Self.validRemote(extra: ["remoteTransport": "auto", "auth": ["kind": "none"]])
            ])
        ).get()
        guard case .remote(let remote) = loaded.integrations[0] else {
            Issue.record("expected remote")
            return
        }
        #expect(remote.remoteTransport == .auto)
        #expect(remote.auth == .none)
        let bytes = try MCPIntegrationStore.encode(loaded).get()
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(!text.contains("remoteTransport"))
        #expect(!text.contains("\"auth\""))
        #expect(try MCPIntegrationStore.decode(bytes).get() == loaded)
    }

    @Test func encodeEmptySetExactBytes() throws {
        let bytes = try MCPIntegrationStore.encode(.empty).get()
        #expect(String(data: bytes, encoding: .utf8) == "{\"integrations\":[],\"version\":1}")
        #expect(try MCPIntegrationStore.decode(bytes).get() == .empty)
    }

    @Test func encodeOversizedFails() throws {
        // Per-field caps bound each member, not the total: one maxed-out
        // integration overflows the document cap on its own.
        #expect(MCPIntegrationStore.encode(MCPIntegrationSet(integrations: [Self.maxedRemote()])) == .failure(.oversized))
        let sane = try MCPIntegrationStore.encode(
            MCPIntegrationSet(integrations: [Self.maximalRemote(), Self.maximalStdio()])
        ).get()
        #expect(sane.count <= MCPIntegrationStore.maximumBytes)
    }

    @Test func presentEmptyMapsSurviveRoundtrip() throws {
        let loaded = try MCPIntegrationStore.decode(
            try Self.documentData([
                Self.validRemote(extra: ["headers": [:], "queryParams": [:]]),
                Self.validStdio(extra: ["args": [], "env": [:]]),
            ])
        ).get()
        let reloaded = try MCPIntegrationStore.decode(try MCPIntegrationStore.encode(loaded).get()).get()
        #expect(reloaded == loaded)
        guard case .remote(let remote) = reloaded.integrations[0],
            case .stdio(let stdio) = reloaded.integrations[1]
        else {
            Issue.record("expected remote then stdio")
            return
        }
        #expect(remote.headers == [:])
        #expect(remote.queryParams == [:])
        #expect(stdio.args == [])
        #expect(stdio.env == [:])
    }

    @Test func transformUpsertAppendsReplacesAndCaps() throws {
        let first = Self.remoteModel(namespace: "a")
        let second = Self.stdioModel(namespace: "b")
        // Append into empty.
        let appended = try MCPIntegrationFileSinkTransform.upsert(first, into: .empty).get()
        #expect(appended.integrations == [first])
        // Append a second namespace.
        let grown = try MCPIntegrationFileSinkTransform.upsert(
            second, into: appended
        ).get()
        #expect(grown.integrations == [first, second])
        // Replace moves the entry to the end (remove-then-append, mirroring
        // Executor's addIntegrationToConfig dedup-by-namespace).
        let replacement = Self.remoteModel(namespace: "a", name: "A2")
        let replaced = try MCPIntegrationFileSinkTransform.upsert(replacement, into: grown).get()
        #expect(replaced.integrations == [second, replacement])
        // At cap: a new namespace fails, a same-namespace replace succeeds.
        let full = MCPIntegrationSet(integrations: (0..<32).map { Self.remoteModel(namespace: "i\($0)") })
        #expect(
            MCPIntegrationFileSinkTransform.upsert(Self.remoteModel(namespace: "new"), into: full)
                == .failure(.invalidDocument)
        )
        let replacedAtCap = try MCPIntegrationFileSinkTransform.upsert(
            Self.remoteModel(namespace: "i0", name: "Zero2"), into: full
        ).get()
        #expect(replacedAtCap.integrations.count == 32)
        #expect(replacedAtCap.integration(namespace: "i0")?.name == "Zero2")
    }

    @Test func transformRemove() {
        let first = Self.remoteModel(namespace: "a")
        let second = Self.stdioModel(namespace: "b")
        let set = MCPIntegrationSet(integrations: [first, second])
        #expect(MCPIntegrationFileSinkTransform.remove(namespace: "a", from: set)?.integrations == [second])
        #expect(MCPIntegrationFileSinkTransform.remove(namespace: "zzz", from: set) == nil)
        #expect(MCPIntegrationFileSinkTransform.remove(namespace: "a", from: .empty) == nil)
        // A hand-built set can hold duplicates the decoder forbids; remove
        // drops every match, mirroring Executor's backwards-walk removal.
        let duped = MCPIntegrationSet(integrations: [first, second, first])
        #expect(MCPIntegrationFileSinkTransform.remove(namespace: "a", from: duped)?.integrations == [second])
    }

    @Test func authNoneEncodesDirectly() throws {
        // The store encoder omits defaulted auth, so the none wire form is
        // pinned by direct encoding instead.
        let bytes = try JSONEncoder().encode(MCPAuthConfig.none)
        #expect(String(data: bytes, encoding: .utf8) == "{\"kind\":\"none\"}")
        let header = try JSONEncoder().encode(
            MCPAuthConfig.header(
                headerName: "X", secret: MCPSecretSelector(provider: "file", item: "x"), prefix: nil
            )
        )
        #expect(String(data: header, encoding: .utf8)?.contains("\"kind\":\"header\"") == true)
    }

    @Test func sinkNeverFailsProperty() throws {
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sample = Self.remoteModel(namespace: "sample")
        let matched = MCPIntegrationSet(integrations: [sample, Self.stdioModel(namespace: "other")])
        let unmatched = MCPIntegrationSet(integrations: [Self.stdioModel(namespace: "other")])
        let readOutcomes: [Result<MCPIntegrationSet, MCPIntegrationStoreError>] = [
            .success(.empty), .success(matched), .success(unmatched),
            .failure(.unsafeLocation), .failure(.unreadable), .failure(.oversized),
            .failure(.invalidDocument), .failure(.unsupportedVersion),
        ]
        let writeOutcomes: [Result<Void, MCPIntegrationStoreError>] = [
            .success(()),
            .failure(.unsafeLocation), .failure(.unreadable), .failure(.oversized),
            .failure(.invalidDocument), .failure(.unsupportedVersion),
        ]
        for read in readOutcomes {
            for write in writeOutcomes {
                // Upsert: every IO failure surfaces exactly once via onError;
                // nothing throws, nothing traps.
                do {
                    let fake = FakeSinkIO(readResult: read, writeResult: write)
                    let errors = ErrorSink()
                    let sink = MCPIntegrationFileSink(directory: directory, io: fake) { op, error in
                        errors.calls.append(SinkError(operation: op, error: error))
                    }
                    sink.upsert(sample)
                    switch read {
                    case .success:
                        #expect(fake.writeCalls.count == 1)
                        switch write {
                        case .success:
                            #expect(errors.calls.isEmpty)
                        case .failure(let error):
                            #expect(errors.calls == [SinkError(operation: .upsert, error: error)])
                        }
                    case .failure(let error):
                        #expect(fake.writeCalls.isEmpty)
                        #expect(errors.calls == [SinkError(operation: .upsert, error: error)])
                    }
                }
                // Remove: same, plus the silent no-op when nothing matches.
                do {
                    let fake = FakeSinkIO(readResult: read, writeResult: write)
                    let errors = ErrorSink()
                    let sink = MCPIntegrationFileSink(directory: directory, io: fake) { op, error in
                        errors.calls.append(SinkError(operation: op, error: error))
                    }
                    sink.removeIntegration(namespace: "sample")
                    switch read {
                    case .success(let set):
                        if set.integration(namespace: "sample") == nil {
                            #expect(fake.writeCalls.isEmpty)
                            #expect(errors.calls.isEmpty)
                        } else {
                            #expect(fake.writeCalls.count == 1)
                            switch write {
                            case .success:
                                #expect(errors.calls.isEmpty)
                            case .failure(let error):
                                #expect(errors.calls == [SinkError(operation: .remove, error: error)])
                            }
                        }
                    case .failure(let error):
                        #expect(fake.writeCalls.isEmpty)
                        #expect(errors.calls == [SinkError(operation: .remove, error: error)])
                    }
                }
            }
        }
    }

    @Test func sinkSkipsWriteWhenTransformFails() throws {
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let full = MCPIntegrationSet(integrations: (0..<32).map { Self.remoteModel(namespace: "i\($0)") })
        let fake = FakeSinkIO(readResult: .success(full), writeResult: .success(()))
        let errors = ErrorSink()
        let sink = MCPIntegrationFileSink(directory: directory, io: fake) { op, error in
            errors.calls.append(SinkError(operation: op, error: error))
        }
        // A 33rd namespace reports and never reaches the write path.
        sink.upsert(Self.remoteModel(namespace: "new"))
        #expect(fake.writeCalls.isEmpty)
        #expect(errors.calls == [SinkError(operation: .upsert, error: .invalidDocument)])
    }

    @Test func sinkUpsertWritesReplacedSet() throws {
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = MCPIntegrationSet(integrations: [
            Self.remoteModel(namespace: "a"), Self.stdioModel(namespace: "b"),
        ])
        let fake = FakeSinkIO(readResult: .success(existing), writeResult: .success(()))
        let errors = ErrorSink()
        let sink = MCPIntegrationFileSink(directory: directory, io: fake) { op, error in
            errors.calls.append(SinkError(operation: op, error: error))
        }
        let replacement = Self.remoteModel(namespace: "a", name: "A2")
        sink.upsert(replacement)
        #expect(errors.calls.isEmpty)
        #expect(fake.writeCalls.count == 1)
        #expect(fake.writeCalls.first?.integrations == [Self.stdioModel(namespace: "b"), replacement])
    }

    @Test func defaultOnErrorIsCallable() {
        // Covers the default reporter (one stderr line, like the Executor
        // console.warn default and the sibling migration logs).
        MCPIntegrationFileSink<FakeSinkIO>.defaultOnError(.upsert, .oversized)
        MCPIntegrationFileSink<FakeSinkIO>.defaultOnError(.remove, .unsafeLocation)
    }

    @Test func mapLoadFailureCoversEveryArm() {
        #expect(MCPIntegrationStore.mapLoadFailure(.missing) == .success(.empty))
        #expect(MCPIntegrationStore.mapLoadFailure(.inaccessible) == .failure(.unsafeLocation))
        #expect(MCPIntegrationStore.mapLoadFailure(.unsafeLocation) == .failure(.unsafeLocation))
        #expect(MCPIntegrationStore.mapLoadFailure(.unreadable) == .failure(.unreadable))
        #expect(MCPIntegrationStore.mapLoadFailure(.oversized) == .failure(.oversized))
    }

    @Test func liveReadSet() throws {
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let io = MCPIntegrationLiveIO()
        #expect(io.readSet(directory: directory) == .success(.empty))
        _ = try Self.writeConfigFile(
            try Self.documentData([Self.validRemote()]),
            named: MCPIntegrationStore.fileName,
            in: directory
        )
        #expect(try io.readSet(directory: directory).get().integrations.count == 1)
    }

    @Test func liveUpsertCreatesAndLoads() throws {
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let errors = ErrorSink()
        let sink = MCPIntegrationFileSink.live(directory: directory) { op, error in
            errors.calls.append(SinkError(operation: op, error: error))
        }
        sink.upsert(Self.maximalRemote())
        sink.upsert(Self.maximalStdio())
        #expect(errors.calls.isEmpty)
        let file = directory.appendingPathComponent(MCPIntegrationStore.fileName)
        #expect(try Self.posixPermissions(of: file) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [MCPIntegrationStore.fileName])
        let loaded = try MCPIntegrationStore.load(from: directory).get()
        #expect(loaded.integrations == [Self.maximalRemote(), Self.maximalStdio()])
    }

    @Test func liveUpsertWithDefaultReporter() throws {
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        MCPIntegrationFileSink.live(directory: directory).upsert(Self.remoteModel())
        #expect(try MCPIntegrationStore.load(from: directory).get().integrations.count == 1)
    }

    @Test func liveDefaultReporterFiresOnFailure() throws {
        // The default reporter must fire through the live convenience sink:
        // one stderr line, normal return, nothing written.
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        MCPIntegrationFileSink.live(directory: directory).upsert(Self.maxedRemote())
        #expect(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(MCPIntegrationStore.fileName).path)
                == false
        )
    }

    @Test func liveUpsertReplaces() throws {
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let errors = ErrorSink()
        let sink = MCPIntegrationFileSink.live(directory: directory) { op, error in
            errors.calls.append(SinkError(operation: op, error: error))
        }
        sink.upsert(Self.remoteModel(namespace: "a", name: "A1"))
        sink.upsert(Self.stdioModel(namespace: "b"))
        sink.upsert(Self.remoteModel(namespace: "a", name: "A2"))
        #expect(errors.calls.isEmpty)
        let loaded = try MCPIntegrationStore.load(from: directory).get()
        #expect(loaded.integrations.map(\.resolvedNamespace) == ["b", "a"])
        #expect(loaded.integration(namespace: "a")?.name == "A2")
        let file = directory.appendingPathComponent(MCPIntegrationStore.fileName)
        #expect(try Self.posixPermissions(of: file) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [MCPIntegrationStore.fileName])
    }

    @Test func liveRemove() throws {
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let errors = ErrorSink()
        let sink = MCPIntegrationFileSink.live(directory: directory) { op, error in
            errors.calls.append(SinkError(operation: op, error: error))
        }
        sink.upsert(Self.remoteModel(namespace: "a"))
        sink.upsert(Self.stdioModel(namespace: "b"))
        sink.removeIntegration(namespace: "a")
        #expect(errors.calls.isEmpty)
        let loaded = try MCPIntegrationStore.load(from: directory).get()
        #expect(loaded.integrations.map(\.resolvedNamespace) == ["b"])
        // A missed namespace writes nothing: bytes stay identical.
        let file = directory.appendingPathComponent(MCPIntegrationStore.fileName)
        let before = try Data(contentsOf: file)
        sink.removeIntegration(namespace: "zzz")
        #expect(errors.calls.isEmpty)
        #expect(try Data(contentsOf: file) == before)
        // Removing the last entry leaves a valid empty document.
        sink.removeIntegration(namespace: "b")
        #expect(errors.calls.isEmpty)
        #expect(try MCPIntegrationStore.load(from: directory).get() == .empty)
    }

    @Test func liveRemoveOnMissingFileIsSilent() throws {
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let errors = ErrorSink()
        MCPIntegrationFileSink.live(directory: directory) { op, error in
            errors.calls.append(SinkError(operation: op, error: error))
        }.removeIntegration(namespace: "anything")
        #expect(errors.calls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(MCPIntegrationStore.fileName).path) == false)
    }

    @Test func liveNeverClobbersInvalid() throws {
        for existing in [
            Data("not json".utf8),
            try Self.documentData([Self.validRemote(name: "")]),
            try Self.documentData([
                Self.validRemote(extra: ["namespace": "dup"]),
                Self.validStdio(extra: ["namespace": "dup"]),
            ]),
        ] {
            let directory = try Self.configDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = try Self.writeConfigFile(existing, named: MCPIntegrationStore.fileName, in: directory)
            let errors = ErrorSink()
            let sink = MCPIntegrationFileSink.live(directory: directory) { op, error in
                errors.calls.append(SinkError(operation: op, error: error))
            }
            sink.upsert(Self.remoteModel(namespace: "new"))
            #expect(errors.calls == [SinkError(operation: .upsert, error: .invalidDocument)])
            #expect(try Data(contentsOf: file) == existing)
            sink.removeIntegration(namespace: "dup")
            #expect(errors.calls.count == 2)
            #expect(errors.calls[1] == SinkError(operation: .remove, error: .invalidDocument))
            #expect(try Data(contentsOf: file) == existing)
        }
    }

    @Test func liveBadLocationsReportWithoutFailing() throws {
        // Missing directory: the read sees empty, the write reports.
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("rv-mcp-integrations-nodir-\(UUID().uuidString)")
            let errors = ErrorSink()
            let sink = MCPIntegrationFileSink.live(directory: directory) { op, error in
                errors.calls.append(SinkError(operation: op, error: error))
            }
            sink.upsert(Self.remoteModel())
            #expect(errors.calls == [SinkError(operation: .upsert, error: .unsafeLocation)])
        }
        // A file where the directory belongs.
        do {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("rv-mcp-integrations-fileisdir-\(UUID().uuidString)")
            try Data("x".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let errors = ErrorSink()
            let sink = MCPIntegrationFileSink.live(directory: file) { op, error in
                errors.calls.append(SinkError(operation: op, error: error))
            }
            sink.upsert(Self.remoteModel())
            #expect(errors.calls == [SinkError(operation: .upsert, error: .unsafeLocation)])
        }
        // Symlinked directory.
        do {
            let base = try Self.configDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let real = base.appendingPathComponent("real", isDirectory: true)
            try FileManager.default.createDirectory(
                at: real, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let link = base.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            let errors = ErrorSink()
            MCPIntegrationFileSink.live(directory: link) { op, error in
                errors.calls.append(SinkError(operation: op, error: error))
            }.upsert(Self.remoteModel())
            #expect(errors.calls == [SinkError(operation: .upsert, error: .unsafeLocation)])
        }
        // Group-readable existing file: the read reports, nothing is written.
        do {
            let directory = try Self.configDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = try Self.writeConfigFile(
                try Self.documentData([Self.validRemote()]),
                named: MCPIntegrationStore.fileName,
                in: directory
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            let errors = ErrorSink()
            let sink = MCPIntegrationFileSink.live(directory: directory) { op, error in
                errors.calls.append(SinkError(operation: op, error: error))
            }
            sink.upsert(Self.remoteModel(namespace: "new"))
            #expect(errors.calls == [SinkError(operation: .upsert, error: .unsafeLocation)])
            sink.removeIntegration(namespace: "github")
            #expect(errors.calls.count == 2)
        }
        // Oversized existing file: the read reports oversized, untouched.
        do {
            let directory = try Self.configDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let original = Data(repeating: 0x20, count: 65_537)
            let file = try Self.writeConfigFile(original, named: MCPIntegrationStore.fileName, in: directory)
            let errors = ErrorSink()
            MCPIntegrationFileSink.live(directory: directory) { op, error in
                errors.calls.append(SinkError(operation: op, error: error))
            }.upsert(Self.remoteModel())
            #expect(errors.calls == [SinkError(operation: .upsert, error: .oversized)])
            #expect(try Data(contentsOf: file) == original)
        }
        // Owner-narrowed directory (0500): trusted but staging fails.
        do {
            let directory = try Self.configDirectory()
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                try? FileManager.default.removeItem(at: directory)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            let errors = ErrorSink()
            MCPIntegrationFileSink.live(directory: directory) { op, error in
                errors.calls.append(SinkError(operation: op, error: error))
            }.upsert(Self.remoteModel())
            #expect(errors.calls == [SinkError(operation: .upsert, error: .unsafeLocation)])
        }
        // A directory where the file belongs: staging succeeds, the rename
        // fails, the temp is cleaned, nothing litters.
        do {
            let directory = try Self.configDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(MCPIntegrationStore.fileName, isDirectory: true),
                withIntermediateDirectories: true
            )
            let errors = ErrorSink()
            MCPIntegrationFileSink.live(directory: directory) { op, error in
                errors.calls.append(SinkError(operation: op, error: error))
            }.removeIntegration(namespace: "github")
            // The read rejects the non-regular file first.
            #expect(errors.calls == [SinkError(operation: .remove, error: .unsafeLocation)])
        }
    }

    @Test func liveOversizedModelReportsWithoutWriting() throws {
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let errors = ErrorSink()
        MCPIntegrationFileSink.live(directory: directory) { op, error in
            errors.calls.append(SinkError(operation: op, error: error))
        }.upsert(Self.maxedRemote())
        #expect(errors.calls == [SinkError(operation: .upsert, error: .oversized)])
        #expect(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(MCPIntegrationStore.fileName).path)
                == false
        )
    }

    @Test func writeAtomicallyDirectErrors() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-mcp-integrations-nodir-\(UUID().uuidString)")
        Self.expectWriteFailure(
            MCPIntegrationLiveIO.writeAtomically(Data("x".utf8), directory: missing), .unsafeLocation
        )
        // Foreign-owned directory: the uid check fails. /etc itself is a
        // symlink on macOS, which O_NOFOLLOW would reject before the uid
        // check runs, so the target resolves first via realpath
        // (/private/etc there, /etc on Linux). Skipped for root, for whom
        // the fixture is self-owned (and writable: the guard also keeps
        // the test from ever writing outside tmp as root), or when the
        // fixture does not have the expected shape.
        guard getuid() != 0, let foreign = Self.foreignSystemDirectory() else { return }
        Self.expectWriteFailure(
            MCPIntegrationLiveIO.writeAtomically(Data("x".utf8), directory: foreign),
            .unsafeLocation
        )
        let foreignFd = foreign.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard foreignFd >= 0 else { return }
        defer { close(foreignFd) }
        #expect(MCPIntegrationLiveIO.directoryIsTrusted(foreignFd) == false)
    }

    @Test func directoryIsTrustedDirect() throws {
        #expect(MCPIntegrationLiveIO.directoryIsTrusted(-1) == false)
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let trusted = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        #expect(trusted >= 0)
        defer { close(trusted) }
        #expect(MCPIntegrationLiveIO.directoryIsTrusted(trusted) == true)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
        #expect(MCPIntegrationLiveIO.directoryIsTrusted(trusted) == false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    @Test func stageAndWriteOnceDirect() throws {
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dirFd = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        #expect(dirFd >= 0)
        defer { close(dirFd) }
        // Successful staging leaves a 0600 temp the caller owns; clean it.
        let staged = try #require(MCPIntegrationLiveIO.stage(bytes: Data("abc".utf8), dirFd: dirFd))
        close(staged.fd)
        let tempURL = directory.appendingPathComponent(staged.name)
        #expect(try Self.posixPermissions(of: tempURL) == 0o600)
        #expect(try Data(contentsOf: tempURL) == Data("abc".utf8))
        try FileManager.default.removeItem(at: tempURL)
        #expect(MCPIntegrationLiveIO.stage(bytes: Data("x".utf8), dirFd: -1) == nil)
        // writeOnce: landed bytes, bad fd, and empty input.
        let file = directory.appendingPathComponent("w")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let fd = file.path.withCString { open($0, O_WRONLY | O_CLOEXEC) }
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(MCPIntegrationLiveIO.writeOnce(Data("abc".utf8), to: fd) == true)
        #expect(MCPIntegrationLiveIO.writeOnce(Data("abc".utf8), to: -1) == false)
        #expect(MCPIntegrationLiveIO.writeOnce(Data(), to: fd) == true)
        #expect(try Data(contentsOf: file) == Data("abc".utf8))
    }

    @Test func replaceFileRenameFailureCleansUp() throws {
        // A directory wearing the live name makes renameat fail after a
        // successful stage; the temp must be unlinked, not littered.
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(MCPIntegrationStore.fileName, isDirectory: true),
            withIntermediateDirectories: true
        )
        let dirFd = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        #expect(dirFd >= 0)
        defer { close(dirFd) }
        #expect(MCPIntegrationLiveIO.replaceFile(bytes: Data("x".utf8), dirFd: dirFd) == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [MCPIntegrationStore.fileName])
        let missing: Int32 = -1
        #expect(MCPIntegrationLiveIO.replaceFile(bytes: Data("x".utf8), dirFd: missing) == false)
    }

    @Test func commandShellMetacharactersRejected() throws {
        // Every byte a shell would interpret fails closed in the executed
        // path. Each metacharacter appears once, so the classifier's every
        // true-arm is load-bearing.
        for ch in ";|&$`\"'\\<>()*?~#!{}[]^" {
            let command = "/bin/a\(ch)b"
            #expect(
                MCPIntegrationStore.decode(
                    try Self.documentData([Self.validStdio(command: command)])
                ) == .failure(.invalidDocument)
            )
        }
        // Spaces and unicode stay legal: commands are paths, not words.
        for command in ["/Applications/My Tool/x", "/tökén/bin/a b"] {
            let loaded = try MCPIntegrationStore.decode(
                try Self.documentData([Self.validStdio(command: command)])
            ).get()
            guard case .stdio(let stdio) = loaded.integrations[0] else {
                Issue.record("expected stdio")
                return
            }
            #expect(stdio.command == command)
        }
    }

    @Test func commandAndCwdControlRules() throws {
        // Control bytes fail closed in both paths; DEL and C1 included.
        for control in ["a\u{7}b", "a\u{7F}b", "a\u{80}b", "a\u{9F}b"] {
            #expect(
                MCPIntegrationStore.decode(
                    try Self.documentData([Self.validStdio(command: "/bin/\(control)")])
                ) == .failure(.invalidDocument)
            )
            #expect(
                MCPIntegrationStore.decode(
                    try Self.documentData([Self.validStdio(extra: ["cwd": "/tmp/\(control)"])])
                ) == .failure(.invalidDocument)
            )
        }
        // Deliberate asymmetry: cwd is a chdir target, not an executed
        // value, so shell metacharacters stay legal there (user paths hold
        // parens); only the command is metachar-free by construction.
        let loaded = try MCPIntegrationStore.decode(
            try Self.documentData([Self.validStdio(extra: ["cwd": "/tmp/work (1)"])])
        ).get()
        guard case .stdio(let stdio) = loaded.integrations[0] else {
            Issue.record("expected stdio")
            return
        }
        #expect(stdio.cwd == "/tmp/work (1)")
    }

    @Test func controlBytesRejectedInText() throws {
        // Beyond NUL/CR/LF (pinned elsewhere): a bare vertical tab or form
        // feed would split an HTTP field value at some servers, and C1/DEL
        // have no business in operator text anywhere.
        for control in ["\u{7}", "\u{B}", "\u{C}", "\u{1B}", "\u{7F}", "\u{80}", "\u{9F}"] {
            let evil = "a\(control)b"
            for entry in [
                Self.validRemote(name: evil),
                Self.validStdio(name: evil),
                Self.validStdio(extra: ["args": [evil]]),
                Self.validStdio(extra: ["env": ["OK": evil]]),
                Self.validRemote(extra: ["headers": ["K": evil]]),
                Self.validRemote(extra: ["queryParams": ["K": evil]]),
                Self.validRemote(extra: [
                    "headers": ["K": ["secret": ["provider": "file", "item": "x"], "prefix": evil]]
                ]),
            ] {
                #expect(
                    MCPIntegrationStore.decode(try Self.documentData([entry]))
                        == .failure(.invalidDocument)
                )
            }
        }
        // Printable text at U+0020 and U+00A0-up still passes everywhere.
        let ok = "caf\u{E9} \u{1F511} ~ + % = :"
        let loaded = try MCPIntegrationStore.decode(
            try Self.documentData([
                Self.validRemote(
                    name: ok, extra: ["headers": ["K": ok], "queryParams": ["Q": ok]]
                )
            ])
        ).get()
        guard case .remote(let remote) = loaded.integrations[0] else {
            Issue.record("expected remote")
            return
        }
        #expect(remote.name == ok)
        #expect(remote.headers?["K"] == .literal(ok))
        #expect(remote.queryParams?["Q"] == .literal(ok))
    }

    @Test func hostnameTrimmedParity() {
        // WHATWG URL (which Executor's hostnameOf uses) strips surrounding
        // whitespace; URLComponents does not, so the store trims first.
        #expect(
            MCPIntegrationStore.deriveNamespace(
                name: "", endpoint: "  https://example.com/x  ", command: nil
            ) == "example_com"
        )
        #expect(
            MCPIntegrationStore.deriveNamespace(name: "", endpoint: "\tnotaurl\n", command: nil) == "mcp"
        )
    }

    @Test func refValidatesItemAndField() {
        // SecretRef only checks the allowlist and item non-emptiness, so the
        // label rules apply in `ref`: hand-built selectors fail closed.
        #expect(MCPSecretSelector(provider: "file", item: "has\nnewline").ref == nil)
        #expect(MCPSecretSelector(provider: "file", item: String(repeating: "i", count: 257)).ref == nil)
        #expect(MCPSecretSelector(provider: "file", item: "x", field: "").ref == nil)
        #expect(MCPSecretSelector(provider: "file", item: "x", field: "has\nnewline").ref == nil)
        #expect(
            MCPSecretSelector(provider: "file", item: "x", field: String(repeating: "f", count: 129)).ref
                == nil
        )
        #expect(MCPSecretSelector(provider: "file", item: "x", field: "f").ref != nil)
    }

    @Test func stringFormUnknownProviderRejected() throws {
        // The string form parses shape-only; resolution still allowlists the
        // provider and validates the item — in header values and auth alike.
        for entry in [
            Self.validRemote(extra: ["headers": ["K": "secret-public-ref:vault/x"]]),
            Self.validRemote(extra: ["queryParams": ["K": "secret-public-ref:vault/x"]]),
            Self.validRemote(extra: [
                "auth": [
                    "kind": "header", "headerName": "X",
                    "secret": "secret-public-ref:vault/x",
                ]
            ]),
            Self.validRemote(extra: ["headers": ["K": "secret-public-ref:file/has\nnewline"]]),
        ] {
            #expect(
                MCPIntegrationStore.decode(try Self.documentData([entry]))
                    == .failure(.invalidDocument)
            )
        }
    }

    @Test func transformUpsertNeverWritesUnloadableBytes() throws {
        // A hand-built model with values decode rejects reports instead of
        // producing bytes the next load would choke on (which would stick,
        // since invalid files are never clobbered).
        let invalid = MCPIntegrationConfig.remote(
            MCPRemoteIntegration(unchecked: "", endpoint: "notaurl")
        )
        #expect(
            MCPIntegrationFileSinkTransform.upsert(invalid, into: .empty)
                == .failure(.invalidDocument)
        )
        // An oversized-but-counted set reports oversized, not invalid.
        #expect(
            MCPIntegrationFileSinkTransform.upsert(Self.maxedRemote(), into: .empty)
                == .failure(.oversized)
        )
    }

    @Test func liveSinkNeverWritesUnloadableBytes() throws {
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let errors = ErrorSink()
        let sink = MCPIntegrationFileSink.live(directory: directory) { op, error in
            errors.calls.append(SinkError(operation: op, error: error))
        }
        sink.upsert(.remote(MCPRemoteIntegration(unchecked: "", endpoint: "https://h")))
        #expect(errors.calls == [SinkError(operation: .upsert, error: .invalidDocument)])
        #expect(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(MCPIntegrationStore.fileName).path
            ) == false
        )
        // A valid upsert still lands afterwards: the failure left no trace.
        sink.upsert(Self.remoteModel())
        #expect(errors.calls.count == 1)
        #expect(try MCPIntegrationStore.load(from: directory).get().integrations.count == 1)
    }

    @Test func liveWriteSetOversizedDirect() throws {
        // writeSet validates the encoding itself; the transform's
        // round-trip guard normally intercepts first, so this arm pins the
        // direct call.
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        Self.expectWriteFailure(
            MCPIntegrationLiveIO().writeSet(
                MCPIntegrationSet(integrations: [Self.maxedRemote()]), directory: directory
            ),
            .oversized
        )
        #expect(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(MCPIntegrationStore.fileName).path
            ) == false
        )
    }

    @Test func writeOnceRealFailures() {
        // /dev/full: every write fails ENOSPC — a real no-space injection,
        // not a mock. Absent only on exotic platforms, where this arm skips.
        let full = "/dev/full".withCString { open($0, O_WRONLY | O_CLOEXEC) }
        if full >= 0 {
            defer { close(full) }
            #expect(MCPIntegrationLiveIO.writeOnce(Data("abc".utf8), to: full) == false)
        }
        // A read-only fd fails EBADF through the same single-attempt path.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-mcp-integrations-ro-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        let readOnly = file.path.withCString { open($0, O_RDONLY | O_CLOEXEC) }
        guard readOnly >= 0 else {
            Issue.record("could not open probe file")
            return
        }
        defer { close(readOnly) }
        #expect(MCPIntegrationLiveIO.writeOnce(Data("abc".utf8), to: readOnly) == false)
    }

    @Test func commandUnicodeLookalikesAreInert() throws {
        // Fullwidth (and other non-ASCII) lookalikes of shell metacharacters
        // are inert to POSIX shells — multibyte UTF-8 never parses as syntax
        // — so the byte classifier lets them through. Pins that the rule is
        // byte-anchored, not glyph-anchored.
        for command in [
            "/bin/\u{FF1B}x", // FULLWIDTH SEMICOLON
            "/bin/\u{FF02}x", // FULLWIDTH QUOTATION MARK
            "/bin/\u{FF04}x", // FULLWIDTH DOLLAR SIGN
            "/bin/\u{FF40}x", // FULLWIDTH GRAVE ACCENT
            "/bin/\u{FF3C}x", // FULLWIDTH REVERSE SOLIDUS
            "/bin/\u{FF5C}x", // FULLWIDTH VERTICAL LINE
            "/bin/\u{FF1C}x", // FULLWIDTH LESS-THAN SIGN
            "/bin/\u{FF0F}x", // FULLWIDTH SOLIDUS (not a separator)
        ] {
            let loaded = try MCPIntegrationStore.decode(
                try Self.documentData([Self.validStdio(command: command)])
            ).get()
            guard case .stdio(let stdio) = loaded.integrations[0] else {
                Issue.record("expected stdio")
                return
            }
            #expect(stdio.command == command)
        }
    }

    @Test func commandWhitespaceEdges() throws {
        // Leading whitespace breaks the absolute-path anchor.
        for command in [" /bin/x", "\t/bin/x"] {
            #expect(
                MCPIntegrationStore.decode(
                    try Self.documentData([Self.validStdio(command: command)])
                ) == .failure(.invalidDocument)
            )
        }
        // A tab anywhere is a control byte, and the classic overlooked
        // shell IFS character.
        #expect(
            MCPIntegrationStore.decode(
                try Self.documentData([Self.validStdio(command: "/bin/x\ty")])
            ) == .failure(.invalidDocument)
        )
        // A trailing space is a legal (if odd) filename byte: exec-safe,
        // so accepted.
        let loaded = try MCPIntegrationStore.decode(
            try Self.documentData([Self.validStdio(command: "/bin/x ")])
        ).get()
        guard case .stdio(let stdio) = loaded.integrations[0] else {
            Issue.record("expected stdio")
            return
        }
        #expect(stdio.command == "/bin/x ")
    }

    @Test func argsEnvAndCwdAreNotShellParsed() throws {
        // Only the executed command is metachar-free by construction; args
        // are exec argv elements, env values are execve literals, and cwd is
        // a chdir target — shell syntax in all three is inert data.
        let loaded = try MCPIntegrationStore.decode(
            try Self.documentData([
                Self.validStdio(extra: [
                    "args": [";rm -rf /", "$(id)", "`id`", "| cat", "> /tmp/x", "*.txt", "--flag=(a|b)"],
                    "env": [
                        "EVIL": "$(touch /tmp/pwned)",
                        "TICK": "`id`",
                        "SEMI": "; rm -rf /",
                        "GLOB": "*.txt",
                        "AMP": "a && b",
                    ],
                    "cwd": "/tmp/$pecial `dir` (1);x",
                ])
            ])
        ).get()
        guard case .stdio(let stdio) = loaded.integrations[0] else {
            Issue.record("expected stdio")
            return
        }
        #expect(stdio.args?.count == 7)
        #expect(stdio.env?["EVIL"] == "$(touch /tmp/pwned)")
        #expect(stdio.cwd == "/tmp/$pecial `dir` (1);x")
        // The one env tripwire stays prefix-anchored: the bare marker with
        // no provider is still a marker.
        #expect(
            MCPIntegrationStore.decode(
                try Self.documentData([
                    Self.validStdio(extra: ["env": ["K": "secret-public-ref:"]])
                ])
            ) == .failure(.invalidDocument)
        )
        // ...while a mid-string marker in a header value is an inert literal.
        let headed = try MCPIntegrationStore.decode(
            try Self.documentData([
                Self.validRemote(extra: ["headers": ["K": "see secret-public-ref:file/x here"]])
            ])
        ).get()
        guard case .remote(let remote) = headed.integrations[0] else {
            Issue.record("expected remote")
            return
        }
        #expect(remote.headers?["K"] == .literal("see secret-public-ref:file/x here"))
    }

    @Test func slugifyUsesUnicodeDefaultMapping() {
        // Executor parity runs through Unicode default case conversion (JS
        // toLowerCase), not locale tailoring and not an ASCII fold: dotted
        // capitals and compatibility cased chars fold to ASCII keeps.
        #expect(MCPIntegrationStore.deriveNamespace(name: "ID", endpoint: nil, command: nil) == "id")
        #expect(MCPIntegrationStore.deriveNamespace(name: "\u{130}", endpoint: nil, command: nil) == "i") // LATIN CAPITAL I WITH DOT ABOVE
        #expect(MCPIntegrationStore.deriveNamespace(name: "\u{212A}", endpoint: nil, command: nil) == "k") // KELVIN SIGN
    }

    @Test func queryKeyAllowsNonMetacharPunctuation() throws {
        // Only the query-string metacharacters (& = # ?) and whitespace are
        // excluded; the rest is data the renderer percent-encodes.
        let loaded = try MCPIntegrationStore.decode(
            try Self.documentData([
                Self.validRemote(extra: ["queryParams": [
                    "a/b": "1", "a%b": "2", "a+b": "3", "a,b": "4", "a@b": "5", "a;b": "6", "a:b": "7",
                ]])
            ])
        ).get()
        guard case .remote(let remote) = loaded.integrations[0] else {
            Issue.record("expected remote")
            return
        }
        #expect(remote.queryParams?.count == 7)
    }

    static func validRemote(
        name: String = "GitHub",
        endpoint: String = "https://api.example.com/mcp",
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var base: [String: Any] = ["kind": "mcp-remote", "name": name, "endpoint": endpoint]
        for (key, value) in extra { base[key] = value }
        return base
    }

    static func validStdio(
        name: String = "Helper",
        command: String = "/usr/local/bin/mcp-helper",
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var base: [String: Any] = ["kind": "mcp-stdio", "name": name, "command": command]
        for (key, value) in extra { base[key] = value }
        return base
    }

    static func documentData(_ integrations: [Any], version: Any = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": version, "integrations": integrations])
    }

    static func configDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-mcp-integrations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    static func writeConfigFile(_ data: Data, named name: String, in directory: URL) throws -> URL {
        let file = directory.appendingPathComponent(name, isDirectory: false)
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    static func posixPermissions(of file: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// `Result<Void, E>` is not `Equatable`, so failures assert manually.
    static func expectWriteFailure(
        _ result: Result<Void, MCPIntegrationStoreError>, _ error: MCPIntegrationStoreError
    ) {
        guard case .failure(let actual) = result else {
            Issue.record("expected write failure")
            return
        }
        #expect(actual == error)
    }

    /// A root-owned directory without group/other write, or nil when the
    /// environment offers no such fixture.
    static func foreignSystemDirectory() -> URL? {
        let resolved: String? = "/etc".withCString { raw in
            guard let out = realpath(raw, nil) else { return nil }
            defer { free(out) }
            return String(cString: out)
        }
        guard let path = resolved else { return nil }
        var status = stat()
        let examined = path.withCString { stat($0, &status) }
        guard examined == 0, status.st_uid != getuid(), (status.st_mode & 0o022) == 0 else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    // Fixture factories build through the unchecked init: every default is
    // known-valid (the throwing init has its own tests below), which keeps
    // the sink suites free of try-churn.
    static func remoteModel(
        namespace: String? = "gh",
        name: String = "GitHub",
        endpoint: String = "https://api.example.com/mcp"
    ) -> MCPIntegrationConfig {
        .remote(MCPRemoteIntegration(unchecked: name, endpoint: endpoint, namespace: namespace))
    }

    static func stdioModel(
        namespace: String? = "helper",
        name: String = "Helper",
        command: String = "/usr/local/bin/mcp-helper"
    ) -> MCPIntegrationConfig {
        .stdio(MCPStdioIntegration(unchecked: name, command: command, namespace: namespace))
    }

    static func maximalRemote() -> MCPIntegrationConfig {
        .remote(
            MCPRemoteIntegration(
                unchecked: "GitHub MCP",
                endpoint: "https://api.example.com:8443/mcp",
                remoteTransport: .sse,
                namespace: "github",
                queryParams: [
                    "plain": .literal("value"),
                    "token": .secret(
                        MCPSecretSelector(provider: "file", item: "ci-token"), prefix: "Bearer "
                    ),
                ],
                headers: [
                    "X-Literal": .literal("yes"),
                    "X-Secret": .secret(
                        MCPSecretSelector(provider: "keychain", item: "svc/acct", field: "token"),
                        prefix: nil
                    ),
                ],
                auth: .header(
                    headerName: "Authorization",
                    secret: MCPSecretSelector(provider: "vault-http", item: "deploy/api", field: "key"),
                    prefix: "Bearer "
                )
            )
        )
    }

    static func maximalStdio() -> MCPIntegrationConfig {
        .stdio(
            MCPStdioIntegration(
                unchecked: "Helper",
                command: "/usr/local/bin/mcp-helper",
                args: ["serve", "--port", "8080"],
                env: ["LOG_LEVEL": "debug", "WORKERS": "4"],
                cwd: "/tmp/work",
                namespace: "helper"
            )
        )
    }

    /// One integration whose canonical encoding overflows the 64KB cap on
    /// its own: maxed headers plus maxed query params plus a long endpoint.
    static func maxedRemote() -> MCPIntegrationConfig {
        let big = String(repeating: "v", count: 1024)
        return .remote(
            MCPRemoteIntegration(
                unchecked: "Big",
                endpoint: "https://h/" + String(repeating: "p", count: 2038),
                namespace: "big",
                queryParams: Dictionary(
                    uniqueKeysWithValues: (0..<32).map { ("q\($0)", MCPHeaderValue.literal(big)) }
                ),
                headers: Dictionary(
                    uniqueKeysWithValues: (0..<32).map { ("X-H-\($0)", MCPHeaderValue.literal(big)) }
                ),
                auth: .oauth2(connectionId: "big.user.main")
            )
        )
    }
}

/// Fail-on-command sink IO for the never-fails property test.
final class FakeSinkIO: MCPIntegrationSinkIO, @unchecked Sendable {
    var readResult: Result<MCPIntegrationSet, MCPIntegrationStoreError>
    var writeResult: Result<Void, MCPIntegrationStoreError>
    private(set) var writeCalls: [MCPIntegrationSet] = []
    private(set) var readCalls = 0

    init(
        readResult: Result<MCPIntegrationSet, MCPIntegrationStoreError>,
        writeResult: Result<Void, MCPIntegrationStoreError>
    ) {
        self.readResult = readResult
        self.writeResult = writeResult
    }

    func readSet(directory: URL) -> Result<MCPIntegrationSet, MCPIntegrationStoreError> {
        readCalls += 1
        return readResult
    }

    func writeSet(_ set: MCPIntegrationSet, directory: URL) -> Result<Void, MCPIntegrationStoreError> {
        writeCalls.append(set)
        return writeResult
    }
}

struct SinkError: Equatable {
    let operation: MCPIntegrationSinkOperation
    let error: MCPIntegrationStoreError
}

/// Captures sink error reports. Test-local; never shared across tests.
final class ErrorSink: @unchecked Sendable {
    var calls: [SinkError] = []
}
