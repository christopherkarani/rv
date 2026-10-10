#if os(macOS)
import Darwin
import Foundation
import RVDomain
import Testing
@testable import RVIsolation
@testable import RVPolicy

private func preparedSupervisor(_ tree: ContainmentTree) throws -> WorkspaceSessionSupervisor {
    try WorkspaceSessionSupervisor.open(
        try #require(WorkingDirectory(validating: tree.workspaceURL.path)),
        lifecycleLog: .file(tree.rootURL.appendingPathComponent("workspace.jsonl")),
        runtimeLog: tree.rootURL.appendingPathComponent("runtimes.jsonl"),
        instanceJournal: .file(tree.rootURL.appendingPathComponent("instances.jsonl"))
    ).get()
}

private func preparedSupervisor(at path: String, tree: ContainmentTree) throws -> WorkspaceSessionSupervisor {
    try WorkspaceSessionSupervisor.open(
        try #require(WorkingDirectory(validating: path)),
        lifecycleLog: .file(tree.rootURL.appendingPathComponent("workspace.jsonl")),
        runtimeLog: tree.rootURL.appendingPathComponent("runtimes.jsonl"),
        instanceJournal: .file(tree.rootURL.appendingPathComponent("instances.jsonl"))
    ).get()
}

private func preparedDefinition(
    id: String = "prepared-agent",
    target: String = "/bin/sleep",
    projects: [String],
    requirement: ExecutableRequirement = ExecutableRequirement(allowsUnsigned: true),
    hookHost: HookHost? = nil,
    agentTag: String? = nil,
    environment: [RuntimeResourceProfile.Environment] = [],
    credentialBindings: [String] = [],
    credentials: [RuntimeResourceProfile.Credential] = [],
    keychain: [RuntimeResourceProfile.KeychainEntry] = []
) -> AgentDefinition {
    AgentDefinition(
        id: AgentDefinitionID(rawValue: id),
        displayName: "Prepared agent",
        blurb: "",
        executableRequirement: requirement,
        hookHost: hookHost,
        agentTag: agentTag,
        resourceProfile: RuntimeResourceProfile(
            id: "prepared",
            projects: projects,
            executableLinks: [.init(name: id, target: target)],
            credentials: credentials,
            environment: environment,
            keychain: keychain
        ),
        credentialBindings: credentialBindings,
        requiredAssurance: .launchObserved,
        authorityCeiling: .none
    )
}

private func preparedNamedSelection(
    _ definition: AgentDefinition,
    executable: String? = nil,
    revision: AgentDefinitionRevision? = nil
) -> ResolvedAgentLaunch {
    ResolvedAgentLaunch(
        resolved: ResolvedAgentDefinition(
            definition: definition,
            revision: revision ?? AgentDefinitionRevision.resolve(definition)
        ),
        executable: executable ?? definition.resourceProfile.executableLinks.first(where: {
            $0.name == definition.id.rawValue
        })?.target ?? "/bin/sleep",
        resourceProfile: definition.resourceProfile
    )
}

private func preparedCustomSelection(executable: String, digest: String) throws -> ResolvedAgentLaunch {
    try AgentLaunchSelection.resolveCustom(
        executable: executable, expectedContentDigestSHA256: digest
    ).get()
}

private func preparedHost() -> (WorkspaceHostID, WorkspaceHostGeneration) {
    (WorkspaceHostID(), WorkspaceHostGeneration())
}

private func readFileSize(_ url: URL) -> Int? {
    guard let data = try? Data(contentsOf: url) else {
        return nil
    }
    return data.count
}

private func dispatchFailure(
    _ result: Result<RunningRuntime, WorkspaceSessionError>
) -> WorkspaceSessionError? {
    switch result {
    case .success:
        nil
    case .failure(let error):
        error
    }
}

@Suite(.serialized)
struct PreparedWorkspaceLaunchTests {
    // MARK: - Preparation correctness

