#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import Testing
@testable import RVPolicy

@Suite("Secrets provider store")
struct SecretsProviderStoreTests {
    @Test func validBindingsLoadAndLookUp() throws {
        let data = try Self.bindingsData(bindings: [
            Self.validBinding(name: "github-token", provider: "file", item: "github/token"),
            Self.validBinding(
                name: "deploy-key", provider: "vault-http", item: "deploy/key", field: "private"
            ),
        ])
        let loaded = try SecretsProviderStore.decode(data).get()
        #expect(loaded.bindings.count == 2)
        let github = try #require(loaded.binding(named: "github-token"))
        #expect(github.provider == "file")
        #expect(github.item == "github/token")
        #expect(github.field == nil)
        let githubRef = try SecretRef(provider: "file", item: "github/token")
        #expect(github.ref == githubRef)
        let deploy = try #require(loaded.binding(named: "deploy-key"))
        #expect(deploy.field == "private")
        let deployRef = try SecretRef(provider: "vault-http", item: "deploy/key", field: "private")
        #expect(deploy.ref == deployRef)
    }

    @Test func missingFileLoadsEmpty() throws {
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try SecretsProviderStore.load(from: directory).get() == .empty)
    }

    @Test func missingDirectoryLoadsEmpty() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-secrets-providers-missing-\(UUID().uuidString)")
        #expect(SecretsProviderStore.load(from: directory) == .success(.empty))
    }

    @Test func fileAsDirectoryIsUnsafeLocation() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-secrets-providers-fileasdir-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(SecretsProviderStore.load(from: file) == .failure(.unsafeLocation))
    }

    @Test func emptyBindingsListLoads() throws {
        let loaded = try SecretsProviderStore.decode(try Self.bindingsData(bindings: [])).get()
        #expect(loaded == .empty)
        #expect(loaded.binding(named: "anything") == nil)
    }

    @Test("every allowed provider loads", arguments: ["file", "keychain", "vault-http", "env", "exec"])
    func allowedProvider_loads(provider: String) throws {
        let loaded = try SecretsProviderStore.decode(
            try Self.bindingsData(bindings: [Self.validBinding(provider: provider)])
        ).get()
        #expect(loaded.bindings.count == 1)
        #expect(loaded.bindings[0].provider == provider)
    }

    @Test(
        "unknown provider rejected",
        arguments: [
            "vault", "s3", "1password", "FILE", "File", " file", "file ", "file\n",
            "", "vault-http-v2", "../file", "keychain;id", " ", "file\0",
        ]
    )
    func unknownProvider_rejected(provider: String) throws {
        #expect(
            SecretsProviderStore.decode(
                try Self.bindingsData(bindings: [Self.validBinding(provider: provider)])
            ) == .failure(.invalidDocument)
        )
    }

    @Test func bindingNameRules() throws {
        for name in ["a", String(repeating: "b", count: 64), "a-b_c.d9", "0"] {
            let loaded = try SecretsProviderStore.decode(
                try Self.bindingsData(bindings: [Self.validBinding(name: name)])
            ).get()
            #expect(loaded.bindings[0].name == name)
        }
        for name in [
            "", String(repeating: "b", count: 65), "has space", "has/slash", "has:colon",
            "tökén", "has\nnewline", "has\0nul", "has\rcarriage",
        ] {
            #expect(
                SecretsProviderStore.decode(
                    try Self.bindingsData(bindings: [Self.validBinding(name: name)])
                ) == .failure(.invalidDocument)
            )
        }
    }

    @Test func duplicateBindingNamesFailClosed() throws {
        let data = try Self.bindingsData(bindings: [
            Self.validBinding(name: "first"),
            Self.validBinding(name: "second"),
            Self.validBinding(name: "first"),
        ])
        #expect(SecretsProviderStore.decode(data) == .failure(.invalidDocument))
    }

    @Test func bindingCountCapEnforced() throws {
        let thirtyTwo = try SecretsProviderStore.decode(
            try Self.bindingsData(bindings: (0..<32).map { Self.validBinding(name: "binding-\($0)") })
        ).get()
        #expect(thirtyTwo.bindings.count == 32)
        #expect(
            SecretsProviderStore.decode(
                try Self.bindingsData(
                    bindings: (0..<33).map { Self.validBinding(name: "binding-\($0)") }
                )
            ) == .failure(.invalidDocument)
        )
    }

    @Test func mistypedBindingsContainerAndFieldFailClosed() {
        #expect(
            SecretsProviderStore.decode(Data(#"{"version":1,"bindings":null}"#.utf8))
                == .failure(.invalidDocument)
        )
        #expect(
            SecretsProviderStore.decode(
                Data(
                    #"{"version":1,"bindings":[{"name":"a","provider":"file","item":"i","field":123}]}"#
                        .utf8
                )
            ) == .failure(.invalidDocument)
        )
    }

    @Test func bindingRefFailsClosedOnEmptyItemOrUnknownProvider() {
        #expect(ProviderBinding(name: "a", provider: "file", item: "").ref == nil)
        #expect(ProviderBinding(name: "a", provider: "nope", item: "i").ref == nil)
    }

    @Test func itemRules() throws {
        for item in ["x", String(repeating: "i", count: 256), "tökén-🔑-名前", "github/token", "a b"] {
            let loaded = try SecretsProviderStore.decode(
                try Self.bindingsData(bindings: [Self.validBinding(item: item)])
            ).get()
            #expect(loaded.bindings[0].item == item)
        }
        for item in ["", String(repeating: "i", count: 257), "has\nnewline", "has\rreturn", "has\0nul"] {
            #expect(
                SecretsProviderStore.decode(
                    try Self.bindingsData(bindings: [Self.validBinding(item: item)])
                ) == .failure(.invalidDocument)
            )
        }
    }

    @Test func fieldRules() throws {
        let absent = try SecretsProviderStore.decode(
            try Self.bindingsData(bindings: [Self.validBinding()])
        ).get()
        #expect(absent.bindings[0].field == nil)
        for field in ["f", String(repeating: "f", count: 128), "clé-🔑"] {
            let loaded = try SecretsProviderStore.decode(
                try Self.bindingsData(bindings: [Self.validBinding(field: field)])
            ).get()
            #expect(loaded.bindings[0].field == field)
        }
        for field in ["", String(repeating: "f", count: 129), "has\nnewline", "has\0nul"] {
            #expect(
                SecretsProviderStore.decode(
                    try Self.bindingsData(bindings: [Self.validBinding(field: field)])
                ) == .failure(.invalidDocument)
            )
        }
        // Explicit null reads as absent, matching the sibling DTOs.
        var binding = Self.validBinding()
        binding["field"] = NSNull()
        let nulled = try SecretsProviderStore.decode(
            try Self.bindingsData(bindings: [binding])
        ).get()
        #expect(nulled.bindings[0].field == nil)
    }

    @Test func unknownKeysFailClosed() throws {
        let top = try JSONSerialization.data(
            withJSONObject: [
                "version": 1, "bindings": [Self.validBinding()], "future": true,
            ]
        )
        #expect(SecretsProviderStore.decode(top) == .failure(.invalidDocument))
        for key in ["mystery", "secretValue", "apiKey", "token"] {
            var binding = Self.validBinding()
            binding[key] = "hunter2"
            #expect(
                SecretsProviderStore.decode(try Self.bindingsData(bindings: [binding]))
                    == .failure(.invalidDocument)
            )
        }
    }

    @Test func unsupportedVersionsFailClosed() throws {
        for version in [0, 2, 99] {
            #expect(
                SecretsProviderStore.decode(
                    try Self.bindingsData(bindings: [Self.validBinding()], version: version)
                ) == .failure(.unsupportedVersion)
            )
        }
        // Wrong-typed versions are malformed, not merely unsupported.
        #expect(
            SecretsProviderStore.decode(
                try Self.bindingsData(bindings: [Self.validBinding()], version: "1")
            ) == .failure(.invalidDocument)
        )
    }

    @Test func malformedDocumentsFailClosed() throws {
        #expect(SecretsProviderStore.decode(Data("not json".utf8)) == .failure(.invalidDocument))
        #expect(SecretsProviderStore.decode(Data()) == .failure(.invalidDocument))
        #expect(SecretsProviderStore.decode(Data("[]".utf8)) == .failure(.invalidDocument))
        #expect(SecretsProviderStore.decode(Data("{}".utf8)) == .failure(.invalidDocument))
        for document: [String: Any] in [
            ["version": 1],
            ["version": 1, "bindings": "nope"],
            ["version": 1, "bindings": [["provider": "file", "item": "x"]]],
            ["version": 1, "bindings": [["name": "n", "item": "x"]]],
            ["version": 1, "bindings": [["name": "n", "provider": "file"]]],
            ["version": 1, "bindings": [["name": "n", "provider": 42, "item": "x"]]],
            ["version": 1, "bindings": ["nope"]],
            ["bindings": [Self.validBinding()]],
        ] {
            #expect(
                SecretsProviderStore.decode(try JSONSerialization.data(withJSONObject: document))
                    == .failure(.invalidDocument)
            )
        }
    }

    @Test func oversizedDocumentsAreRejected() throws {
        #expect(
            SecretsProviderStore.decode(Data(repeating: 0, count: 65_537)) == .failure(.oversized)
        )
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Self.writeConfigFile(
            Data(repeating: 0x20, count: 65_537),
            named: SecretsProviderStore.fileName,
            in: directory
        )
        #expect(file.lastPathComponent == "secrets-providers.json")
        #expect(SecretsProviderStore.load(from: directory) == .failure(.oversized))
    }

    @Test func onlyOwnerFilesWithoutSymlinksAreLoaded() throws {
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Self.writeConfigFile(
            try Self.bindingsData(bindings: [Self.validBinding()]),
            named: SecretsProviderStore.fileName,
            in: directory
        )
        #expect(try SecretsProviderStore.load(from: directory).get().bindings.count == 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(SecretsProviderStore.load(from: directory) == .failure(.unsafeLocation))
        try FileManager.default.removeItem(at: file)
        let target = directory.appendingPathComponent("target.json")
        try Self.bindingsData(bindings: [Self.validBinding()]).write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        #expect(SecretsProviderStore.load(from: directory) == .failure(.unsafeLocation))
        try FileManager.default.removeItem(at: file)
        try Self.bindingsData(bindings: [Self.validBinding()]).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
        #expect(SecretsProviderStore.load(from: directory) == .failure(.unsafeLocation))
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
            try Self.bindingsData(bindings: [Self.validBinding()]),
            named: SecretsProviderStore.fileName,
            in: real
        )
        #expect(try SecretsProviderStore.load(from: real).get().bindings.count == 1)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(SecretsProviderStore.load(from: link) == .failure(.unsafeLocation))
        // A directory where the file belongs is not a regular file.
        let impostor = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: impostor) }
        try FileManager.default.createDirectory(
            at: impostor.appendingPathComponent(SecretsProviderStore.fileName, isDirectory: true),
            withIntermediateDirectories: true
        )
        #expect(SecretsProviderStore.load(from: impostor) == .failure(.unsafeLocation))
    }

    @Test func refHelperFailsClosed() throws {
        let valid = ProviderBinding(name: "n", provider: "keychain", item: "svc/acct", field: "f")
        let expected = try SecretRef(provider: "keychain", item: "svc/acct", field: "f")
        #expect(valid.ref == expected)
        #expect(ProviderBinding(name: "n", provider: "vault", item: "x").ref == nil)
        #expect(ProviderBinding(name: "n", provider: "", item: "x").ref == nil)
        #expect(ProviderBinding(name: "n", provider: "file", item: "").ref == nil)
    }

    @Test func bindingLookupMissesReturnNil() throws {
        let loaded = try SecretsProviderStore.decode(
            try Self.bindingsData(bindings: [Self.validBinding(name: "present")])
        ).get()
        #expect(loaded.binding(named: "present")?.name == "present")
        #expect(loaded.binding(named: "absent") == nil)
        #expect(loaded.binding(named: "") == nil)
        #expect(loaded.binding(named: "PRESENT") == nil)
    }

    @Test func definitionProviderDefaultsToFile() throws {
        let set = try AgentDefinitionStore.decode(
            try Self.documentData(definitions: [Self.validDefinition()]),
            resourcePolicy: Self.resources()
        ).get()
        let id = try #require(AgentDefinitionID(validating: "claude"))
        #expect(set.definition(id: id)?.secretsProvider == "file")
    }

    @Test(
        "every allowed provider loads in definitions",
        arguments: ["file", "keychain", "vault-http", "env", "exec"]
    )
    func definitionProvider_allowedLoads(provider: String) throws {
        var definition = Self.validDefinition()
        definition["secretsProvider"] = provider
        let set = try AgentDefinitionStore.decode(
            try Self.documentData(definitions: [definition]),
            resourcePolicy: Self.resources()
        ).get()
        let id = try #require(AgentDefinitionID(validating: "claude"))
        #expect(set.definition(id: id)?.secretsProvider == provider)
    }

    @Test(
        "unknown definition provider rejected",
        arguments: ["vault", "", "FILE", " file", "vault-http-v2", "keychain;id", "s3"]
    )
    func definitionProvider_unknownRejected(provider: String) throws {
        var definition = Self.validDefinition()
        definition["secretsProvider"] = provider
        #expect(
            AgentDefinitionStore.decode(
                try Self.documentData(definitions: [definition]),
                resourcePolicy: Self.resources()
            ) == .failure(.invalidDocument)
        )
    }

    @Test func nullDefinitionProviderReadsAsDefault() throws {
        var definition = Self.validDefinition()
        definition["secretsProvider"] = NSNull()
        let set = try AgentDefinitionStore.decode(
            try Self.documentData(definitions: [definition]),
            resourcePolicy: Self.resources()
        ).get()
        let id = try #require(AgentDefinitionID(validating: "claude"))
        #expect(set.definition(id: id)?.secretsProvider == "file")
    }

    @Test func providerSwapChangesRevision() throws {
        let id = try #require(AgentDefinitionID(validating: "claude"))
        func revision(provider: String?) throws -> AgentDefinitionRevision {
            var definition = Self.validDefinition()
            if let provider {
                definition["secretsProvider"] = provider
            }
            let set = try AgentDefinitionStore.decode(
                try Self.documentData(definitions: [definition]),
                resourcePolicy: Self.resources()
            ).get()
            return try #require(set.revision(of: id))
        }
        // A provider swap reads as a new definition requiring fresh identity.
        let implicit = try revision(provider: nil)
        let explicit = try revision(provider: "file")
        let keychain = try revision(provider: "keychain")
        let vault = try revision(provider: "vault-http")
        #expect(implicit == explicit)
        #expect(keychain != implicit)
        #expect(vault != implicit)
        #expect(vault != keychain)
        #expect(try revision(provider: "keychain") == keychain)
    }

    @Test func newFieldLoadsWhileUnknownFieldsStillRejected() throws {
        // The v1 reader rule rests on this mechanism: old binaries, whose
        // key allowlist lacks the new field, reject new documents through
        // the same unknown-field path this asserts stays live.
        var definition = Self.validDefinition()
        definition["secretsProvider"] = "keychain"
        definition["mystery"] = "field"
        #expect(
            AgentDefinitionStore.decode(
                try Self.documentData(definitions: [definition]),
                resourcePolicy: Self.resources()
            ) == .failure(.invalidDocument)
        )
        var smuggled = Self.validDefinition()
        smuggled["secretsProvider"] = "keychain"
        smuggled["secretValue"] = "hunter2"
        #expect(
            AgentDefinitionStore.decode(
                try Self.documentData(definitions: [smuggled]),
                resourcePolicy: Self.resources()
            ) == .failure(.invalidDocument)
        )
    }

    @Test func definitionMigrationInsertsDefaultDeterministically() throws {
        let legacy = try Self.documentData(definitions: [
            Self.validDefinition(id: "claude"), Self.validDefinition(id: "codex"),
        ])
        let first = try #require(AgentDefinitionStore.migrate(legacy))
        let second = try #require(AgentDefinitionStore.migrate(legacy))
        #expect(first == second)
        // The rewrite is already current: migrating again is a no-op,
        // which is what makes the on-disk rewrite one-shot.
        #expect(AgentDefinitionStore.migrate(first) == nil)
        let migrated = try JSONSerialization.jsonObject(with: first) as? [String: Any]
        let definitions = try #require(migrated?["definitions"] as? [[String: Any]])
        #expect(definitions.count == 2)
        #expect(definitions.allSatisfy { $0["secretsProvider"] as? String == "file" })
        // Every other key survives untouched.
        let original = try JSONSerialization.jsonObject(with: legacy) as? [String: Any]
        let originalDefinitions = try #require(original?["definitions"] as? [[String: Any]])
        for (before, after) in zip(originalDefinitions, definitions) {
            #expect(after.count == before.count + 1)
            for (key, value) in before {
                #expect((after[key] as? NSObject) == (value as? NSObject))
            }
        }
        // And the rewritten bytes still decode to the same loaded value.
        let id = try #require(AgentDefinitionID(validating: "claude"))
        let set = try AgentDefinitionStore.decode(first, resourcePolicy: Self.resources()).get()
        #expect(set.definition(id: id)?.secretsProvider == "file")
    }

    @Test func definitionMigrationSkipsCurrentAndMalformed() throws {
        var current = Self.validDefinition()
        current["secretsProvider"] = "keychain"
        #expect(AgentDefinitionStore.migrate(try Self.documentData(definitions: [current])) == nil)
        var nulled = Self.validDefinition()
        nulled["secretsProvider"] = NSNull()
        #expect(AgentDefinitionStore.migrate(try Self.documentData(definitions: [nulled])) == nil)
        #expect(
            AgentDefinitionStore.migrate(
                try Self.documentData(definitions: [current], version: 2)
            ) == nil
        )
        #expect(AgentDefinitionStore.migrate(try Self.documentData(definitions: [])) == nil)
        #expect(AgentDefinitionStore.migrate(Data("not json".utf8)) == nil)
        #expect(AgentDefinitionStore.migrate(Data()) == nil)
        #expect(AgentDefinitionStore.migrate(Data(repeating: 0, count: 65_537)) == nil)
        let mistyped = try JSONSerialization.data(
            withJSONObject: ["version": 1, "definitions": "nope"]
        )
        #expect(AgentDefinitionStore.migrate(mistyped) == nil)
    }

    @Test func definitionLoadRewritesLegacyDocOneShot() throws {
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Self.documentData(definitions: [Self.validDefinition()])
        let file = try Self.writeConfigFile(original, named: "agent-definitions.json", in: directory)
        let id = try #require(AgentDefinitionID(validating: "claude"))
        let set = try AgentDefinitionStore.load(from: directory, resourcePolicy: Self.resources()).get()
        #expect(set.definition(id: id)?.secretsProvider == "file")
        let rewritten = try Data(contentsOf: file)
        #expect(rewritten != original)
        let parsed = try JSONSerialization.jsonObject(with: rewritten) as? [String: Any]
        let definitions = try #require(parsed?["definitions"] as? [[String: Any]])
        #expect(definitions.count == 1)
        #expect(definitions[0]["secretsProvider"] as? String == "file")
        #expect(try Self.posixPermissions(of: file) == 0o600)
        // No staging litter survives the atomic rewrite.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            == ["agent-definitions.json"])
        // Second load is stable: the rewrite was one-shot.
        _ = try AgentDefinitionStore.load(from: directory, resourcePolicy: Self.resources()).get()
        #expect(try Data(contentsOf: file) == rewritten)
    }

    @Test func definitionLoadLeavesInvalidDocUntouched() throws {
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var definition = Self.validDefinition()
        definition["secretsProvider"] = "vault"
        let original = try Self.documentData(definitions: [definition])
        let file = try Self.writeConfigFile(original, named: "agent-definitions.json", in: directory)
        #expect(
            AgentDefinitionStore.load(from: directory, resourcePolicy: Self.resources())
                == .failure(.invalidDocument)
        )
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func definitionMigrationSkippedWhenRewriteWouldOverflowCap() throws {
        // Tune a legacy doc to land within one inserted key of the 64KB
        // cap: migration must skip the rewrite (it would overflow) while
        // the doc still loads with the default.
        func maxedDefinition(id: String, blurbBytes: Int, scopes: Int) -> [String: Any] {
            [
                "id": id,
                "displayName": String(repeating: "d", count: 256),
                "blurb": String(repeating: "x", count: blurbBytes),
                "executable": [
                    "expectedContentDigestSHA256": Self.digest,
                    "requiredTeamID": String(repeating: "T", count: 32),
                    "requiredCodeRequirement": String(repeating: "r", count: 1024),
                ],
                "hookHost": "claude",
                "agentTag": "claude",
                "resourceProfile": "profile-a",
                "credentialBindings": (0..<32).map { "b\($0)-" + String(repeating: "b", count: 59) },
                "requiredAssurance": "launchObserved",
                "authorityCeiling": (0..<scopes).map { "s\($0):" + String(repeating: "s", count: 120) },
            ]
        }
        // Five maxed definitions top out below the window, so a sixth
        // minimal filler carries the total over the cap and the tuned
        // definition shrinks back into the window. Both knobs stay
        // clamped to their schema caps, so the tuned doc stays valid.
        var blurb = 1024
        var scopes = 64
        var legacy = Data()
        for _ in 0..<200 {
            var definitions = (0..<4).map {
                maxedDefinition(id: "agent-\($0)", blurbBytes: 1024, scopes: 64)
            }
            definitions.append(maxedDefinition(id: "tuned", blurbBytes: blurb, scopes: scopes))
            definitions.append(maxedDefinition(id: "filler", blurbBytes: 0, scopes: 0))
            legacy = try Self.documentData(definitions: definitions)
            let gap = AgentDefinitionStore.maximumBytes - legacy.count
            if gap >= 0 && gap < 100 { break }
            if gap >= 100 {
                if blurb < 1024 {
                    blurb = min(1024, blurb + gap - 50)
                } else if scopes < 64 {
                    scopes += 1
                } else {
                    Issue.record("tuning cannot grow into the window")
                    return
                }
            } else {
                if blurb > 0 {
                    blurb = max(0, blurb + gap - 50)
                } else if scopes > 0 {
                    scopes -= 1
                } else {
                    Issue.record("tuning cannot shrink into the window")
                    return
                }
            }
        }
        let gap = AgentDefinitionStore.maximumBytes - legacy.count
        #expect(gap >= 0 && gap < 100)
        #expect(AgentDefinitionStore.migrate(legacy) == nil)
        let tunedID = try #require(AgentDefinitionID(validating: "tuned"))
        let set = try AgentDefinitionStore.decode(legacy, resourcePolicy: Self.resources()).get()
        #expect(set.definition(id: tunedID)?.secretsProvider == "file")
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Self.writeConfigFile(legacy, named: "agent-definitions.json", in: directory)
        _ = try AgentDefinitionStore.load(from: directory, resourcePolicy: Self.resources()).get()
        #expect(try Data(contentsOf: file) == legacy)
    }

    @Test func secretsEntriesRoundTripThroughStore() throws {
        let profile = RuntimeResourceProfile(
            id: "profile-a", projects: ["/tmp/project"],
            secrets: [
                .init(
                    provider: "vault-http", item: "deploy/key", field: "private",
                    env: "DEPLOY_KEY", agents: ["claude"]
                ),
                .init(provider: "file", item: "github/token", env: "GITHUB_TOKEN"),
            ]
        )
        let decoded = try RuntimeResourcePolicyStore.decode(
            JSONEncoder().encode(RuntimeResourcePolicy(profiles: [profile]))
        ).get()
        #expect(decoded.profiles[0].secrets == profile.secrets)
    }

    @Test(
        "every allowed provider loads in entries",
        arguments: ["file", "keychain", "vault-http", "env", "exec"]
    )
    func entryProvider_allowedLoads(provider: String) throws {
        let profile = RuntimeResourceProfile(
            id: "profile-a", projects: ["/tmp/project"],
            secrets: [.init(provider: provider, item: "item", env: "ENTRY_VAR")]
        )
        let decoded = try RuntimeResourcePolicyStore.decode(
            JSONEncoder().encode(RuntimeResourcePolicy(profiles: [profile]))
        ).get()
        #expect(decoded.profiles[0].secrets.count == 1)
    }

    @Test(
        "unknown entry provider rejected",
        arguments: ["vault", "", "FILE", " file", "vault-http-v2", "keychain;id", "s3"]
    )
    func entryProvider_unknownRejected(provider: String) throws {
        let profile = RuntimeResourceProfile(
            id: "profile-a", projects: ["/tmp/project"],
            secrets: [.init(provider: provider, item: "item", env: "ENTRY_VAR")]
        )
        #expect(
            RuntimeResourcePolicyStore.decode(
                (try? JSONEncoder().encode(RuntimeResourcePolicy(profiles: [profile]))) ?? Data()
            ) == .failure(.invalidDocument)
        )
    }

    @Test func legacyDocumentWithoutSecretsKeyLoadsEmpty() throws {
        let raw = """
        {"version":1,"profiles":[{"id":"profile-a","projects":["/tmp/project"],\
        "executableLinks":[],"readFiles":[],"readTrees":[],"writeTrees":[],\
        "credentials":[],"environment":[]}]}
        """
        let decoded = try RuntimeResourcePolicyStore.decode(Data(raw.utf8)).get()
        #expect(decoded.profiles[0].secrets == [])
        #expect(decoded.profiles[0].keychain == [])
    }

    @Test func nullSecretsListReadsAsEmpty() throws {
        let raw = """
        {"version":1,"profiles":[{"id":"profile-a","projects":["/tmp/project"],\
        "executableLinks":[],"readFiles":[],"readTrees":[],"writeTrees":[],\
        "credentials":[],"environment":[],"keychain":[],"secrets":null}]}
        """
        let decoded = try RuntimeResourcePolicyStore.decode(Data(raw.utf8)).get()
        #expect(decoded.profiles[0].secrets == [])
    }

    @Test func entryItemFieldEnvRules() throws {
        func result(
            item: String = "item", field: String? = nil, env: String = "ENTRY_VAR"
        ) -> Result<RuntimeResourcePolicy, RuntimeResourcePolicyError> {
            let profile = RuntimeResourceProfile(
                id: "profile-a", projects: ["/tmp/project"],
                secrets: [.init(provider: "file", item: item, field: field, env: env)]
            )
            return RuntimeResourcePolicyStore.decode(
                (try? JSONEncoder().encode(RuntimeResourcePolicy(profiles: [profile]))) ?? Data()
            )
        }
        #expect(try result(item: String(repeating: "i", count: 256)).get().profiles[0].secrets.count == 1)
        #expect(try result(item: "tökén-🔑-名前").get().profiles[0].secrets[0].item == "tökén-🔑-名前")
        #expect(try result(item: "github/token").get().profiles[0].secrets.count == 1)
        #expect(result(item: "") == .failure(.invalidDocument))
        #expect(result(item: String(repeating: "i", count: 257)) == .failure(.invalidDocument))
        #expect(result(item: "has\nnewline") == .failure(.invalidDocument))
        #expect(result(item: "has\0nul") == .failure(.invalidDocument))
        #expect(try result(field: String(repeating: "f", count: 128)).get()
            .profiles[0].secrets.count == 1)
        #expect(result(field: "") == .failure(.invalidDocument))
        #expect(result(field: String(repeating: "f", count: 129)) == .failure(.invalidDocument))
        #expect(result(field: "has\nnewline") == .failure(.invalidDocument))
        #expect(try result(env: "_OK").get().profiles[0].secrets.count == 1)
        #expect(try result(env: String(repeating: "E", count: 64)).get()
            .profiles[0].secrets.count == 1)
        #expect(result(env: "") == .failure(.invalidDocument))
        #expect(result(env: "9LIVES") == .failure(.invalidDocument))
        #expect(result(env: "has-dash") == .failure(.invalidDocument))
        #expect(result(env: "has space") == .failure(.invalidDocument))
        #expect(result(env: String(repeating: "E", count: 65)) == .failure(.invalidDocument))
    }

    @Test(
        "reserved env names rejected in entries",
        arguments: ["PATH", "HOME", "http_proxy", "NO_PROXY", "TMPDIR"]
    )
    func entryEnv_reservedRejected(env: String) {
        let profile = RuntimeResourceProfile(
            id: "profile-a", projects: ["/tmp/project"],
            secrets: [.init(provider: "file", item: "item", env: env)]
        )
        #expect(
            RuntimeResourcePolicyStore.decode(
                (try? JSONEncoder().encode(RuntimeResourcePolicy(profiles: [profile]))) ?? Data()
            ) == .failure(.invalidDocument)
        )
    }

    @Test func entryEnvCollisionsFailClosed() throws {
        func result(
            secrets: [RuntimeResourceProfile.BrokerEntry],
            environment: [RuntimeResourceProfile.Environment] = [],
            keychain: [RuntimeResourceProfile.KeychainEntry] = []
        ) -> Result<RuntimeResourcePolicy, RuntimeResourcePolicyError> {
            let profile = RuntimeResourceProfile(
                id: "profile-a", projects: ["/tmp/project"],
                environment: environment, keychain: keychain, secrets: secrets
            )
            return RuntimeResourcePolicyStore.decode(
                (try? JSONEncoder().encode(RuntimeResourcePolicy(profiles: [profile]))) ?? Data()
            )
        }
        func entry(env: String) -> RuntimeResourceProfile.BrokerEntry {
            .init(provider: "file", item: "item", env: env)
        }
        // Distinct names across all three injected-variable sources pass.
        #expect(try result(
            secrets: [entry(env: "SECRETS_VAR")],
            environment: [.init(name: "ENV_VAR", literalValue: "1")],
            keychain: [.init(service: "s", account: "a", env: "KEYCHAIN_VAR")]
        ).get().profiles[0].secrets.count == 1)
        // Every collision direction fails.
        #expect(result(secrets: [entry(env: "DUP"), entry(env: "DUP")])
            == .failure(.invalidDocument))
        #expect(result(
            secrets: [entry(env: "SHARED")],
            environment: [.init(name: "SHARED", literalValue: "1")]
        ) == .failure(.invalidDocument))
        #expect(result(
            secrets: [entry(env: "SHARED")],
            keychain: [.init(service: "s", account: "a", env: "SHARED")]
        ) == .failure(.invalidDocument))
    }

    @Test func entryAgentsFilterRules() throws {
        func result(agents: [String]?) -> Result<RuntimeResourcePolicy, RuntimeResourcePolicyError> {
            let profile = RuntimeResourceProfile(
                id: "profile-a", projects: ["/tmp/project"],
                secrets: [.init(provider: "file", item: "item", env: "ENTRY_VAR", agents: agents)]
            )
            return RuntimeResourcePolicyStore.decode(
                (try? JSONEncoder().encode(RuntimeResourcePolicy(profiles: [profile]))) ?? Data()
            )
        }
        #expect(try result(agents: nil).get().profiles[0].secrets[0].agents == nil)
        #expect(try result(agents: []).get().profiles[0].secrets[0].agents == nil)
        #expect(try result(agents: ["claude", "codex"]).get()
            .profiles[0].secrets[0].agents == ["claude", "codex"])
        #expect(try result(agents: (0..<8).map { "agent-\($0)" }).get()
            .profiles[0].secrets[0].agents?.count == 8)
        #expect(try result(agents: [String(repeating: "a", count: 32)]).get()
            .profiles[0].secrets.count == 1)
        #expect(result(agents: ["claude", "claude"]) == .failure(.invalidDocument))
        #expect(result(agents: ["not an id"]) == .failure(.invalidDocument))
        #expect(result(agents: (0..<9).map { "agent-\($0)" }) == .failure(.invalidDocument))
        #expect(result(agents: [String(repeating: "a", count: 33)])
            == .failure(.invalidDocument))
    }

    @Test func secretsCountCapEnforced() throws {
        let eight = RuntimeResourceProfile(
            id: "profile-a", projects: ["/tmp/project"],
            secrets: (0..<8).map { .init(provider: "file", item: "item-\($0)", env: "VAR_\($0)") }
        )
        #expect(try RuntimeResourcePolicyStore.decode(
            JSONEncoder().encode(RuntimeResourcePolicy(profiles: [eight]))
        ).get().profiles[0].secrets.count == 8)
        let nine = RuntimeResourceProfile(
            id: "profile-a", projects: ["/tmp/project"],
            secrets: (0..<9).map { .init(provider: "file", item: "item-\($0)", env: "VAR_\($0)") }
        )
        #expect(RuntimeResourcePolicyStore.decode(
            try JSONEncoder().encode(RuntimeResourcePolicy(profiles: [nine]))
        ) == .failure(.invalidDocument))
    }

    @Test func secretsEntriesChangeRevision() throws {
        func definition(
            secrets: [RuntimeResourceProfile.BrokerEntry],
            provider: String = "file"
        ) -> AgentDefinition {
            AgentDefinition(
                id: AgentDefinitionID(rawValue: "claude"),
                displayName: "Claude",
                blurb: "Anthropic coding agent.",
                executableRequirement: ExecutableRequirement(
                    expectedContentDigestSHA256: Self.digest
                ),
                hookHost: .claude,
                agentTag: "claude",
                resourceProfile: RuntimeResourceProfile(
                    id: "profile-a", projects: ["/tmp/project"], secrets: secrets
                ),
                credentialBindings: ["github-token"],
                secretsProvider: provider,
                requiredAssurance: .launchObserved,
                authorityCeiling: AgentAuthority(scopes: ["shell.exec"])
            )
        }
        let baseline = AgentDefinitionRevision.resolve(definition(secrets: []))
        #expect(AgentDefinitionRevision.resolve(definition(secrets: [])) == baseline)
        let one = RuntimeResourceProfile.BrokerEntry(
            provider: "file", item: "github/token", env: "GITHUB_TOKEN"
        )
        #expect(AgentDefinitionRevision.resolve(definition(secrets: [one])) != baseline)
        // Every entry field feeds the digest.
        var byProvider = one
        byProvider.provider = "keychain"
        #expect(AgentDefinitionRevision.resolve(definition(secrets: [byProvider]))
            != AgentDefinitionRevision.resolve(definition(secrets: [one])))
        var byItem = one
        byItem.item = "other/token"
        #expect(AgentDefinitionRevision.resolve(definition(secrets: [byItem]))
            != AgentDefinitionRevision.resolve(definition(secrets: [one])))
        var byField = one
        byField.field = "token"
        #expect(AgentDefinitionRevision.resolve(definition(secrets: [byField]))
            != AgentDefinitionRevision.resolve(definition(secrets: [one])))
        var byEnv = one
        byEnv.env = "OTHER_TOKEN"
        #expect(AgentDefinitionRevision.resolve(definition(secrets: [byEnv]))
            != AgentDefinitionRevision.resolve(definition(secrets: [one])))
        var byAgents = one
        byAgents.agents = ["claude"]
        #expect(AgentDefinitionRevision.resolve(definition(secrets: [byAgents]))
            != AgentDefinitionRevision.resolve(definition(secrets: [one])))
        // Entry order is insignificant: the canonical form sorts.
        let two = RuntimeResourceProfile.BrokerEntry(
            provider: "vault-http", item: "deploy/key", env: "DEPLOY_KEY"
        )
        #expect(AgentDefinitionRevision.resolve(definition(secrets: [one, two]))
            == AgentDefinitionRevision.resolve(definition(secrets: [two, one])))
    }

    @Test func entryRefHelperFailsClosed() throws {
        let valid = RuntimeResourceProfile.BrokerEntry(
            provider: "env", item: "bundle", field: "key", env: "BUNDLE_KEY"
        )
        let expected = try SecretRef(provider: "env", item: "bundle", field: "key")
        #expect(valid.ref == expected)
        #expect(RuntimeResourceProfile.BrokerEntry(
            provider: "vault", item: "x", env: "E"
        ).ref == nil)
        #expect(RuntimeResourceProfile.BrokerEntry(
            provider: "file", item: "", env: "E"
        ).ref == nil)
    }

    @Test func emptyEntryAgentsNormalizeToNil() throws {
        let entry = try JSONDecoder().decode(
            RuntimeResourceProfile.BrokerEntry.self,
            from: Data(#"{"provider":"file","item":"i","env":"E","agents":[]}"#.utf8)
        )
        #expect(entry.agents == nil)
    }

    @Test func resourceMigrationInsertsEmptyList() throws {
        let legacy = """
        {"version":1,"profiles":\
        [{"id":"with-secrets","projects":["/tmp/project"],"executableLinks":[],\
        "readFiles":[],"readTrees":[],"writeTrees":[],"credentials":[],\
        "environment":[],"keychain":[],\
        "secrets":[{"provider":"file","item":"github/token","env":"GITHUB_TOKEN"}]},\
        {"id":"legacy","projects":["/tmp/project"],"executableLinks":[],\
        "readFiles":[],"readTrees":[],"writeTrees":[],"credentials":[],\
        "environment":[]}]}
        """
        let legacyData = Data(legacy.utf8)
        let migrated = try #require(RuntimeResourcePolicyStore.migrate(legacyData))
        #expect(RuntimeResourcePolicyStore.migrate(legacyData) == migrated)
        #expect(RuntimeResourcePolicyStore.migrate(migrated) == nil)
        let decoded = try RuntimeResourcePolicyStore.decode(migrated).get()
        #expect(decoded.profiles.count == 2)
        // Present entries survive the migration untouched.
        #expect(decoded.profiles[0].secrets
            == [.init(provider: "file", item: "github/token", env: "GITHUB_TOKEN")])
        #expect(decoded.profiles[1].secrets == [])
    }

    @Test func resourceMigrationSkipsCurrentAndMalformed() throws {
        let current = RuntimeResourcePolicy(profiles: [
            RuntimeResourceProfile(id: "profile-a", projects: ["/tmp/project"], secrets: []),
        ])
        #expect(RuntimeResourcePolicyStore.migrate(try JSONEncoder().encode(current)) == nil)
        #expect(RuntimeResourcePolicyStore.migrate(
            try JSONEncoder().encode(RuntimeResourcePolicy(version: 2))
        ) == nil)
        #expect(RuntimeResourcePolicyStore.migrate(
            try JSONEncoder().encode(RuntimeResourcePolicy(profiles: []))
        ) == nil)
        #expect(RuntimeResourcePolicyStore.migrate(Data("not json".utf8)) == nil)
        #expect(RuntimeResourcePolicyStore.migrate(Data()) == nil)
        #expect(RuntimeResourcePolicyStore.migrate(Data(repeating: 0, count: 65_537)) == nil)
    }

    @Test func resourceLoadRewritesLegacyDocOneShot() throws {
        let legacy = """
        {"version":1,"profiles":[{"id":"profile-a","projects":["/tmp/project"],\
        "executableLinks":[],"readFiles":[],"readTrees":[],"writeTrees":[],\
        "credentials":[],"environment":[]}]}
        """
        let original = Data(legacy.utf8)
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Self.writeConfigFile(original, named: "runtime-resources.json", in: directory)
        let policy = try RuntimeResourcePolicyStore.load(from: directory).get()
        #expect(policy.profiles[0].secrets == [])
        let rewritten = try Data(contentsOf: file)
        #expect(rewritten != original)
        let parsed = try JSONSerialization.jsonObject(with: rewritten) as? [String: Any]
        let profiles = try #require(parsed?["profiles"] as? [[String: Any]])
        #expect(profiles.count == 1)
        #expect((profiles[0]["secrets"] as? [Any])?.isEmpty == true)
        #expect(try Self.posixPermissions(of: file) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            == ["runtime-resources.json"])
        _ = try RuntimeResourcePolicyStore.load(from: directory).get()
        #expect(try Data(contentsOf: file) == rewritten)
    }

    @Test func resourceLoadLeavesInvalidDocUntouched() throws {
        let profile = RuntimeResourceProfile(
            id: "profile-a", projects: ["/tmp/project"],
            secrets: [.init(provider: "vault", item: "item", env: "ENTRY_VAR")]
        )
        let original = try JSONEncoder().encode(RuntimeResourcePolicy(profiles: [profile]))
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Self.writeConfigFile(original, named: "runtime-resources.json", in: directory)
        #expect(RuntimeResourcePolicyStore.load(from: directory) == .failure(.invalidDocument))
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func resourceMalformedAndOversizedFailClosed() throws {
        #expect(RuntimeResourcePolicyStore.decode(Data("not json".utf8)) == .failure(.invalidDocument))
        #expect(RuntimeResourcePolicyStore.decode(Data()) == .failure(.invalidDocument))
        #expect(RuntimeResourcePolicyStore.decode(Data("[]".utf8)) == .failure(.invalidDocument))
        #expect(RuntimeResourcePolicyStore.decode(Data("{}".utf8)) == .failure(.invalidDocument))
        #expect(RuntimeResourcePolicyStore.decode(Data(repeating: 0, count: 65_537))
            == .failure(.oversized))
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try Self.writeConfigFile(
            Data(repeating: 0x20, count: 65_537), named: "runtime-resources.json", in: directory
        )
        #expect(RuntimeResourcePolicyStore.load(from: directory) == .failure(.oversized))
    }

    @Test func groupWritableDirectoryIsRejected() throws {
        let directory = try Self.configDirectory()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path
            )
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777], ofItemAtPath: directory.path
        )
        #expect(SecretsProviderStore.load(from: directory) == .failure(.unsafeLocation))
        #expect(RuntimeResourcePolicyStore.load(from: directory) == .failure(.unsafeLocation))
        #expect(AgentDefinitionStore.load(from: directory, resourcePolicy: Self.resources())
            == .failure(.unsafeLocation))
    }

    @Test func fileWhereDirectoryBelongsIsRejected() throws {
        let impostor = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-secrets-providers-file-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: impostor) }
        try Data("not a directory".utf8).write(to: impostor)
        // Opening a regular file as the config directory fails outside
        // ENOENT, so every store fails closed with unsafeLocation.
        #expect(SecretsProviderStore.load(from: impostor) == .failure(.unsafeLocation))
        #expect(RuntimeResourcePolicyStore.load(from: impostor) == .failure(.unsafeLocation))
        #expect(AgentDefinitionStore.load(from: impostor, resourcePolicy: Self.resources())
            == .failure(.unsafeLocation))
    }

    @Test func resourceMigrationSkippedWhenRewriteWouldOverflowCap() throws {
        // One legacy profile tuned to land within the inserted key of
        // the 64KB cap: migration skips the rewrite while the doc loads.
        func legacyData(files: Int, pad: Int) throws -> Data {
            let profile: [String: Any] = [
                "id": "profile-a",
                "projects": ["/tmp/p" + String(repeating: "p", count: pad)],
                "agents": [],
                "executableLinks": [],
                "readFiles": (0..<files).map { _ in "/t/" + String(repeating: "f", count: 1021) },
                "readTrees": [],
                "writeTrees": [],
                "credentials": [],
                "environment": [],
                "keychain": [],
            ]
            return try JSONSerialization.data(
                withJSONObject: ["version": 1, "profiles": [profile]]
            )
        }
        var files = 60
        var pad = 0
        var legacy = Data()
        for _ in 0..<200 {
            legacy = try legacyData(files: files, pad: pad)
            let gap = RuntimeResourcePolicyStore.maximumBytes - legacy.count
            // The inserted `"secrets":[]` grows the doc by 13 bytes.
            if gap >= 0 && gap < 10 { break }
            if gap >= 10 {
                if pad < 1018 {
                    pad = min(1018, pad + gap - 5)
                } else if files < 64 {
                    files += 1
                } else {
                    Issue.record("tuning cannot grow into the window")
                    return
                }
            } else {
                if pad > 0 {
                    pad = max(0, pad + gap - 5)
                } else if files > 0 {
                    files -= 1
                } else {
                    Issue.record("tuning cannot shrink into the window")
                    return
                }
            }
        }
        let gap = RuntimeResourcePolicyStore.maximumBytes - legacy.count
        #expect(gap >= 0 && gap < 10)
        #expect(RuntimeResourcePolicyStore.migrate(legacy) == nil)
        let policy = try RuntimeResourcePolicyStore.decode(legacy).get()
        #expect(policy.profiles[0].secrets == [])
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Self.writeConfigFile(legacy, named: "runtime-resources.json", in: directory)
        _ = try RuntimeResourcePolicyStore.load(from: directory).get()
        #expect(try Data(contentsOf: file) == legacy)
    }

    @Test func rewriteRefusesMissingSwappedAndUnwritableFiles() throws {
        let directory = try Self.configDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Self.writeConfigFile(
            Data("{\"version\":1}".utf8), named: "rewrite-target.json", in: directory
        )
        let directoryFD = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        #expect(directoryFD >= 0)
        defer { close(directoryFD) }
        let identity = try #require(Self.identity(of: file))
        let replacement = Data("{\"version\":1,\"rewritten\":true}".utf8)
        // The live file still matches: the rewrite lands atomically.
        #expect(MigratedDocumentRewrite.rewrite(
            fileName: "rewrite-target.json",
            inDirectory: directoryFD,
            expectedDevice: identity.device,
            expectedInode: identity.inode,
            bytes: replacement
        ))
        #expect(try Data(contentsOf: file) == replacement)
        #expect(try Self.posixPermissions(of: file) == 0o600)
        let rotated = try #require(Self.identity(of: file))
        // A missing file has no identity to match.
        #expect(MigratedDocumentRewrite.rewrite(
            fileName: "absent.json",
            inDirectory: directoryFD,
            expectedDevice: rotated.device,
            expectedInode: rotated.inode,
            bytes: replacement
        ) == false)
        // A stale identity aborts instead of clobbering whoever moved in.
        #expect(MigratedDocumentRewrite.rewrite(
            fileName: "rewrite-target.json",
            inDirectory: directoryFD,
            expectedDevice: rotated.device,
            expectedInode: rotated.inode &+ 1,
            bytes: Data("{\"version\":1,\"clobbered\":true}".utf8)
        ) == false)
        #expect(try Data(contentsOf: file) == replacement)
        // An unwritable directory cannot stage the temp file.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: directory.path
        )
        #expect(MigratedDocumentRewrite.rewrite(
            fileName: "rewrite-target.json",
            inDirectory: directoryFD,
            expectedDevice: rotated.device,
            expectedInode: rotated.inode,
            bytes: Data("{\"version\":1,\"clobbered\":true}".utf8)
        ) == false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path
        )
        #expect(try Data(contentsOf: file) == replacement)
        // A symlink where the file belongs is never followed.
        try FileManager.default.removeItem(at: file)
        let target = directory.appendingPathComponent("link-target.json")
        try Data("{\"version\":1,\"linked\":true}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        #expect(MigratedDocumentRewrite.rewrite(
            fileName: "rewrite-target.json",
            inDirectory: directoryFD,
            expectedDevice: rotated.device,
            expectedInode: rotated.inode,
            bytes: replacement
        ) == false)
        #expect(try Data(contentsOf: target) == Data("{\"version\":1,\"linked\":true}".utf8))
    }
}

