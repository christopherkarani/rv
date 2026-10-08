import Foundation
import RVDomain
import Testing
@testable import RVIsolation

@Test func noProfileNeverAdmitsInstalledAgentResources() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try #require(WorkingDirectory(validating: root.path))
    let plan = try compileIsolationPlan(
        IsolationCompileRequest(requested: .contained, workspace: workspace)
    ).get()
    let command = try #require(IsolatedCommand(executable: "/bin/zsh"))
    let prepared = try prepareSeatbelt(plan, command).get()
    let profile = try #require(prepared.seatbeltProfile)
    #expect(prepared.resources == nil)
    #expect(profile.source.contains("rv-agent-bin") == false)
    #expect(profile.source.contains(".codex/auth.json") == false)
    #expect(profile.source.contains(".claude/.credentials.json") == false)
    #expect(profile.source.contains("(allow network-outbound"))
    #expect(profile.source.contains("(remote tcp \"localhost:*\")"))
    #expect(profile.source.contains("(deny default)"))
}

@Test func selectedGenericProfileStagesOnlyItsOwnSyntheticCredential() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-resource-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let first = root.appendingPathComponent("first.auth")
    let second = root.appendingPathComponent("second.auth")
    try Data("synthetic-a".utf8).write(to: first)
    try Data("synthetic-b".utf8).write(to: second)
    for source in [first, second] {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
    }
    let profileA = RuntimeResourceProfile(
        id: "arbitrary-a", projects: [root.path],
        credentials: [.init(source: first.path, destination: ".config/selected.auth")]
    )
    let profileB = RuntimeResourceProfile(
        id: "arbitrary-b", projects: [root.path],
        credentials: [.init(source: second.path, destination: ".config/selected.auth")]
    )
    let manifestA = RuntimeResourceManifest(profileA)
    let manifestB = RuntimeResourceManifest(profileB)
    defer { manifestA.remove(); manifestB.remove() }
    #expect(manifestA.stage().isSuccess)
    #expect(manifestB.stage().isSuccess)
    let stagedA = manifestA.privateHome + "/.config/selected.auth"
    let stagedB = manifestB.privateHome + "/.config/selected.auth"
    #expect(try String(contentsOfFile: stagedA, encoding: .utf8) == "synthetic-a")
    #expect(try String(contentsOfFile: stagedB, encoding: .utf8) == "synthetic-b")
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".config/selected.auth").path) == false)

    let workspace = try #require(WorkingDirectory(validating: root.path))
    let plan = try compileIsolationPlan(
        IsolationCompileRequest(requested: .contained, workspace: workspace)
    ).get()
    let command = try #require(IsolatedCommand(executable: "/bin/zsh"))
    let request = try prepareSeatbelt(plan, command, resourceProfile: profileA).get()
    let seatbelt = try #require(request.seatbeltProfile)
    #expect(seatbelt.source.contains(first.path) == false)
    #expect(seatbelt.source.contains(second.path) == false)
    #expect(seatbelt.source.contains(request.resources?.privateHome ?? "absent"))
    #expect(seatbelt.source.contains(manifestB.privateHome) == false)
}

@Test func stagedCredentialMustBeOwnerFileAndNeverSymlink() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-resource-unsafe-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("source")
    let alias = root.appendingPathComponent("alias")
    try Data("fake".utf8).write(to: source)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
    let profile = RuntimeResourceProfile(
        id: "profile", projects: [root.path],
        credentials: [.init(source: alias.path, destination: "auth")]
    )
    let manifest = RuntimeResourceManifest(profile)
    defer { manifest.remove() }
    #expect(manifest.stage().isFailure(.credential(destination: "auth")))
    #expect(FileManager.default.fileExists(atPath: manifest.privateHome) == false)
}