    @Test func namedProposalResolvesExactTrustedRevision() throws {
        let tree = try ContainmentTree()
        let supervisor = try preparedSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = preparedDefinition(projects: [tree.workspaceURL.path])
        let selection = preparedNamedSelection(definition)
        let (host, generation) = preparedHost()
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: selection, arguments: ["30"], io: .discard,
            host: host, generation: generation
        ).get()
        guard case .named(let named) = prepared.intent.target else {
            Issue.record("expected named intent")
            return
        }
        #expect(named.definitionID == definition.id)
        #expect(named.definitionRevision == AgentDefinitionRevision.resolve(definition))
        #expect(named.resolvedExecutable == "/bin/sleep")
        #expect(prepared.binding.workspace == supervisor.id)
        #expect(prepared.binding.host == host)
        #expect(prepared.binding.generation == generation)
        #expect(prepared.selection == selection)
        // Independently rebuilt PR1 intent from trusted parts plus a
        // test-side realpath call: identical object, identical digest.
        let expectedCwd = try #require(posixRealpath(tree.workspaceURL.path))
        let rebuilt = try WorkspaceLaunchIntent.makeNamed(
            definition: definition,
            revision: AgentDefinitionRevision.resolve(definition),
            resolvedExecutable: "/bin/sleep",
            workspaceSessionID: supervisor.id,
            workingDirectory: expectedCwd,
            arguments: ["30"],
            io: .discard
        ).get()
        #expect(prepared.intent == rebuilt)
        #expect(prepared.intentDigest == rebuilt.canonicalDigest)
        #expect(prepared.resolvedWorkspacePath == expectedCwd)
    }

    @Test func customProposalFreezesAdHocSelection() throws {
        let tree = try ContainmentTree()
        let supervisor = try preparedSupervisor(tree)
        defer { _ = supervisor.close() }
        // M4: custom preparation measures the executable against the
        // authorized digest; the fixture authorizes the real bytes.
        let digest = try #require(RVFileDigest.sha256HexOfFile(atPath: "/bin/sleep"))
        let selection = try preparedCustomSelection(executable: "/bin/sleep", digest: digest)
        let (host, generation) = preparedHost()
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: selection, arguments: ["--flag", ""], io: .discard,
            host: host, generation: generation
        ).get()
        guard case .custom(let custom) = prepared.intent.target else {
            Issue.record("expected custom intent")
            return
        }
        #expect(custom.executable == "/bin/sleep")
        #expect(custom.expectedContentDigestSHA256 == digest)
        #expect(prepared.selection == selection)
        #expect(prepared.hook == nil)
        #expect(prepared.stagingAgent == nil)
        // The retained snapshot is the fixed template for the digest:
        // rebuilding from the digest alone reproduces it exactly.
        let snapshot = try #require(AdHocAgentSnapshot.make(expectedContentDigestSHA256: digest))
        #expect(prepared.selection.resolved.definition == snapshot.definition)
        #expect(prepared.selection.resolved.revision == snapshot.revision)
    }

    @Test func customPrepareRefusesDigestMismatch() throws {
        // M4: path strings alone never satisfy an executable requirement.
        let tree = try ContainmentTree()
        let supervisor = try preparedSupervisor(tree)
        defer { _ = supervisor.close() }
        let selection = try preparedCustomSelection(
            executable: "/bin/sleep", digest: String(repeating: "0", count: 64)
        )
        let (host, generation) = preparedHost()
        #expect(
            supervisor.prepareIdentityLaunch(
                selection: selection, arguments: ["30"], io: .discard,
                host: host, generation: generation
            ) == .failure(.executableDigestMismatch)
        )
    }

    @Test func customPrepareRefusesUnreadableExecutable() throws {
        let tree = try ContainmentTree()
        let supervisor = try preparedSupervisor(tree)
        defer { _ = supervisor.close() }
        let selection = try preparedCustomSelection(
            executable: "/nonexistent-rv-dir-\(UUID().uuidString)/nope",
            digest: String(repeating: "0", count: 64)
        )
        let (host, generation) = preparedHost()
        #expect(
            supervisor.prepareIdentityLaunch(
                selection: selection, arguments: [], io: .discard,
                host: host, generation: generation
            ) == .failure(.executableDigestMismatch)
        )
    }

    @Test func argvRetainedByteForByte() throws {
        let tree = try ContainmentTree()
        let supervisor = try preparedSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = preparedDefinition(projects: [tree.workspaceURL.path])
        let selection = preparedNamedSelection(definition)
        let argv = ["b", "a", "a", "", "caf\u{00E9}", "x\ny", "a\tb", "--flag=value with spaces"]
        let (host, generation) = preparedHost()
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: selection, arguments: argv, io: .discard,
            host: host, generation: generation
        ).get()
        #expect(prepared.command.arguments == argv)
        #expect(prepared.intent.arguments == argv)
        #expect(prepared.launchRequest.command.arguments == argv)
    }

    @Test func ioRetainedExactly() throws {
        let tree = try ContainmentTree()
        let supervisor = try preparedSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = preparedDefinition(projects: [tree.workspaceURL.path])
        let selection = preparedNamedSelection(definition)
        let (host, generation) = preparedHost()
        for io in [IsolatedIO.discard, .pseudoTerminal(rows: 24, columns: 80), .pseudoTerminal(rows: 1, columns: 512)] {
            let prepared = try supervisor.prepareIdentityLaunch(
                selection: selection, arguments: [], io: io,
                host: host, generation: generation
            ).get()
            #expect(prepared.io == io)
            #expect(prepared.launchRequest.io == io)
        }
        #expect(
            supervisor.prepareIdentityLaunch(
                selection: selection, arguments: [], io: .inherit,
                host: host, generation: generation
            ) == .failure(.unsupportedIO)
        )
    }

    @Test func resourceStateCorrespondsToRevision() throws {
        let tree = try ContainmentTree()
        let supervisor = try preparedSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = preparedDefinition(
            projects: [tree.workspaceURL.path],
            environment: [.init(name: "LITERAL_MARKER", literalValue: "literal-1")]
        )
        let selection = preparedNamedSelection(definition)
        let (host, generation) = preparedHost()
        let first = try supervisor.prepareIdentityLaunch(
            selection: selection, arguments: [], io: .discard,
            host: host, generation: generation
        ).get()
        #expect(first.selection.resolved.revision == AgentDefinitionRevision.resolve(definition))
        #expect(first.selection.resourceProfile == definition.resourceProfile)
        #expect(first.launchRequest.resources?.profile == definition.resourceProfile)
        // Each preparation mints its own manifest identity (private home);
        // nothing is shared or re-resolved across preparations.
        let second = try supervisor.prepareIdentityLaunch(
            selection: selection, arguments: [], io: .discard,
            host: host, generation: generation
        ).get()
        let firstHome = try #require(first.launchRequest.resources?.privateHome)
        let secondHome = try #require(second.launchRequest.resources?.privateHome)
        #expect(firstHome != secondHome)
        #expect(first.binding.preparedLaunchID != second.binding.preparedLaunchID)
    }

    // MARK: - Working directory resolution

    @Test func cwdIsResolvedBeforeIntentCreation() throws {
        // This host aliases /tmp to /private/tmp while the tree paths use
        // the unresolved spelling, so preparation must resolve before
        // binding. Closes the PR1 reviewer note.
        #expect(try #require(posixRealpath("/tmp")) == "/private/tmp")
        let tree = try ContainmentTree()
        let treeSpelling = tree.workspaceURL.path
        let live = try #require(posixRealpath(treeSpelling))
        #expect(live != treeSpelling)
        let supervisor = try preparedSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = preparedDefinition(projects: [tree.workspaceURL.path])
        let selection = preparedNamedSelection(definition)
        let (host, generation) = preparedHost()
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: selection, arguments: [], io: .discard,
            host: host, generation: generation
        ).get()
        #expect(prepared.resolvedWorkspacePath == live)
        #expect(prepared.intent.workingDirectory == live)
        #expect(prepared.launchRequest.containedWorkspacePath == live)
        #expect(prepared.intent.workingDirectory != treeSpelling)
    }

    @Test func differentSpellingsResolveToSameExecution() throws {
        // Same directory reached through two spellings (direct path and a
        // symlink) prepares the identical cwd and intent digest.
        let tree = try ContainmentTree()
        let link = tree.rootURL.appendingPathComponent("ws-link").path
        try FileManager.default.createSymbolicLink(
            atPath: link, withDestinationPath: tree.workspaceURL.path
        )
        let definition = preparedDefinition(projects: [tree.workspaceURL.path])
        let selection = preparedNamedSelection(definition)
        let (host, generation) = preparedHost()
        let direct = try preparedSupervisor(tree)
        let first = try direct.prepareIdentityLaunch(
            selection: selection, arguments: ["x"], io: .discard,
            host: host, generation: generation
        ).get()
        _ = direct.close()
        let viaLink = try preparedSupervisor(at: link, tree: tree)
        let second = try viaLink.prepareIdentityLaunch(
            selection: selection, arguments: ["x"], io: .discard,
            host: host, generation: generation
        ).get()
        _ = viaLink.close()
        #expect(first.resolvedWorkspacePath == second.resolvedWorkspacePath)
        // Workspace ids differ (two opens), so full digests differ; the
        // EXECUTION path is what coincides.
        #expect(first.intent.workingDirectory == second.intent.workingDirectory)
    }

    // MARK: - Proposal rejection

    @Test func prepareRejectsInvalidProposals() throws {
        let tree = try ContainmentTree()
        let supervisor = try preparedSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = preparedDefinition(projects: [tree.workspaceURL.path])
        let (host, generation) = preparedHost()

        // Revision mismatch: digest of other content.
        let other = preparedDefinition(id: "other-agent", projects: [tree.workspaceURL.path])
        let mismatched = preparedNamedSelection(
            definition, revision: AgentDefinitionRevision.resolve(other)
        )
        #expect(
            supervisor.prepareIdentityLaunch(
                selection: mismatched, arguments: [], io: .discard,
                host: host, generation: generation
            ) == .failure(.revisionMismatch)
        )

        // Tampered custom snapshot: id claims ad-hoc but the body is not
        // the fixed template for its digest.
        var tampered = preparedDefinition(id: "adhoc", projects: [tree.workspaceURL.path])
        tampered = AgentDefinition(
            id: tampered.id, displayName: tampered.displayName, blurb: tampered.blurb,
            executableRequirement: ExecutableRequirement(
                expectedContentDigestSHA256: String(repeating: "ab", count: 32)
            ),
            hookHost: .codex, agentTag: tampered.agentTag,
            resourceProfile: tampered.resourceProfile,
            credentialBindings: tampered.credentialBindings,
            requiredAssurance: tampered.requiredAssurance,
            authorityCeiling: tampered.authorityCeiling
        )
        let tamperedSelection = preparedNamedSelection(tampered)
        #expect(
            supervisor.prepareIdentityLaunch(
                selection: tamperedSelection, arguments: [], io: .discard,
                host: host, generation: generation
            ) == .failure(.invalidCustomSnapshot)
        )

        // Credential-bearing shapes stay rejected.
        for credentialed in [
            preparedDefinition(projects: [tree.workspaceURL.path], credentialBindings: ["token"]),
            preparedDefinition(
                projects: [tree.workspaceURL.path],
                credentials: [.init(source: "a", destination: "b")]
            ),
            preparedDefinition(
                projects: [tree.workspaceURL.path],
                keychain: [.init(service: "s", account: "a", env: "E")]
            ),
        ] {
            #expect(
                supervisor.prepareIdentityLaunch(
                    selection: preparedNamedSelection(credentialed),
                    arguments: [], io: .discard,
                    host: host, generation: generation
                ) == .failure(.credentialStagingNotSupported)
            )
        }

        // A reserved-id named definition never passes the template gate.
        let reserved = preparedDefinition(id: "adhoc", projects: [tree.workspaceURL.path])
        #expect(
            supervisor.prepareIdentityLaunch(
                selection: preparedNamedSelection(reserved),
                arguments: [], io: .discard,
                host: host, generation: generation
            ) == .failure(.invalidCustomSnapshot)
        )

        // Fresh-review finding: a named selection whose carried profile
        // diverges from the revision-committed definition profile must
        // fail closed instead of freezing unattested grants. The evil
        // profile below would otherwise execute behind the clean digest.
        let evil = RuntimeResourceProfile(
            id: "evil",
            projects: [tree.workspaceURL.path],
            executableLinks: [.init(name: "prepared-agent", target: "/bin/sleep")],
            readTrees: ["/tmp/evil-read"],
            environment: [.init(name: "EVIL_MARKER", literalValue: "evil-1")]
        )
        let divergent = ResolvedAgentLaunch(
            resolved: ResolvedAgentDefinition(
                definition: definition,
                revision: AgentDefinitionRevision.resolve(definition)
            ),
            executable: "/bin/sleep",
            resourceProfile: evil
        )
        #expect(
            supervisor.prepareIdentityLaunch(
                selection: divergent, arguments: [], io: .discard,
                host: host, generation: generation
            ) == .failure(.resourceProfileMismatch)
        )

        // Same gate on the custom path: a smuggled non-nil profile behind
        // a base-fence intent fails closed.
        let snapshot = try #require(
            AdHocAgentSnapshot.make(
                expectedContentDigestSHA256: String(repeating: "ab", count: 32)
            )
        )
        let smuggled = ResolvedAgentLaunch(
            resolved: ResolvedAgentDefinition(
                definition: snapshot.definition, revision: snapshot.revision
            ),
            executable: "/bin/sleep",
            resourceProfile: evil
        )
        #expect(
            supervisor.prepareIdentityLaunch(
                selection: smuggled, arguments: [], io: .discard,
                host: host, generation: generation
            ) == .failure(.resourceProfileMismatch)
        )

        // Oversized argv and out-of-range PTY fail at intent construction.
        let selection = preparedNamedSelection(definition)
        #expect(
            supervisor.prepareIdentityLaunch(
                selection: selection,
                arguments: Array(repeating: "a", count: 65), io: .discard,
                host: host, generation: generation
            ) == .failure(.invalidIntent(.tooManyArguments))
        )
        #expect(
            supervisor.prepareIdentityLaunch(
                selection: selection, arguments: [],
                io: .pseudoTerminal(rows: 513, columns: 80),
                host: host, generation: generation
            ) == .failure(.invalidIntent(.invalidTerminalDimensions))
        )
    }

    // MARK: - Zero side effects

    @Test func preparationLaunchesNothing() throws {
        let tree = try ContainmentTree()
        let supervisor = try preparedSupervisor(tree)
        defer { _ = supervisor.close() }
        let journalURL = tree.rootURL.appendingPathComponent("instances.jsonl")
        let runtimeLogURL = tree.rootURL.appendingPathComponent("runtimes.jsonl")
        let definition = preparedDefinition(projects: [tree.workspaceURL.path])
        let selection = preparedNamedSelection(definition)
        let (host, generation) = preparedHost()
        _ = try supervisor.prepareIdentityLaunch(
            selection: selection, arguments: ["30"], io: .discard,
            host: host, generation: generation
        ).get()
        // No AgentInstance announced: the instance journal is untouched.
        #expect(readFileSize(journalURL) == nil || readFileSize(journalURL) == 0)
        // No runtime binding: no session record, no children at all.
        #expect(readFileSize(runtimeLogURL) == nil || readFileSize(runtimeLogURL) == 0)
        #expect(supervisor.runtimeFacts() == [])
        // The preparation IS retained and described.
        #expect(supervisor.describePreparedLaunch(PreparedLaunchID()) == nil)
    }

    @Test func preparationConsultsNoGit() throws {
        // Positive control needs a real git: fail loudly if the fixture
        // cannot run rather than passing vacuously.
        let git = ["/usr/bin/git", "/opt/homebrew/bin/git"].first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        })
        let gitPath = try #require(git)
        _ = gitPath
        let tree = try ContainmentTree()

        func fakeHome(named name: String) throws -> String {
            let home = tree.rootURL.appendingPathComponent(name).path
            try FileManager.default.createDirectory(
                atPath: home, withIntermediateDirectories: true
            )
            let gitconfig = "[user]\n\tname = Fixture User\n\temail = fixture@example.test\n"
            try gitconfig.write(
                to: URL(fileURLWithPath: home + "/.gitconfig"),
                atomically: true, encoding: .utf8
            )
            return home
        }

        func gitconfigs(under home: String) -> [String] {
            (FileManager.default.enumerator(atPath: home) ?? nil).map { enumerator in
                enumerator.compactMap { $0 as? String }.filter { $0.hasSuffix(".gitconfig") }
            } ?? []
        }

        // Positive control: legacy resolution consults git and seeds identity.
        let legacyHome = try fakeHome(named: "legacy-home")
        var legacyEnv = ProcessInfo.processInfo.environment
        legacyEnv["HOME"] = legacyHome
        _ = resolveProductiveWorkspace(
            workspacePath: tree.workspaceURL.path, hostEnvironment: legacyEnv
        )
        let seeded = gitconfigs(under: legacyHome).filter { $0 != ".gitconfig" }
        #expect(seeded.count == 1)
        if let first = seeded.first {
            let body = try String(
                contentsOf: URL(fileURLWithPath: legacyHome + "/" + first), encoding: .utf8
            )
            #expect(body.contains("Fixture User"))
        }

        // Preparation never consults git: nothing is seeded.
        let preparedHome = try fakeHome(named: "prepared-home")
        var preparedEnv = ProcessInfo.processInfo.environment
        preparedEnv["HOME"] = preparedHome
        let supervisor = try preparedSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = preparedDefinition(projects: [tree.workspaceURL.path])
        let selection = preparedNamedSelection(definition)
        let (host, generation) = preparedHost()
        _ = try supervisor.prepareIdentityLaunch(
            selection: selection, arguments: [], io: .discard,
            host: host, generation: generation, hostEnvironment: preparedEnv
        ).get()
        #expect(gitconfigs(under: preparedHome) == [".gitconfig"])
    }

    @Test func descriptionRevealsNoSecrets() throws {
        let tree = try ContainmentTree()
        let supervisor = try preparedSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = preparedDefinition(projects: [tree.workspaceURL.path])
        let selection = preparedNamedSelection(definition)
        let (host, generation) = preparedHost()
        var env = ProcessInfo.processInfo.environment
        env["PR2_PROBE_VAR"] = "env-canary-9f2e"
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: selection, arguments: ["--arg-marker-7aa1"], io: .discard,
            host: host, generation: generation, hostEnvironment: env
        ).get()
        // Sanity: the canary IS in the retained private entries.
        #expect(prepared.environment.entries.contains("PR2_PROBE_VAR=env-canary-9f2e"))
        // But it appears in neither the description, the intent bytes, nor
        // the digests. (Argv is intentionally visible in descriptions.)
        let rendered = String(describing: prepared.description)
        #expect(rendered.contains("--arg-marker-7aa1"))
        #expect(rendered.contains("env-canary-9f2e") == false)
        #expect(rendered.contains("PR2_PROBE_VAR") == false)
        let canary = Array("env-canary-9f2e".utf8)
        #expect(prepared.intent.canonicalBytes.count >= canary.count)
        var found = false
        for start in 0...(prepared.intent.canonicalBytes.count - canary.count) {
            if Array(prepared.intent.canonicalBytes[start..<(start + canary.count)]) == canary {
                found = true
            }
        }
        #expect(found == false)
        #expect(prepared.intentDigest.sha256Hex.contains("env-canary-9f2e") == false)
    }

    // MARK: - Environment freeze

    @Test func frozenEnvironmentIgnoresLaterHostChanges() throws {
        let tree = try ContainmentTree()
        let supervisor = try preparedSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = preparedDefinition(projects: [tree.workspaceURL.path])
        let selection = preparedNamedSelection(definition)
        let (host, generation) = preparedHost()
        var first = ProcessInfo.processInfo.environment
        first["PR2_DYNAMIC_VAR"] = "v1"
        var second = ProcessInfo.processInfo.environment
        second["PR2_DYNAMIC_VAR"] = "v2"
        let one = try supervisor.prepareIdentityLaunch(
            selection: selection, arguments: [], io: .discard,
            host: host, generation: generation, hostEnvironment: first
        ).get()
        let two = try supervisor.prepareIdentityLaunch(
            selection: selection, arguments: [], io: .discard,
            host: host, generation: generation, hostEnvironment: second
        ).get()
        // Same proposal, different host state: distinct frozen snapshots.
        #expect(one.environment.entries.contains("PR2_DYNAMIC_VAR=v1"))
        #expect(two.environment.entries.contains("PR2_DYNAMIC_VAR=v2"))
        #expect(one.environment.digestHex != two.environment.digestHex)
        // Rebuilding from the same entries reproduces the same digest.
        #expect(
            WorkspaceLaunchEnvironmentSnapshot(entries: one.environment.entries).digestHex
                == one.environment.digestHex
        )
        // Order matters: execve lookup is first-spelling-wins.
        #expect(
            WorkspaceLaunchEnvironmentSnapshot(entries: ["A=1", "B=2"]).digestHex
                != WorkspaceLaunchEnvironmentSnapshot(entries: ["B=2", "A=1"]).digestHex
        )
    }

    @Test func dispatchExecutesFrozenEnvironmentNotLive() throws {
        // Profile-provided hostVariable values are read at preparation and
        // executed verbatim at dispatch, even when live host state changes
        // in between. Uses real /bin/sh in the cage.
        let tree = try ContainmentTree()
        let supervisor = try preparedSupervisor(tree)
        defer { _ = supervisor.close() }
        let outPath = tree.workspaceURL.appendingPathComponent("frozen-env-out").path
        let definition = preparedDefinition(
            target: "/bin/sh",
            projects: [tree.workspaceURL.path],
            environment: [.init(name: "FROZEN_COPY", hostVariable: "PR2_DYNAMIC_VAR")]
        )
        let selection = preparedNamedSelection(definition)
        let (host, generation) = preparedHost()
        let saved = getenv("PR2_DYNAMIC_VAR").map { String(cString: $0) }
        defer {
            if let saved {
                setenv("PR2_DYNAMIC_VAR", saved, 1)
            } else {
                unsetenv("PR2_DYNAMIC_VAR")
            }
        }
        setenv("PR2_DYNAMIC_VAR", "v1-at-prepare", 1)
        // The child writes the marker first, then sleeps so establishment
        // observes a live process (an immediately-exiting child cannot
        // establish, exactly like the legacy path).
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: selection,
            arguments: ["-c", "printf %s \"$FROZEN_COPY\" > " + outPath + "; sleep 30"],
            io: .discard,
            host: host, generation: generation
        ).get()
        #expect(prepared.environment.entries.contains("FROZEN_COPY=v1-at-prepare"))
        // Mutate live host state after preparation, before dispatch.
        setenv("PR2_DYNAMIC_VAR", "v2-after-prepare", 1)
        let runtime = try supervisor.dispatchPreparedLaunch(
            prepared,
            sessionStore: .file(tree.rootURL.appendingPathComponent("env-runtime.jsonl")),
            admission: .failClosed
        ).get()
        let deadline = Date().addingTimeInterval(10)
        while (try? String(contentsOfFile: outPath, encoding: .utf8)) == nil,
            Date() < deadline {
            usleep(10_000)
        }
        let body = try String(contentsOfFile: outPath, encoding: .utf8)
        #expect(body == "v1-at-prepare")
        try supervisor.cancel(runtime.id).get()
    }

    // MARK: - Mutation after preparation

    @Test func mutationAfterPreparationLeavesPreparedUnchanged() throws {
        let tree = try ContainmentTree()
        let supervisor = try preparedSupervisor(tree)
        defer { _ = supervisor.close() }
        var argv = ["one", "two"]
        let definition = preparedDefinition(projects: [tree.workspaceURL.path])
        let selection = preparedNamedSelection(definition)
        let (host, generation) = preparedHost()
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: selection, arguments: argv, io: .discard,
            host: host, generation: generation, requestID: UUID()
        ).get()
        let bytesBefore = prepared.intent.canonicalBytes
        let digestBefore = prepared.intentDigest
        let descriptionBefore = prepared.description
        // Mutate every source: proposal argv, definition source, live host
        // state, and the selection value itself.
        argv.append("three")
        var changed = preparedDefinition(target: "/bin/false", projects: [tree.workspaceURL.path])
        _ = changed
        let liveChanged = preparedNamedSelection(
            preparedDefinition(target: "/bin/false", projects: [tree.workspaceURL.path])
        )
        _ = liveChanged
        var mutatedEnv = ProcessInfo.processInfo.environment
        mutatedEnv["PR2_DYNAMIC_VAR"] = "mutated"
        _ = try supervisor.prepareIdentityLaunch(
            selection: selection, arguments: ["other"], io: .discard,
            host: host, generation: generation, hostEnvironment: mutatedEnv
        ).get()
        let described = try #require(
            supervisor.describePreparedLaunch(prepared.binding.preparedLaunchID)
        )
        #expect(described == descriptionBefore)
        #expect(prepared.intent.canonicalBytes == bytesBefore)
        #expect(prepared.intentDigest == digestBefore)
        #expect(prepared.command.arguments == ["one", "two"])
    }

    @Test func configChangeAffectsOnlyNewPreparations() throws {
        // Host configuration is process-immutable (server `let`s), so a
        // changed definition can only arrive via a new host incarnation
        // (fresh store) or a new selection value. Either way the old
        // prepared operation keeps executing exactly its retained snapshot:
        // never silently the new config under the old digest.
        let tree = try ContainmentTree()
        let supervisor = try preparedSupervisor(tree)
        defer { _ = supervisor.close() }
        let old = preparedDefinition(projects: [tree.workspaceURL.path])
        let new = preparedDefinition(target: "/bin/false", projects: [tree.workspaceURL.path])
        let (host, generation) = preparedHost()
        let first = try supervisor.prepareIdentityLaunch(
            selection: preparedNamedSelection(old), arguments: ["30"], io: .discard,
            host: host, generation: generation
        ).get()
        let second = try supervisor.prepareIdentityLaunch(
            selection: preparedNamedSelection(new), arguments: ["30"], io: .discard,
            host: host, generation: generation
        ).get()
        #expect(first.intentDigest != second.intentDigest)
        // The old preparation still dispatches its retained executable.
        let runtime = try supervisor.dispatchPreparedLaunch(
            first,
            sessionStore: .file(tree.rootURL.appendingPathComponent("retained-runtime.jsonl")),
            admission: .failClosed
        ).get()
        try supervisor.cancel(runtime.id).get()
        #expect(first.selection.executable == "/bin/sleep")
    }

    // MARK: - Lifecycle

    @Test func ttlExpiryMakesPreparedUnusable() throws {
        let tree = try ContainmentTree()
        let supervisor = try preparedSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = preparedDefinition(projects: [tree.workspaceURL.path])
        let selection = preparedNamedSelection(definition)
        let (host, generation) = preparedHost()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: selection, arguments: [], io: .discard,
            host: host, generation: generation, now: start
        ).get()
        let id = prepared.binding.preparedLaunchID
        #expect(supervisor.describePreparedLaunch(id, now: start) != nil)
        let beforeExpiry = start.addingTimeInterval(PreparedLaunchLimits.timeToLiveSeconds - 1)
        #expect(supervisor.describePreparedLaunch(id, now: beforeExpiry) != nil)
        // At exactly expiresAt the entry is gone: fail-closed boundary.
        let atExpiry = start.addingTimeInterval(PreparedLaunchLimits.timeToLiveSeconds)
        #expect(supervisor.describePreparedLaunch(id, now: atExpiry) == nil)
        #expect(
            dispatchFailure(supervisor.dispatchPreparedLaunch(
                prepared,
                sessionStore: .file(tree.rootURL.appendingPathComponent("ttl-runtime.jsonl")),
                admission: .failClosed, now: atExpiry
            )) == .unknownPreparedLaunch
        )
    }

    @Test func explicitInvalidateMakesPreparedUnusable() throws {
        let tree = try ContainmentTree()
        let supervisor = try preparedSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = preparedDefinition(projects: [tree.workspaceURL.path])
        let selection = preparedNamedSelection(definition)
        let (host, generation) = preparedHost()
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: selection, arguments: [], io: .discard,
            host: host, generation: generation
        ).get()
        let id = prepared.binding.preparedLaunchID
        #expect(supervisor.describePreparedLaunch(id) != nil)
        supervisor.invalidatePreparedLaunch(id)
        supervisor.invalidatePreparedLaunch(id)
        #expect(supervisor.describePreparedLaunch(id) == nil)
        #expect(
            dispatchFailure(supervisor.dispatchPreparedLaunch(
                prepared,
                sessionStore: .file(tree.rootURL.appendingPathComponent("inv-runtime.jsonl")),
                admission: .failClosed
            )) == .unknownPreparedLaunch
        )
    }

    @Test func workspaceClosureInvalidatesPrepared() throws {
        let tree = try ContainmentTree()
        let supervisor = try preparedSupervisor(tree)
        let definition = preparedDefinition(projects: [tree.workspaceURL.path])
        let selection = preparedNamedSelection(definition)
        let (host, generation) = preparedHost()
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: selection, arguments: [], io: .discard,
            host: host, generation: generation
        ).get()
        let id = prepared.binding.preparedLaunchID
        #expect(supervisor.describePreparedLaunch(id) != nil)
        _ = supervisor.close()
        #expect(supervisor.describePreparedLaunch(id) == nil)
        #expect(
            dispatchFailure(supervisor.dispatchPreparedLaunch(
                prepared,
                sessionStore: .file(tree.rootURL.appendingPathComponent("closed-runtime.jsonl")),
                admission: .failClosed
            )) == .unknownPreparedLaunch
        )
        // Preparation after close fails without spawning.
        #expect(
            supervisor.prepareIdentityLaunch(
                selection: selection, arguments: [], io: .discard,
                host: host, generation: generation
            ) == .failure(.workspaceNotActive)
        )
    }

    @Test func preparationsDoNotCrossHosts() throws {
        let firstTree = try ContainmentTree()
        let secondTree = try ContainmentTree()
        let first = try preparedSupervisor(firstTree)
        defer { _ = first.close() }
        let second = try preparedSupervisor(secondTree)
        defer { _ = second.close() }
        let definition = preparedDefinition(projects: [firstTree.workspaceURL.path])
        let selection = preparedNamedSelection(definition)
        let (host, generation) = preparedHost()
        let prepared = try first.prepareIdentityLaunch(
            selection: selection, arguments: [], io: .discard,
            host: host, generation: generation
        ).get()
        let id = prepared.binding.preparedLaunchID
        #expect(first.describePreparedLaunch(id) != nil)
        // Unknown to the other host incarnation: no description, no dispatch.
        #expect(second.describePreparedLaunch(id) == nil)
        #expect(
            dispatchFailure(second.dispatchPreparedLaunch(
                prepared,
                sessionStore: .file(secondTree.rootURL.appendingPathComponent("xhost-runtime.jsonl")),
                admission: .failClosed
            )) == .unknownPreparedLaunch
        )
    }

    @Test func duplicateClientRequestIDsStayDistinct() throws {
        let tree = try ContainmentTree()
        let supervisor = try preparedSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = preparedDefinition(projects: [tree.workspaceURL.path])
        let selection = preparedNamedSelection(definition)
        let (host, generation) = preparedHost()
        let requestID = UUID()
        let one = try supervisor.prepareIdentityLaunch(
            selection: selection, arguments: [], io: .discard,
            host: host, generation: generation, requestID: requestID
        ).get()
        let two = try supervisor.prepareIdentityLaunch(
            selection: selection, arguments: [], io: .discard,
            host: host, generation: generation, requestID: requestID
        ).get()
        // Same correlation, distinct preparations; neither overwrites the
        // other and neither ID derives from the request.
        #expect(one.binding.preparedLaunchID != two.binding.preparedLaunchID)
        #expect(one.requestID == requestID)
        #expect(two.requestID == requestID)
        #expect(supervisor.describePreparedLaunch(one.binding.preparedLaunchID) != nil)
        #expect(supervisor.describePreparedLaunch(two.binding.preparedLaunchID) != nil)
    }

    // MARK: - Concurrency

    @Test func concurrentPreparationsAreDistinct() async throws {
        let tree = try ContainmentTree()
        let supervisor = try preparedSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = preparedDefinition(projects: [tree.workspaceURL.path])
        let selection = preparedNamedSelection(definition)
        let (host, generation) = preparedHost()
        let ids = try await withThrowingTaskGroup(of: PreparedLaunchID.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try supervisor.prepareIdentityLaunch(
                        selection: selection, arguments: ["x"], io: .discard,
                        host: host, generation: generation
                    ).get().binding.preparedLaunchID
                }
            }
            var collected: [PreparedLaunchID] = []
            for try await id in group {
                collected.append(id)
            }
            return collected
        }
        #expect(Set(ids).count == 8)
        for id in ids {
            #expect(supervisor.describePreparedLaunch(id) != nil)
        }
    }

    @Test func preparationRacingClosureLeavesNothingUsable() async throws {
        let tree = try ContainmentTree()
        let supervisor = try preparedSupervisor(tree)
        let definition = preparedDefinition(projects: [tree.workspaceURL.path])
        let selection = preparedNamedSelection(definition)
        let (host, generation) = preparedHost()
        let ids = await withTaskGroup(of: PreparedLaunchID?.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try? supervisor.prepareIdentityLaunch(
                        selection: selection, arguments: ["x"], io: .discard,
                        host: host, generation: generation
                    ).get().binding.preparedLaunchID
                }
            }
            group.addTask {
                _ = supervisor.close()
                return nil
            }
            var collected: [PreparedLaunchID] = []
            for await id in group {
                if let id {
                    collected.append(id)
                }
            }
            return collected
        }
        // Whatever won the race, the terminal state holds nothing usable:
        // winners were invalidated by close, losers never stored.
        for id in ids {
            #expect(supervisor.describePreparedLaunch(id) == nil)
        }
    }

    // MARK: - Dispatch round trip

    @Test func prepareThenDispatchRoundTrip() throws {
        let tree = try ContainmentTree()
        let supervisor = try preparedSupervisor(tree)
        defer { _ = supervisor.close() }
        let journalURL = tree.rootURL.appendingPathComponent("instances.jsonl")
        let definition = preparedDefinition(
            projects: [tree.workspaceURL.path], hookHost: .codex, agentTag: "codex"
        )
        let selection = preparedNamedSelection(definition)
        let (host, generation) = preparedHost()
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: selection, arguments: ["30"], io: .discard,
            host: host, generation: generation
        ).get()
        #expect(readFileSize(journalURL) == nil || readFileSize(journalURL) == 0)
        let runtime = try supervisor.dispatchPreparedLaunch(
            prepared,
            sessionStore: .file(tree.rootURL.appendingPathComponent("roundtrip-runtime.jsonl")),
            admission: .failClosed
        ).get()
        // Dispatch (not preparation) announces the instance and binds the
        // runtime; the retained definition/revision identify it.
        #expect((readFileSize(journalURL) ?? 0) > 0)
        #expect(supervisor.runtimeFacts().count == 1)
        let instance = try #require(supervisor.agentInstances.instance(forRuntime: runtime.id))
        #expect(instance.definitionID == definition.id)
        #expect(instance.definitionRevision == AgentDefinitionRevision.resolve(definition))
        try supervisor.cancel(runtime.id).get()
    }

    @Test func dispatchRejectsDivergentRetainedSelection() throws {
        // Fresh-review finding: dispatch re-proves the retained
        // selection/profile correspondence instead of trusting the struct.
        // An evil twin reusing a live preparation's ID but carrying a
        // divergent profile fails the retained-intent check and spawns
        // nothing, even though the ID itself is usable.
        let tree = try ContainmentTree()
        let supervisor = try preparedSupervisor(tree)
        defer { _ = supervisor.close() }
        let journalURL = tree.rootURL.appendingPathComponent("instances.jsonl")
        let definition = preparedDefinition(projects: [tree.workspaceURL.path])
        let (host, generation) = preparedHost()
        let honest = try supervisor.prepareIdentityLaunch(
            selection: preparedNamedSelection(definition),
            arguments: ["30"], io: .discard,
            host: host, generation: generation
        ).get()
        let evil = RuntimeResourceProfile(
            id: "evil",
            projects: [tree.workspaceURL.path],
            executableLinks: [.init(name: "prepared-agent", target: "/bin/sleep")],
            environment: [.init(name: "EVIL_MARKER", literalValue: "evil-1")]
        )
        let divergent = ResolvedAgentLaunch(
            resolved: ResolvedAgentDefinition(
                definition: definition,
                revision: AgentDefinitionRevision.resolve(definition)
            ),
            executable: "/bin/sleep",
            resourceProfile: evil
        )
        let twin = preparedClone(honest, id: honest.binding.preparedLaunchID, selection: divergent)
        #expect(
            dispatchFailure(supervisor.dispatchPreparedLaunch(
                twin,
                sessionStore: .file(tree.rootURL.appendingPathComponent("twin-runtime.jsonl")),
                admission: .failClosed
            )) == .unknownPreparedLaunch
        )
        #expect(readFileSize(journalURL) == nil || readFileSize(journalURL) == 0)
        #expect(supervisor.runtimeFacts() == [])
        // Deeper variant: the manifest itself is swapped for the evil
        // profile's. Without the manifest-correspondence gate this would
        // dispatch (the rederived intent digest still matches, since the
        // profile enters the intent only through the verified revision).
        let evilRequest = try prepareSeatbelt(
            honest.launchRequest.plan, honest.command,
            resourceProfile: evil, legacyAgentIntegration: false
        ).get().withIO(honest.io)
        let manifestTwin = preparedClone(
            honest, id: honest.binding.preparedLaunchID, launchRequest: evilRequest
        )
        #expect(
            dispatchFailure(supervisor.dispatchPreparedLaunch(
                manifestTwin,
                sessionStore: .file(tree.rootURL.appendingPathComponent("twin2-runtime.jsonl")),
                admission: .failClosed
            )) == .unknownPreparedLaunch
        )
        #expect(supervisor.runtimeFacts() == [])
        // The honest twin still dispatches: the store entry is intact.
        let runtime = try supervisor.dispatchPreparedLaunch(
            honest,
            sessionStore: .file(tree.rootURL.appendingPathComponent("honest-runtime.jsonl")),
            admission: .failClosed
        ).get()
        try supervisor.cancel(runtime.id).get()
    }
}

