import Foundation
import RVDomain
import Testing
@testable import RVPolicy

@Suite("Agent definition store")
struct AgentDefinitionStoreTests {
    @Test func validConfigLoadsAndRevisionIsStable() throws {
        let resources = Self.resources()
        let first = try AgentDefinitionStore.decode(
            Self.documentData(definitions: [Self.validDefinition()]), resourcePolicy: resources
        ).get()
        let second = try AgentDefinitionStore.decode(
            Self.documentData(definitions: [Self.validDefinition()]), resourcePolicy: resources
        ).get()
        #expect(first == second)
        let id = try #require(AgentDefinitionID(validating: "claude"))
        let definition = try #require(first.definition(id: id))
        #expect(definition.displayName == "Claude")
        #expect(definition.executableRequirement.expectedContentDigestSHA256 == Self.digest)
        #expect(definition.hookHost == .claude)
        #expect(definition.agentTag == "claude")
        #expect(definition.resourceProfile == resources.profiles[0])
        #expect(definition.credentialBindings == ["github-token"])
        #expect(definition.requiredAssurance == .launchObserved)
        #expect(definition.authorityCeiling == AgentAuthority(scopes: ["fs.read", "shell.exec"]))
        // The stored revision is the PR1 canonical revision of the resolved
        // definition, not an independent digest.
        #expect(first.revision(of: id) == AgentDefinitionRevision.resolve(definition))
        #expect(first.revision(of: id) == second.revision(of: id))
    }