@Test func agentFilteredCredentialsStageOnlyForMatchingAgent() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-resource-agent-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let shared = root.appendingPathComponent("shared.auth")
    let grokOnly = root.appendingPathComponent("grok.auth")
    try Data("synthetic-shared".utf8).write(to: shared)
    try Data("synthetic-grok".utf8).write(to: grokOnly)
    for source in [shared, grokOnly] {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
    }
    let profile = RuntimeResourceProfile(
        id: "agents", projects: [root.path],
        credentials: [
            .init(source: shared.path, destination: "shared.auth"),
            .init(source: grokOnly.path, destination: "grok.auth", agents: ["grok"]),
        ]
    )
    let agent = RuntimeResourceManifest(profile)
    defer { agent.remove() }
    #expect(agent.stage(forAgent: "grok").isSuccess)
    #expect(try String(contentsOfFile: agent.privateHome + "/shared.auth", encoding: .utf8)
        == "synthetic-shared")
    #expect(try String(contentsOfFile: agent.privateHome + "/grok.auth", encoding: .utf8)
        == "synthetic-grok")

    let other = RuntimeResourceManifest(profile)
    defer { other.remove() }
    #expect(other.stage(forAgent: "codex").isSuccess)
    #expect(FileManager.default.fileExists(atPath: other.privateHome + "/shared.auth"))
    #expect(FileManager.default.fileExists(atPath: other.privateHome + "/grok.auth") == false)

    let shell = RuntimeResourceManifest(profile)
    defer { shell.remove() }
    #expect(shell.stage().isSuccess)
    #expect(FileManager.default.fileExists(atPath: shell.privateHome + "/shared.auth"))
    #expect(FileManager.default.fileExists(atPath: shell.privateHome + "/grok.auth") == false)
}

@Test func deadExecutableLinkNamesItselfInStagingFailure() {
    let profile = RuntimeResourceProfile(
        id: "agents", projects: ["/tmp/project"],
        executableLinks: [.init(name: "grok", target: "/nonexistent/grok-target")]
    )
    let manifest = RuntimeResourceManifest(profile)
    defer { manifest.remove() }
    #expect(manifest.stage().isFailure(.executableLink(name: "grok")))
    #expect(ResourceStagingError.executableLink(name: "grok").detail == "executable link 'grok'")
    #expect(FileManager.default.fileExists(atPath: manifest.privateHome) == false)
}

private func keychainProfile(
    field: String? = "api_key", agents: [String]? = ["muse"]
) -> RuntimeResourceProfile {
    RuntimeResourceProfile(
        id: "agents", projects: ["/tmp/project"],
        keychain: [.init(
            service: "synthetic.service", account: "synthetic-account",
            field: field, env: "SYNTHETIC_KEY", agents: agents
        )]
    )
}

private func keychainReader(returning data: Data?) -> KeychainReader {
    KeychainReader(read: { _, _ in data })
}

@Test func deniedReaderFailsClosed() throws {
    // The identity launch path stages through `.denied`: keychain
    // entries fail closed, so no value can flow to a runtime even
    // if a credential-free gate ever regresses.
    let manifest = RuntimeResourceManifest(keychainProfile(agents: nil))
    #expect(manifest.keychainEnvironment(reader: .denied).isFailure(.keychain(env: "SYNTHETIC_KEY")))
    #expect(manifest.keychainEnvironment(forAgent: "muse", reader: .denied).isFailure(.keychain(env: "SYNTHETIC_KEY")))
}

@Test func keychainEntryInjectsOnlyForMatchingAgent() throws {
    let secret = try #require(#"{"api_key":"synthetic-secret"}"#.data(using: .utf8))
    let manifest = RuntimeResourceManifest(keychainProfile())
    let matched = try manifest.keychainEnvironment(
        forAgent: "muse", reader: keychainReader(returning: secret)
    ).get()
    #expect(matched.count == 1)
    #expect(matched[0].name == "SYNTHETIC_KEY")
    #expect(matched[0].value == "synthetic-secret")
    #expect(try manifest.keychainEnvironment(
        forAgent: "codex", reader: keychainReader(returning: secret)
    ).get().isEmpty)
    #expect(try manifest.keychainEnvironment(
        reader: keychainReader(returning: secret)
    ).get().isEmpty)
    let unfiltered = RuntimeResourceManifest(keychainProfile(agents: nil))
    #expect(try unfiltered.keychainEnvironment(
        reader: keychainReader(returning: secret)
    ).get().count == 1)
}