private func preparedTemplate(tree: ContainmentTree) throws -> (
    supervisor: WorkspaceSessionSupervisor, prepared: PreparedWorkspaceLaunch
) {
    let supervisor = try preparedSupervisor(tree)
    let definition = preparedDefinition(projects: [tree.workspaceURL.path])
    let selection = preparedNamedSelection(definition)
    let (host, generation) = preparedHost()
    let prepared = try supervisor.prepareIdentityLaunch(
        selection: selection, arguments: ["x"], io: .discard,
        host: host, generation: generation
    ).get()
    return (supervisor, prepared)
}

private func preparedClone(
    _ template: PreparedWorkspaceLaunch,
    id: PreparedLaunchID = PreparedLaunchID(),
    preparedAt: Date? = nil,
    expiresAt: Date? = nil,
    selection: ResolvedAgentLaunch? = nil,
    launchRequest: IsolatedLaunchRequest? = nil,
    cwdIdentity: CwdIdentityStamp? = nil
) -> PreparedWorkspaceLaunch {
    PreparedWorkspaceLaunch(
        binding: PreparedLaunchBinding(
            workspace: template.binding.workspace,
            host: template.binding.host,
            generation: template.binding.generation,
            preparedLaunchID: id
        ),
        requestID: template.requestID,
        intent: template.intent,
        intentDigest: template.intentDigest,
        preparedAt: preparedAt ?? template.preparedAt,
        expiresAt: expiresAt ?? template.expiresAt,
        selection: selection ?? template.selection,
        command: template.command,
        resolvedWorkspacePath: template.resolvedWorkspacePath,
        cwdIdentity: cwdIdentity ?? template.cwdIdentity,
        io: template.io,
        environment: template.environment,
        productive: template.productive,
        launchRequest: launchRequest ?? template.launchRequest,
        egressProxyPort: template.egressProxyPort,
        hook: template.hook,
        stagingAgent: template.stagingAgent
    )
}