extension SecretsProviderStoreTests {
    static let digest = String(repeating: "ab", count: 32)

    static func configDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-secrets-providers-\(UUID().uuidString)", isDirectory: true)
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

    static func identity(of file: URL) -> (device: UInt64, inode: UInt64)? {
        var status = stat()
        guard file.path.withCString({ stat($0, &status) }) == 0 else { return nil }
        return (UInt64(status.st_dev), UInt64(status.st_ino))
    }

    static func resources() -> RuntimeResourcePolicy {
        RuntimeResourcePolicy(profiles: [
            RuntimeResourceProfile(id: "profile-a", projects: ["/tmp/project"]),
        ])
    }

    static func validDefinition(id: String = "claude") -> [String: Any] {
        [
            "id": id,
            "displayName": "Claude",
            "blurb": "Anthropic coding agent.",
            "executable": ["expectedContentDigestSHA256": digest],
            "hookHost": "claude",
            "agentTag": "claude",
            "resourceProfile": "profile-a",
            "credentialBindings": ["github-token"],
            "requiredAssurance": "launchObserved",
            "authorityCeiling": ["shell.exec", "fs.read"],
        ]
    }

    static func documentData(definitions: [[String: Any]], version: Any = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": version, "definitions": definitions])
    }

    static func validBinding(
        name: String = "github-token",
        provider: String = "file",
        item: String = "github/token",
        field: String? = nil
    ) -> [String: Any] {
        var binding: [String: Any] = ["name": name, "provider": provider, "item": item]
        if let field {
            binding["field"] = field
        }
        return binding
    }

    static func bindingsData(bindings: [[String: Any]], version: Any = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": version, "bindings": bindings])
    }

    @Test func strictKeysRejectIntegerCodingKeys() {
        #expect(ProviderStrictKey(intValue: 7) == nil)
    }
}
