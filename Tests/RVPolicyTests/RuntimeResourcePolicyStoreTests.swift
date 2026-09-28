import Foundation
import RVDomain
import Testing
@testable import RVPolicy

@Suite("Runtime resource policy")
struct RuntimeResourcePolicyStoreTests {
    @Test func emptyMachinePolicyGrantsNothing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-resources-missing-\(UUID().uuidString)")
        let policy = try RuntimeResourcePolicyStore.load(from: directory).get()
        #expect(policy == .empty)
        #expect(policy.profile(id: "profile-a", project: "/tmp/project") == nil)
    }

    @Test func explicitProfileIsScopedToProjectAndKeepsGenericResources() throws {
        let profile = RuntimeResourceProfile(
            id: "profile-a",
            projects: ["/tmp/project-a"],
            executableLinks: [.init(name: "tool", target: "/tmp/bin/tool")],
            readFiles: ["/tmp/support/version"],
            readTrees: ["/tmp/support/package"],
            writeTrees: ["/tmp/scratch-a"],
            credentials: [.init(source: "/tmp/home/credential", destination: ".config/tool/auth")],
            environment: [.init(name: "TOOL_KEY", hostVariable: "RV_TEST_KEY")]
        )
        let document = RuntimeResourcePolicy(profiles: [profile])
        let decoded = try RuntimeResourcePolicyStore.decode(JSONEncoder().encode(document)).get()
        #expect(decoded.profile(id: "profile-a", project: "/tmp/project-a") == profile)
        #expect(decoded.profile(id: "profile-a", project: "/tmp/project-b") == nil)
        #expect(decoded.profile(id: "tool", project: "/tmp/project-a") == nil)
    }

    @Test func malformedGrantsAndNewerVersionFailClosed() throws {
        let unsafe = RuntimeResourcePolicy(profiles: [
            RuntimeResourceProfile(
                id: "profile-a", projects: ["/tmp/project"],
                credentials: [.init(source: "/tmp/home/credential", destination: "../escape")]
            ),
        ])
        #expect(RuntimeResourcePolicyStore.decode(try JSONEncoder().encode(unsafe)) == .failure(.invalidDocument))
        let duplicate = RuntimeResourcePolicy(profiles: [
            RuntimeResourceProfile(id: "same", projects: ["/tmp/project"]),
            RuntimeResourceProfile(id: "same", projects: ["/tmp/project"]),
        ])
        #expect(RuntimeResourcePolicyStore.decode(try JSONEncoder().encode(duplicate)) == .failure(.invalidDocument))
        #expect(RuntimeResourcePolicyStore.decode(Data(repeating: 0, count: 65_537)) == .failure(.oversized))
        #expect(RuntimeResourcePolicyStore.decode(
            try JSONEncoder().encode(RuntimeResourcePolicy(version: 2))
        ) == .failure(.unsupportedVersion))
        let rootGrant = RuntimeResourcePolicy(profiles: [
            RuntimeResourceProfile(id: "root", projects: ["/tmp/project"], writeTrees: ["/"]),
        ])
        #expect(RuntimeResourcePolicyStore.decode(try JSONEncoder().encode(rootGrant))
            == .failure(.invalidDocument))
        let reserved = RuntimeResourcePolicy(profiles: [
            RuntimeResourceProfile(id: "reserved", projects: ["/tmp/project"],
                environment: [.init(name: "HOME", literalValue: "/tmp/override")]),
        ])
        #expect(RuntimeResourcePolicyStore.decode(try JSONEncoder().encode(reserved))
            == .failure(.invalidDocument))
        var conflicting = RuntimeResourceProfile.Environment(name: "KEY", hostVariable: "HOST_KEY")
        conflicting.literalValue = "literal"
        let both = RuntimeResourcePolicy(profiles: [
            RuntimeResourceProfile(id: "both", projects: ["/tmp/project"], environment: [conflicting]),
        ])
        #expect(RuntimeResourcePolicyStore.decode(try JSONEncoder().encode(both))
            == .failure(.invalidDocument))
    }

    @Test func contradictoryEnvironmentEntriesFailClosed() throws {
        // Both sources set but only one content-valid: still rejected, so no
        // consumer can silently prefer one source over the other.
        var contradictory = RuntimeResourceProfile.Environment(name: "KEY", hostVariable: "not a name")
        contradictory.literalValue = "literal"
        #expect(contradictory.resolvedSource == nil)
        let document = RuntimeResourcePolicy(profiles: [
            RuntimeResourceProfile(id: "contra", projects: ["/tmp/project"], environment: [contradictory]),
        ])
        #expect(RuntimeResourcePolicyStore.decode(try JSONEncoder().encode(document))
            == .failure(.invalidDocument))
        var empty = RuntimeResourceProfile.Environment(name: "KEY", hostVariable: "HOST_KEY")
        empty.hostVariable = nil
        #expect(empty.resolvedSource == nil)
        #expect(RuntimeResourceProfile.Environment(name: "KEY", hostVariable: "HOST_KEY").resolvedSource
            == .hostVariable("HOST_KEY"))
        #expect(RuntimeResourceProfile.Environment(name: "KEY", literalValue: "v").resolvedSource
            == .literal("v"))
    }

    @Test func onlyOwnerFilesWithoutSymlinksAreLoaded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-resources-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // The store rejects group-writable directories; under umask 002 the
        // default directory mode is 0775, which must not fail this test.
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let file = RVPolicyPaths.runtimeResourcesFile(inConfigDir: root)
        let data = try JSONEncoder().encode(RuntimeResourcePolicy(profiles: [
            RuntimeResourceProfile(id: "profile-a", projects: ["/tmp/project"]),
        ]))
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try RuntimeResourcePolicyStore.load(from: root).get().profiles.count == 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(RuntimeResourcePolicyStore.load(from: root) == .failure(.unsafeLocation))
        try FileManager.default.removeItem(at: file)
        let target = root.appendingPathComponent("target.json")
        try data.write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        #expect(RuntimeResourcePolicyStore.load(from: root) == .failure(.unsafeLocation))
    }

    @Test func legacyDocumentsDecodeWithEmptyAgentsAndNoDefault() throws {
        let legacy = """
            {"version":1,"profiles":[{"id":"profile-a","projects":["/tmp/project"],\
            "executableLinks":[],"readFiles":[],"readTrees":[],"writeTrees":[],\
            "credentials":[],"environment":[]}]}
            """
        let policy = try RuntimeResourcePolicyStore.decode(Data(legacy.utf8)).get()
        #expect(policy.profiles.count == 1)
        #expect(policy.profiles[0].agents == [])
        #expect(policy.defaultProfile == nil)
    }

    @Test func agentMarksRoundTripThroughTheStore() throws {
        let profile = RuntimeResourceProfile(
            id: "profile-a", projects: ["/tmp/project"],
            agents: ["muse", "codex"]
        )
        let decoded = try RuntimeResourcePolicyStore.decode(
            JSONEncoder().encode(RuntimeResourcePolicy(profiles: [profile]))
        ).get()
        #expect(decoded.profiles[0].agents == ["muse", "codex"])
        #expect(RuntimeAgentEntries.known == ["claude", "codex", "opencode", "muse"])
    }

    @Test func invalidAgentMarksFailClosed() throws {
        func result(for agents: [String]) -> Result<RuntimeResourcePolicy, RuntimeResourcePolicyError> {
            let profile = RuntimeResourceProfile(
                id: "profile-a", projects: ["/tmp/project"], agents: agents
            )
            return RuntimeResourcePolicyStore.decode(
                (try? JSONEncoder().encode(RuntimeResourcePolicy(profiles: [profile]))) ?? Data()
            )
        }
        #expect(result(for: ["muse", "muse"]) == .failure(.invalidDocument))
        #expect(result(for: ["not an id"]) == .failure(.invalidDocument))
        #expect(result(for: Array(repeating: "muse", count: 9)) == .failure(.invalidDocument))
    }

    @Test func agentMarksAcceptAnyIdentifier() throws {
        let profile = RuntimeResourceProfile(
            id: "profile-a", projects: ["/tmp/project"],
            agents: ["vim", "grok", "hal-9000"]
        )
        let policy = try RuntimeResourcePolicyStore.decode(
            JSONEncoder().encode(RuntimeResourcePolicy(profiles: [profile]))
        ).get()
        #expect(policy.profiles[0].agents == ["vim", "grok", "hal-9000"])
    }

    @Test func credentialAgentFiltersRoundTripAndFailClosed() throws {
        func result(for agents: [String]?) -> Result<RuntimeResourcePolicy, RuntimeResourcePolicyError> {
            let profile = RuntimeResourceProfile(
                id: "profile-a", projects: ["/tmp/project"],
                credentials: [.init(source: "/tmp/secret", destination: "auth", agents: agents)]
            )
            return RuntimeResourcePolicyStore.decode(
                (try? JSONEncoder().encode(RuntimeResourcePolicy(profiles: [profile]))) ?? Data()
            )
        }
        #expect(try result(for: nil).get().profiles[0].credentials[0].agents == nil)
        #expect(try result(for: ["grok", "codex"]).get().profiles[0].credentials[0].agents
            == ["grok", "codex"])
        #expect(result(for: ["muse", "muse"]) == .failure(.invalidDocument))
        #expect(result(for: ["not an id"]) == .failure(.invalidDocument))
        #expect(result(for: Array(repeating: "muse", count: 9)) == .failure(.invalidDocument))
    }

    @Test func defaultProfileMustNameAProfileInTheSameDocument() throws {
        func result(defaultProfile: String?) -> Result<RuntimeResourcePolicy, RuntimeResourcePolicyError> {
            let document = RuntimeResourcePolicy(
                profiles: [RuntimeResourceProfile(id: "profile-a", projects: ["/tmp/project"])],
                defaultProfile: defaultProfile
            )
            return RuntimeResourcePolicyStore.decode(
                (try? JSONEncoder().encode(document)) ?? Data()
            )
        }
        #expect(try result(defaultProfile: "profile-a").get().defaultProfile == "profile-a")
        #expect(try result(defaultProfile: nil).get().defaultProfile == nil)
        #expect(result(defaultProfile: "missing") == .failure(.invalidDocument))
        #expect(result(defaultProfile: "not an id") == .failure(.invalidDocument))
        let empty = RuntimeResourcePolicy(profiles: [], defaultProfile: "profile-a")
        #expect(RuntimeResourcePolicyStore.decode(
            try JSONEncoder().encode(empty)
        ) == .failure(.invalidDocument))
    }

    @Test func keychainEntriesRoundTripThroughTheStore() throws {
        let profile = RuntimeResourceProfile(
            id: "profile-a", projects: ["/tmp/project"],
            keychain: [
                .init(
                    service: "synthetic.service", account: "synthetic-account",
                    field: "api_key", env: "SYNTHETIC_KEY", agents: ["muse"]
                ),
                .init(
                    service: "synthetic.raw", account: "raw", env: "SYNTHETIC_RAW"
                ),
            ]
        )
        let decoded = try RuntimeResourcePolicyStore.decode(
            JSONEncoder().encode(RuntimeResourcePolicy(profiles: [profile]))
        ).get()
        #expect(decoded.profiles[0].keychain == profile.keychain)
    }

    @Test func keychainEntriesFailClosed() throws {
        func result(
            keychain: [RuntimeResourceProfile.KeychainEntry],
            environment: [RuntimeResourceProfile.Environment] = []
        ) -> Result<RuntimeResourcePolicy, RuntimeResourcePolicyError> {
            let profile = RuntimeResourceProfile(
                id: "profile-a", projects: ["/tmp/project"],
                environment: environment, keychain: keychain
            )
            return RuntimeResourcePolicyStore.decode(
                (try? JSONEncoder().encode(RuntimeResourcePolicy(profiles: [profile]))) ?? Data()
            )
        }
        func entry(
            service: String = "synthetic.service", account: String = "synthetic-account",
            field: String? = "api_key", env: String = "SYNTHETIC_KEY",
            agents: [String]? = ["muse"]
        ) -> RuntimeResourceProfile.KeychainEntry {
            .init(service: service, account: account, field: field, env: env, agents: agents)
        }
        let overlong = String(repeating: "s", count: 257)
        #expect(result(keychain: [entry(service: "")]) == .failure(.invalidDocument))
        #expect(result(keychain: [entry(account: "")]) == .failure(.invalidDocument))
        #expect(result(keychain: [entry(service: overlong)]) == .failure(.invalidDocument))
        #expect(result(keychain: [entry(service: "has\nnewline")]) == .failure(.invalidDocument))
        #expect(result(keychain: [entry(field: "")]) == .failure(.invalidDocument))
        #expect(result(keychain: [entry(env: "not an env")]) == .failure(.invalidDocument))
        #expect(result(keychain: [entry(env: "PATH")]) == .failure(.invalidDocument))
        #expect(result(keychain: [entry(agents: ["muse", "muse"])]) == .failure(.invalidDocument))
        #expect(result(keychain: [entry(agents: ["not an id"])]) == .failure(.invalidDocument))
        #expect(result(
            keychain: [entry(env: "SYNTHETIC_KEY"), entry(env: "SYNTHETIC_KEY")]
        ) == .failure(.invalidDocument))
        #expect(result(
            keychain: [entry(env: "SYNTHETIC_KEY")],
            environment: [.init(name: "SYNTHETIC_KEY", literalValue: "1")]
        ) == .failure(.invalidDocument))
        #expect(result(keychain: Array(repeating: entry(), count: 9)) == .failure(.invalidDocument))
    }

    @Test func legacyDocumentsDecodeWithEmptyKeychain() throws {
        let raw = """
        {"version":1,"profiles":[{"id":"profile-a","projects":["/tmp/project"],\
        "executableLinks":[],"readFiles":[],"readTrees":[],"writeTrees":[],\
        "credentials":[],"environment":[]}]}
        """
        let decoded = try RuntimeResourcePolicyStore.decode(Data(raw.utf8)).get()
        #expect(decoded.profiles[0].keychain == [])
    }

    @Test func emptyAgentFiltersNormalizeToNil() throws {
        let credential = try JSONDecoder().decode(
            RuntimeResourceProfile.Credential.self,
            from: Data(#"{"source":"/tmp/secret","destination":"auth","agents":[]}"#.utf8)
        )
        #expect(credential.agents == nil)
        let entry = try JSONDecoder().decode(
            RuntimeResourceProfile.KeychainEntry.self,
            from: Data(#"{"service":"s","account":"a","env":"E","agents":[]}"#.utf8)
        )
        #expect(entry.agents == nil)
    }
}