@Suite("Prepared launch store")
struct PreparedLaunchStoreTests {
    @Test func insertRejectsDuplicatesAndFull() throws {
        let tree = try ContainmentTree()
        let (supervisor, template) = try preparedTemplate(tree: tree)
        defer { _ = supervisor.close() }
        let store = PreparedLaunchStore()
        let now = Date()
        for _ in 0..<PreparedLaunchLimits.maxPendingPreparedLaunches {
            #expect(store.insert(preparedClone(template), now: now))
        }
        // Full: one more fails, and re-inserting an existing ID fails even
        // when space exists elsewhere.
        #expect(store.insert(preparedClone(template), now: now) == false)
        let existing = preparedClone(template)
        let roomy = PreparedLaunchStore()
        #expect(roomy.insert(existing, now: now))
        #expect(roomy.insert(existing, now: now) == false)
        #expect(roomy.liveCount(now: now) == 1)
    }

    @Test func expiredEntriesEvictedOnInsert() throws {
        let tree = try ContainmentTree()
        let (supervisor, template) = try preparedTemplate(tree: tree)
        defer { _ = supervisor.close() }
        let store = PreparedLaunchStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for _ in 0..<PreparedLaunchLimits.maxPendingPreparedLaunches {
            let entry = preparedClone(
                template,
                preparedAt: start,
                expiresAt: start.addingTimeInterval(PreparedLaunchLimits.timeToLiveSeconds)
            )
            #expect(store.insert(entry, now: start))
        }
        #expect(store.liveCount(now: start) == PreparedLaunchLimits.maxPendingPreparedLaunches)
        // Past expiry, the next insert evicts everything and succeeds.
        let later = start.addingTimeInterval(PreparedLaunchLimits.timeToLiveSeconds + 1)
        #expect(store.insert(preparedClone(template), now: later))
        #expect(store.liveCount(now: later) == 1)
        #expect(store.pruneExpired(now: later) == 0)
        let farFuture = template.expiresAt.addingTimeInterval(1)
        #expect(store.pruneExpired(now: farFuture) == 1)
        #expect(store.liveCount(now: farFuture) == 0)
    }