    @Test func securityRelevantEditChangesRevision() throws {
        let resources = Self.resources()
        let id = try #require(AgentDefinitionID(validating: "claude"))
        let baseline = try #require(
            try AgentDefinitionStore.decode(
                Self.documentData(definitions: [Self.validDefinition()]),
                resourcePolicy: resources
            ).get().revision(of: id)
        )
        func revision(
            for mutate: (inout [String: Any]) -> Void, resources: RuntimeResourcePolicy? = nil
        ) throws -> AgentDefinitionRevision {
            var definition = Self.validDefinition()
            mutate(&definition)
            let set = try AgentDefinitionStore.decode(
                Self.documentData(definitions: [definition]),
                resourcePolicy: resources ?? Self.resources()
            ).get()
            return try #require(set.revision(of: id))
        }
        #expect(try revision { $0["executable"] = ["expectedContentDigestSHA256": Self.otherDigest] }
            != baseline)
        #expect(try revision { $0["credentialBindings"] = ["github-token", "npm-token"] } != baseline)
        #expect(try revision { $0["authorityCeiling"] = ["shell.exec"] } != baseline)
        #expect(try revision { $0["requiredAssurance"] = "unattested" } != baseline)
        #expect(try revision { $0["agentTag"] = "claude-2" } != baseline)
        // Same profile name but edited profile content: the revision covers
        // the RESOLVED profile state, not the name.
        var edited = Self.resources()
        edited.profiles[0].projects = ["/tmp/other-project"]
        #expect(try revision(for: { _ in }, resources: edited) != baseline)
    }

    @Test func displayOnlyEditDoesNotChangeRevision() throws {
        let id = try #require(AgentDefinitionID(validating: "claude"))
        let baseline = try AgentDefinitionStore.decode(
            Self.documentData(definitions: [Self.validDefinition()]),
            resourcePolicy: Self.resources()
        ).get()
        var edited = Self.validDefinition()
        edited["displayName"] = "Claude Renamed"
        edited["blurb"] = "A brand-new marketing blurb."
        let reloaded = try AgentDefinitionStore.decode(
            Self.documentData(definitions: [edited]), resourcePolicy: Self.resources()
        ).get()
        #expect(reloaded.revision(of: id) == baseline.revision(of: id))
        #expect(reloaded.definition(id: id)?.displayName == "Claude Renamed")
    }

    @Test func missingFileLoadsEmpty() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-definitions-missing-\(UUID().uuidString)")
        let set = try AgentDefinitionStore.load(
            from: directory, resourcePolicy: Self.resources()
        ).get()
        #expect(set == .empty)
    }

    @Test func onlyOwnerFilesWithoutSymlinksAreLoaded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-definitions-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // The store rejects group-writable directories; under umask 002 the
        // default directory mode is 0775, which must not fail this test.
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let file = RVPolicyPaths.agentDefinitionsFile(inConfigDir: root)
        #expect(file.lastPathComponent == "agent-definitions.json")
        let data = try Self.documentData(definitions: [Self.validDefinition()])
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(
            try AgentDefinitionStore.load(from: root, resourcePolicy: Self.resources())
                .get().resolved.count == 1
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(
            AgentDefinitionStore.load(from: root, resourcePolicy: Self.resources())
                == .failure(.unsafeLocation)
        )
        try FileManager.default.removeItem(at: file)
        #expect(
            try AgentDefinitionStore.load(from: root, resourcePolicy: Self.resources())
                .get() == .empty
        )
        let target = root.appendingPathComponent("target.json")
        try data.write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        #expect(
            AgentDefinitionStore.load(from: root, resourcePolicy: Self.resources())
                == .failure(.unsafeLocation)
        )
        try FileManager.default.removeItem(at: file)
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root.path)
        #expect(
            AgentDefinitionStore.load(from: root, resourcePolicy: Self.resources())
                == .failure(.unsafeLocation)
        )
    }

    @Test func symlinkedConfigDirectoryIsRejected() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-definitions-dirlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let real = base.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(
            at: real, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let file = RVPolicyPaths.agentDefinitionsFile(inConfigDir: real)
        try Self.documentData(definitions: [Self.validDefinition()]).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(
            try AgentDefinitionStore.load(from: real, resourcePolicy: Self.resources())
                .get().resolved.count == 1
        )
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(
            AgentDefinitionStore.load(from: link, resourcePolicy: Self.resources())
                == .failure(.unsafeLocation)
        )
    }

    @Test func signedExecutablePinsLoad() throws {
        var definition = Self.validDefinition()
        definition["executable"] = [
            "expectedContentDigestSHA256": Self.digest,
            "requiredTeamID": "ABCDE12345",
            "requiredCodeRequirement": "identifier \"com.example.tool\"",
        ]
        let set = try AgentDefinitionStore.decode(
            Self.documentData(definitions: [definition]), resourcePolicy: Self.resources()
        ).get()
        let id = try #require(AgentDefinitionID(validating: "claude"))
        let loaded = try #require(set.definition(id: id))
        #expect(loaded.executableRequirement.expectedContentDigestSHA256 == Self.digest)
        #expect(loaded.executableRequirement.requiredTeamID == "ABCDE12345")
        #expect(
            loaded.executableRequirement.requiredCodeRequirement
                == "identifier \"com.example.tool\""
        )
        #expect(loaded.executableRequirement.allowsUnsigned == false)
    }

    @Test func boundaryValuesAtCapLoad() throws {
        var definition = Self.validDefinition(id: String(repeating: "a", count: 32))
        definition["credentialBindings"] = [String(repeating: "b", count: 64)]
        definition["authorityCeiling"] = [String(repeating: "c", count: 128)]
        let set = try AgentDefinitionStore.decode(
            Self.documentData(definitions: [definition]), resourcePolicy: Self.resources()
        ).get()
        #expect(set.resolved.count == 1)
    }

    @Test func oversizedDocumentsAreRejected() throws {
        #expect(
            AgentDefinitionStore.decode(
                Data(repeating: 0, count: 65_537), resourcePolicy: Self.resources()
            ) == .failure(.oversized)
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-definitions-huge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let file = RVPolicyPaths.agentDefinitionsFile(inConfigDir: root)
        try Data(repeating: 0x20, count: 65_537).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(
            AgentDefinitionStore.load(from: root, resourcePolicy: Self.resources())
                == .failure(.oversized)
        )
    }

    @Test func malformedDocumentsFailClosed() throws {
        #expect(Self.result(for: Data("not json".utf8)) == .failure(.invalidDocument))
        #expect(try Self.result(definitions: [])?.get() == .empty)
        // Missing required key.
        var missing = Self.validDefinition()
        missing.removeValue(forKey: "executable")
        #expect(Self.result(definitions: [missing]) == .failure(.invalidDocument))
        // Bad definition id.
        #expect(Self.result(mutating: { $0["id"] = "not an id" }) == .failure(.invalidDocument))
        #expect(Self.result(mutating: { $0["id"] = "" }) == .failure(.invalidDocument))
        // Over the 32-byte tag-wire cap.
        #expect(
            Self.result(mutating: { $0["id"] = String(repeating: "a", count: 33) })
                == .failure(.invalidDocument)
        )
        // Display-text bounds: empty name, embedded line breaks.
        #expect(Self.result(mutating: { $0["displayName"] = "" }) == .failure(.invalidDocument))
        #expect(
            Self.result(mutating: { $0["displayName"] = "has\nnewline" })
                == .failure(.invalidDocument)
        )
        #expect(
            Self.result(mutating: { $0["blurb"] = "has\rreturn" }) == .failure(.invalidDocument)
        )
        // Reserved snapshot id is not definable in operator config.
        #expect(Self.result(mutating: { $0["id"] = "adhoc" }) == .failure(.invalidDocument))
        // Malformed executable requirements.
        #expect(
            Self.result(mutating: { $0["executable"] = ["expectedContentDigestSHA256": "abc"] })
                == .failure(.invalidDocument)
        )
        #expect(
            Self.result(mutating: {
                $0["executable"] = ["expectedContentDigestSHA256": String(repeating: "A", count: 64)]
            }) == .failure(.invalidDocument)
        )
        #expect(
            Self.result(mutating: { $0["executable"] = ["requiredTeamID": "not a team!"] })
                == .failure(.invalidDocument)
        )
        #expect(
            Self.result(mutating: { $0["executable"] = ["requiredTeamID": ""] })
                == .failure(.invalidDocument)
        )
        #expect(
            Self.result(mutating: {
                $0["executable"] = ["requiredCodeRequirement": "has\nnewline"]
            }) == .failure(.invalidDocument)
        )
        #expect(
            Self.result(mutating: { $0["executable"] = ["allowsUnsigned": false] })
                == .failure(.invalidDocument)
        )
        // Explicit unsigned opt-in with no pins is well-formed.
        #expect(
            try Self.result(mutating: { $0["executable"] = ["allowsUnsigned": true] })?.get()
                .resolved.count == 1
        )
        // Unknown integration values.
        #expect(Self.result(mutating: { $0["hookHost"] = "evilhost" }) == .failure(.invalidDocument))
        #expect(Self.result(mutating: { $0["agentTag"] = "not an id" }) == .failure(.invalidDocument))
        #expect(
            Self.result(mutating: { $0["requiredAssurance"] = "strongly-attested" })
                == .failure(.invalidDocument)
        )
        // Unresolvable resource profile.
        #expect(
            Self.result(mutating: { $0["resourceProfile"] = "missing" })
                == .failure(.invalidDocument)
        )
        // Over the 64-byte profile-reference cap.
        #expect(
            Self.result(mutating: {
                $0["resourceProfile"] = String(repeating: "d", count: 65)
            }) == .failure(.invalidDocument)
        )
        // Malformed bindings and ceilings.
        #expect(
            Self.result(mutating: { $0["credentialBindings"] = ["not a binding!"] })
                == .failure(.invalidDocument)
        )
        #expect(
            Self.result(mutating: { $0["credentialBindings"] = ["a", "a"] })
                == .failure(.invalidDocument)
        )
        // Over the 64-byte binding cap.
        #expect(
            Self.result(mutating: {
                $0["credentialBindings"] = [String(repeating: "b", count: 65)]
            }) == .failure(.invalidDocument)
        )
        #expect(
            Self.result(mutating: { $0["authorityCeiling"] = ["has space"] })
                == .failure(.invalidDocument)
        )
        #expect(
            Self.result(mutating: { $0["authorityCeiling"] = ["a", "a"] })
                == .failure(.invalidDocument)
        )
        // Over the 128-byte scope cap.
        #expect(
            Self.result(mutating: {
                $0["authorityCeiling"] = [String(repeating: "c", count: 129)]
            }) == .failure(.invalidDocument)
        )
        // Too many definitions.
        #expect(
            Self.result(
                definitions: (0..<33).map { Self.validDefinition(id: "agent-\($0)") }
            ) == .failure(.invalidDocument)
        )
    }

    @Test func unknownFieldsFailClosed() throws {
        // Unknown top-level field.
        let top = try JSONSerialization.data(
            withJSONObject: [
                "version": 1, "definitions": [Self.validDefinition()], "future": true,
            ]
        )
        #expect(Self.result(for: top) == .failure(.invalidDocument))
        // Unknown definition field.
        #expect(
            Self.result(mutating: { $0["mystery"] = "field" }) == .failure(.invalidDocument)
        )
        // Unknown executable field.
        #expect(
            Self.result(mutating: {
                $0["executable"] = [
                    "expectedContentDigestSHA256": Self.digest, "trustMe": true,
                ]
            }) == .failure(.invalidDocument)
        )
        // No secret values are accepted in the file under any name.
        #expect(
            Self.result(mutating: { $0["secretValue"] = "hunter2" }) == .failure(.invalidDocument)
        )
        #expect(
            Self.result(mutating: { $0["apiKey"] = "hunter2" }) == .failure(.invalidDocument)
        )
    }

    @Test func duplicateIDsFailClosed() throws {
        #expect(
            Self.result(definitions: [Self.validDefinition(), Self.validDefinition()])
                == .failure(.invalidDocument)
        )
        let distinct = Self.result(
            definitions: [Self.validDefinition(), Self.validDefinition(id: "codex")]
        )
        #expect(try distinct?.get().resolved.count == 2)
    }

    @Test func unsupportedVersionsFailClosed() throws {
        for version in [0, 2, 99] {
            let data = try JSONSerialization.data(
                withJSONObject: ["version": version, "definitions": [Self.validDefinition()]]
            )
            #expect(Self.result(for: data) == .failure(.unsupportedVersion))
        }
    }

    @Test func customExecutableSnapshotGainsNoNamedGrants() throws {
        let snapshot = try #require(AdHocAgentSnapshot.make(expectedContentDigestSHA256: Self.digest))
        // Distinct marker: the reserved id operator config cannot define.
        #expect(snapshot.definition.id.rawValue == AgentDefinitionStore.reservedSnapshotID)
        #expect(snapshot.definition.credentialBindings == [])
        #expect(snapshot.definition.authorityCeiling == .none)
        #expect(snapshot.definition.agentTag == nil)
        #expect(snapshot.definition.hookHost == nil)
        #expect(snapshot.definition.resourceProfile.projects == [])
        #expect(snapshot.revision == AgentDefinitionRevision.resolve(snapshot.definition))
        // Malformed digests fail closed: no snapshot, no identity.
        #expect(AdHocAgentSnapshot.make(expectedContentDigestSHA256: "abc") == nil)
        #expect(AdHocAgentSnapshot.make(expectedContentDigestSHA256: "") == nil)
        // The snapshot shares no identity with a named definition loaded
        // from the same trusted config.
        let set = try AgentDefinitionStore.decode(
            Self.documentData(definitions: [Self.validDefinition()]),
            resourcePolicy: Self.resources()
        ).get()
        let named = try #require(
            set.definition(id: AgentDefinitionID(rawValue: "claude"))
        )
        #expect(snapshot.definition.id != named.id)
        #expect(named.credentialBindings.isEmpty == false)
    }

    @Test func trustedRootIgnoresRequestProvidedHome() throws {
        // The default file derives from the real OS account root only.
        // There is no overload accepting a HOME string, so request input
        // cannot redirect it; this test pins the derivation.
        if let home = HomeDirectory.process() {
            #expect(
                AgentDefinitionStore.defaultConfigFile()
                    == RVPolicyPaths.agentDefinitionsFile(
                        inConfigDir: RVPolicyPaths.configDirectory(home: home)
                    )
            )
            #expect(
                AgentDefinitionStore.defaultConfigFile()?.path.hasPrefix(home.rawValue) == true
            )
        } else {
            #expect(AgentDefinitionStore.defaultConfigFile() == nil)
            #expect(
                AgentDefinitionStore.loadFromOperatorConfig(resourcePolicy: Self.resources())
                    == .failure(.unsafeLocation)
            )
        }
        // A fabricated HOME builds a different path that the store never
        // consults on its own.
        let evil = try #require(HomeDirectory(validating: "/tmp/rv-evil-home"))
        #expect(
            RVPolicyPaths.agentDefinitionsFile(
                inConfigDir: RVPolicyPaths.configDirectory(home: evil)
            ).path.hasPrefix("/tmp/rv-evil-home")
        )
        if HomeDirectory.process() != nil {
            #expect(
                AgentDefinitionStore.defaultConfigFile()
                    != RVPolicyPaths.agentDefinitionsFile(
                        inConfigDir: RVPolicyPaths.configDirectory(home: evil)
                    )
            )
        }
    }

    @Test func uninstallArtifactsIncludeAgentDefinitions() {
        let root = URL(fileURLWithPath: "/tmp/rv-config", isDirectory: true)
        let artifacts = RVPolicyPaths.uninstallArtifacts(inConfigDir: root)
        #expect(artifacts.contains(RVPolicyPaths.agentDefinitionsFile(inConfigDir: root)))
    }
}

extension AgentDefinitionStoreTests {
    static let digest = String(repeating: "ab", count: 32)
    static let otherDigest = String(repeating: "cd", count: 32)

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

    static func documentData(definitions: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": 1, "definitions": definitions])
    }

    static func result(
        for data: Data
    ) -> Result<AgentDefinitionSet, AgentDefinitionStoreError> {
        AgentDefinitionStore.decode(data, resourcePolicy: resources())
    }

    static func result(
        definitions: [[String: Any]]
    ) -> Result<AgentDefinitionSet, AgentDefinitionStoreError>? {
        guard let data = try? documentData(definitions: definitions) else { return nil }
        return result(for: data)
    }

    static func result(
        mutating mutate: (inout [String: Any]) -> Void
    ) -> Result<AgentDefinitionSet, AgentDefinitionStoreError>? {
        var definition = validDefinition()
        mutate(&definition)
        return result(definitions: [definition])
    }
}