@Test func keychainRawSecretWithoutFieldDecodesAsText() throws {
    let manifest = RuntimeResourceManifest(keychainProfile(field: nil, agents: nil))
    let plain = try manifest.keychainEnvironment(
        reader: keychainReader(returning: Data("synthetic-raw".utf8))
    ).get()
    #expect(plain.count == 1)
    #expect(plain[0].value == "synthetic-raw")
}

@Test func keychainFailuresNameTheEnvAndStageNothing() {
    let manifest = RuntimeResourceManifest(keychainProfile(agents: nil))
    let missing = manifest.keychainEnvironment(reader: keychainReader(returning: nil))
    #expect(missing.isFailure(.keychain(env: "SYNTHETIC_KEY")))
    let malformed = manifest.keychainEnvironment(
        reader: keychainReader(returning: Data("not-json".utf8))
    )
    #expect(malformed.isFailure(.keychain(env: "SYNTHETIC_KEY")))
    let fieldless = manifest.keychainEnvironment(
        reader: keychainReader(returning: Data(#"{"other":"x"}"#.utf8))
    )
    #expect(fieldless.isFailure(.keychain(env: "SYNTHETIC_KEY")))
    let nonString = manifest.keychainEnvironment(
        reader: keychainReader(returning: Data(#"{"api_key":42}"#.utf8))
    )
    #expect(nonString.isFailure(.keychain(env: "SYNTHETIC_KEY")))
    let nulled = manifest.keychainEnvironment(
        reader: keychainReader(returning: Data(#"{"api_key":"ab\u0000cd"}"#.utf8))
    )
    #expect(nulled.isFailure(.keychain(env: "SYNTHETIC_KEY")))
    let oversized = manifest.keychainEnvironment(
        reader: keychainReader(returning: Data(repeating: 0x61, count: 8_193))
    )
    #expect(oversized.isFailure(.keychain(env: "SYNTHETIC_KEY")))
    let empty = manifest.keychainEnvironment(reader: keychainReader(returning: Data()))
    #expect(empty.isFailure(.keychain(env: "SYNTHETIC_KEY")))
    let raw = RuntimeResourceManifest(keychainProfile(field: nil, agents: nil))
    let binary = raw.keychainEnvironment(
        reader: keychainReader(returning: Data([0xFF, 0xFE]))
    )
    #expect(binary.isFailure(.keychain(env: "SYNTHETIC_KEY")))
    #expect(ResourceStagingError.keychain(env: "SYNTHETIC_KEY").detail == "keychain 'SYNTHETIC_KEY'")
}

@Test func emptyAgentsListNormalizesToNilInInitAndDecode() throws {
    let credential = RuntimeResourceProfile.Credential(source: "a", destination: "b", agents: [])
    #expect(credential.agents == nil)
    let entry = RuntimeResourceProfile.KeychainEntry(
        service: "s", account: "a", env: "E", agents: []
    )
    #expect(entry.agents == nil)
    let decodedCredential = try JSONDecoder().decode(
        RuntimeResourceProfile.Credential.self,
        from: Data(#"{"source":"a","destination":"b","agents":[]}"#.utf8)
    )
    #expect(decodedCredential == credential)
    let decodedEntry = try JSONDecoder().decode(
        RuntimeResourceProfile.KeychainEntry.self,
        from: Data(#"{"service":"s","account":"a","env":"E","agents":[]}"#.utf8)
    )
    #expect(decodedEntry == entry)
}