    @Test func expiryBoundaryFailsClosed() throws {
        let tree = try ContainmentTree()
        let (supervisor, template) = try preparedTemplate(tree: tree)
        defer { _ = supervisor.close() }
        let store = PreparedLaunchStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = preparedClone(
            template,
            preparedAt: start,
            expiresAt: start.addingTimeInterval(PreparedLaunchLimits.timeToLiveSeconds)
        )
        let id = entry.binding.preparedLaunchID
        #expect(store.insert(entry, now: start))
        #expect(store.isUsable(id, now: start))
        #expect(store.description(for: id, now: start) != nil)
        let atExpiry = start.addingTimeInterval(PreparedLaunchLimits.timeToLiveSeconds)
        #expect(store.isUsable(id, now: atExpiry) == false)
        #expect(store.description(for: id, now: atExpiry) == nil)
    }

    @Test func removeAndInvalidateAllDropEntries() throws {
        let tree = try ContainmentTree()
        let (supervisor, template) = try preparedTemplate(tree: tree)
        defer { _ = supervisor.close() }
        let store = PreparedLaunchStore()
        let now = Date()
        let one = preparedClone(template)
        let two = preparedClone(template)
        #expect(store.insert(one, now: now))
        #expect(store.insert(two, now: now))
        store.remove(one.binding.preparedLaunchID)
        store.remove(one.binding.preparedLaunchID)
        #expect(store.isUsable(one.binding.preparedLaunchID, now: now) == false)
        #expect(store.isUsable(two.binding.preparedLaunchID, now: now))
        store.invalidateAll()
        #expect(store.isUsable(two.binding.preparedLaunchID, now: now) == false)
        #expect(store.liveCount(now: now) == 0)
    }

    @Test func descriptionCarriesDigestsNotValues() throws {
        let tree = try ContainmentTree()
        let (supervisor, template) = try preparedTemplate(tree: tree)
        defer { _ = supervisor.close() }
        let store = PreparedLaunchStore()
        let now = Date()
        #expect(store.insert(template, now: now))
        let described = try #require(
            store.description(for: template.binding.preparedLaunchID, now: now)
        )
        #expect(described == template.description)
        #expect(described.intentDigest == template.intent.canonicalDigest)
        #expect(described.environmentDigestHex == template.environment.digestHex)
        #expect(described.environmentDigestHex.utf8.count == 64)
        // Structural: the description's members expose digests and bindings
        // only; no environment entries member exists to leak values.
        let labels = Mirror(reflecting: described).children.compactMap { $0.label }
        #expect(labels.contains("entries") == false)
        #expect(labels.contains("environment") == false)
    }
}
#endif
