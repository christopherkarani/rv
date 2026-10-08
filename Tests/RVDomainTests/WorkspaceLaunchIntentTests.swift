import Foundation
import Testing
@testable import RVDomain

func launchIntentUUID(_ string: String) throws -> UUID {
    try #require(UUID(uuidString: string))
}

func launchIntentHex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

func launchIntentTestDefinition(
    id: String = "trusted-agent",
    executableTarget: String? = "/bin/cat",
    extraLinks: [RuntimeResourceProfile.ExecutableLink] = [],
    executableRequirement: ExecutableRequirement = ExecutableRequirement(allowsUnsigned: true),
    hookHost: HookHost? = nil,
    agentTag: String? = nil,
    projects: [String] = ["/tmp/identity-project"],
    readTrees: [String] = [],
    credentialBindings: [String] = [],
    credentials: [RuntimeResourceProfile.Credential] = [],
    keychain: [RuntimeResourceProfile.KeychainEntry] = [],
    requiredAssurance: ExecutableAssurance = .launchObserved,
    authorityCeiling: AgentAuthority = .none
) -> AgentDefinition {
    var links = extraLinks
    if let executableTarget {
        links.append(RuntimeResourceProfile.ExecutableLink(name: id, target: executableTarget))
    }
    return AgentDefinition(
        id: AgentDefinitionID(rawValue: id),
        displayName: "Test agent",
        blurb: "",
        executableRequirement: executableRequirement,
        hookHost: hookHost,
        agentTag: agentTag,
        resourceProfile: RuntimeResourceProfile(
            id: "test-profile",
            projects: projects,
            executableLinks: links,
            readTrees: readTrees,
            credentials: credentials,
            keychain: keychain
        ),
        credentialBindings: credentialBindings,
        requiredAssurance: requiredAssurance,
        authorityCeiling: authorityCeiling
    )
}

func launchIntentNamed(
    definition: AgentDefinition? = nil,
    revision: AgentDefinitionRevision? = nil,
    resolvedExecutable: String = "/bin/cat",
    workspace: UUID? = nil,
    workingDirectory: String = "/tmp/identity-project",
    arguments: [String] = ["hello"],
    io: WorkspaceLaunchIO = .discard
) throws -> WorkspaceLaunchIntent {
    let definition = definition ?? launchIntentTestDefinition()
    let revision = revision ?? AgentDefinitionRevision.resolve(definition)
    let workspace = try workspace ?? launchIntentUUID("01234567-89ab-cdef-0123-456789abcdef")
    return try WorkspaceLaunchIntent.makeNamed(
        definition: definition,
        revision: revision,
        resolvedExecutable: resolvedExecutable,
        workspaceSessionID: WorkspaceSessionID(rawValue: workspace),
        workingDirectory: workingDirectory,
        arguments: arguments,
        io: io
    ).get()
}

func launchIntentCustom(
    executable: String = "/usr/local/bin/agent",
    digest: String = String(repeating: "ab", count: 32),
    workspace: UUID? = nil,
    workingDirectory: String = "/tmp/custom-project",
    arguments: [String] = ["--serve"],
    io: WorkspaceLaunchIO = .discard
) throws -> WorkspaceLaunchIntent {
    let workspace = try workspace ?? launchIntentUUID("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    return try WorkspaceLaunchIntent.makeCustom(
        executable: executable,
        expectedContentDigestSHA256: digest,
        workspaceSessionID: WorkspaceSessionID(rawValue: workspace),
        workingDirectory: workingDirectory,
        arguments: arguments,
        io: io
    ).get()
}

/// Fixed cross-implementation fixtures. Semantic inputs are pinned here;
/// expected canonical hex and digests are pinned in the vector tests below.
/// Future UI/host/service tests reuse these fixtures as compatibility
/// anchors: any byte or digest change is a security-relevant break.
func launchIntentFixtureNamedBasic() throws -> WorkspaceLaunchIntent {
    let definition = launchIntentTestDefinition()
    return try WorkspaceLaunchIntent.makeNamed(
        definition: definition,
        revision: AgentDefinitionRevision.resolve(definition),
        resolvedExecutable: "/bin/cat",
        workspaceSessionID: WorkspaceSessionID(
            rawValue: launchIntentUUID("01234567-89ab-cdef-0123-456789abcdef")
        ),
        workingDirectory: "/tmp/identity-project",
        arguments: ["hello"],
        io: .discard
    ).get()
}

func launchIntentFixtureNamedEmptyArg() throws -> WorkspaceLaunchIntent {
    let definition = launchIntentTestDefinition()
    return try WorkspaceLaunchIntent.makeNamed(
        definition: definition,
        revision: AgentDefinitionRevision.resolve(definition),
        resolvedExecutable: "/bin/cat",
        workspaceSessionID: WorkspaceSessionID(
            rawValue: launchIntentUUID("01234567-89ab-cdef-0123-456789abcdef")
        ),
        workingDirectory: "/tmp/identity-project",
        arguments: [""],
        io: .pseudoTerminal(rows: 24, columns: 80)
    ).get()
}

func launchIntentFixtureCustomBasic() throws -> WorkspaceLaunchIntent {
    try WorkspaceLaunchIntent.makeCustom(
        executable: "/usr/local/bin/agent",
        expectedContentDigestSHA256: String(repeating: "ab", count: 32),
        workspaceSessionID: WorkspaceSessionID(
            rawValue: launchIntentUUID("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        ),
        workingDirectory: "/tmp/custom-project",
        arguments: ["--serve", "--port", "8080"],
        io: .discard
    ).get()
}

func launchIntentFixtureUnicodeEdge() throws -> WorkspaceLaunchIntent {
    try WorkspaceLaunchIntent.makeCustom(
        executable: "/bin/caf\u{00E9}",
        expectedContentDigestSHA256: String(repeating: "01", count: 32),
        workspaceSessionID: WorkspaceSessionID(
            rawValue: launchIntentUUID("ffffffff-ffff-ffff-ffff-ffffffffffff")
        ),
        workingDirectory: "/tmp/unicode-project",
        arguments: ["e\u{0301}", "\u{202E}rtl", "a\tb", "x\ny", "zw\u{200B}sp"],
        io: .pseudoTerminal(rows: 1, columns: 512)
    ).get()
}

@Suite("Workspace launch intent")
struct WorkspaceLaunchIntentTests {
    // MARK: - Named validation

    @Test func namedRejectsInvalidDefinitionID() throws {
        for bad in ["", "has space", "has/slash", String(repeating: "a", count: 33)] {
            let definition = launchIntentTestDefinition(id: bad)
            let result = WorkspaceLaunchIntent.makeNamed(
                definition: definition,
                revision: AgentDefinitionRevision.resolve(definition),
                resolvedExecutable: "/bin/cat",
                workspaceSessionID: WorkspaceSessionID(),
                workingDirectory: "/tmp/identity-project",
                arguments: [],
                io: .discard
            )
            #expect(result == .failure(.invalidDefinitionID))
        }
    }

    @Test func namedRejectsReservedSnapshotID() throws {
        let definition = launchIntentTestDefinition(id: "adhoc")
        let result = WorkspaceLaunchIntent.makeNamed(
            definition: definition,
            revision: AgentDefinitionRevision.resolve(definition),
            resolvedExecutable: "/bin/cat",
            workspaceSessionID: WorkspaceSessionID(),
            workingDirectory: "/tmp/identity-project",
            arguments: [],
            io: .discard
        )
        #expect(result == .failure(.reservedDefinitionID))
    }

    @Test func namedRejectsMalformedRevision() throws {
        let definition = launchIntentTestDefinition()
        for bad in ["", "xyz", String(repeating: "A", count: 64), String(repeating: "a", count: 63),
            String(repeating: "a", count: 65), String(repeating: "g", count: 64)]
        {
            let result = WorkspaceLaunchIntent.makeNamed(
                definition: definition,
                revision: AgentDefinitionRevision(digestHex: bad),
                resolvedExecutable: "/bin/cat",
                workspaceSessionID: WorkspaceSessionID(),
                workingDirectory: "/tmp/identity-project",
                arguments: [],
                io: .discard
            )
            #expect(result == .failure(.invalidRevisionDigest))
        }
    }

    @Test func namedRejectsRevisionMismatch() throws {
        let definition = launchIntentTestDefinition()
        let other = launchIntentTestDefinition(id: "other-agent")
        let result = WorkspaceLaunchIntent.makeNamed(
            definition: definition,
            revision: AgentDefinitionRevision.resolve(other),
            resolvedExecutable: "/bin/cat",
            workspaceSessionID: WorkspaceSessionID(),
            workingDirectory: "/tmp/identity-project",
            arguments: [],
            io: .discard
        )
        #expect(result == .failure(.revisionMismatch))
    }

    @Test func namedRejectsBadExecutable() throws {
        let definition = launchIntentTestDefinition()
        let revision = AgentDefinitionRevision.resolve(definition)
        let long = "/bin/" + String(repeating: "a", count: 1020)
        #expect(long.utf8.count == 1025)
        for bad in ["", "relative/path", "/", "/a/../b", "/a/./b", "/a//b", "/a/", "/a\nb", "/a\rb",
            "/a\0b", long]
        {
            let result = WorkspaceLaunchIntent.makeNamed(
                definition: definition,
                revision: revision,
                resolvedExecutable: bad,
                workspaceSessionID: WorkspaceSessionID(),
                workingDirectory: "/tmp/identity-project",
                arguments: [],
                io: .discard
            )
            #expect(result == .failure(.invalidExecutable))
        }
    }

    @Test func namedAcceptsBoundaryExecutable() throws {
        let target = "/bin/" + String(repeating: "a", count: 1019)
        #expect(target.utf8.count == 1024)
        let definition = launchIntentTestDefinition(executableTarget: target)
        let intent = try WorkspaceLaunchIntent.makeNamed(
            definition: definition,
            revision: AgentDefinitionRevision.resolve(definition),
            resolvedExecutable: target,
            workspaceSessionID: WorkspaceSessionID(),
            workingDirectory: "/tmp/identity-project",
            arguments: [],
            io: .discard
        ).get()
        #expect(intent.arguments == [])
    }

    @Test func namedRejectsExecutableNotAuthorizedByRevision() throws {
        // Valid format, but not the revision-pinned link target.
        let definition = launchIntentTestDefinition()
        let revision = AgentDefinitionRevision.resolve(definition)
        let mismatched = WorkspaceLaunchIntent.makeNamed(
            definition: definition,
            revision: revision,
            resolvedExecutable: "/bin/other",
            workspaceSessionID: WorkspaceSessionID(),
            workingDirectory: "/tmp/identity-project",
            arguments: [],
            io: .discard
        )
        #expect(mismatched == .failure(.executableNotAuthorizedByRevision))

        // No link for this definition id.
        let unlinked = launchIntentTestDefinition(executableTarget: nil)
        let missing = WorkspaceLaunchIntent.makeNamed(
            definition: unlinked,
            revision: AgentDefinitionRevision.resolve(unlinked),
            resolvedExecutable: "/bin/cat",
            workspaceSessionID: WorkspaceSessionID(),
            workingDirectory: "/tmp/identity-project",
            arguments: [],
            io: .discard
        )
        #expect(missing == .failure(.executableNotAuthorizedByRevision))

        // Ambiguous: two links for this definition id.
        let ambiguous = launchIntentTestDefinition(extraLinks: [
            RuntimeResourceProfile.ExecutableLink(name: "trusted-agent", target: "/bin/cat"),
        ])
        let doubled = WorkspaceLaunchIntent.makeNamed(
            definition: ambiguous,
            revision: AgentDefinitionRevision.resolve(ambiguous),
            resolvedExecutable: "/bin/cat",
            workspaceSessionID: WorkspaceSessionID(),
            workingDirectory: "/tmp/identity-project",
            arguments: [],
            io: .discard
        )
        #expect(doubled == .failure(.executableNotAuthorizedByRevision))
    }

    @Test func namedRejectsCredentialBearingDefinitions() throws {
        let bound = launchIntentTestDefinition(credentialBindings: ["github"])
        #expect(
            WorkspaceLaunchIntent.makeNamed(
                definition: bound,
                revision: AgentDefinitionRevision.resolve(bound),
                resolvedExecutable: "/bin/cat",
                workspaceSessionID: WorkspaceSessionID(),
                workingDirectory: "/tmp/identity-project",
                arguments: [],
                io: .discard
            ) == .failure(.credentialStagingNotSupported)
        )

        let credentialed = launchIntentTestDefinition(
            credentials: [RuntimeResourceProfile.Credential(source: "a", destination: "b")]
        )
        #expect(
            WorkspaceLaunchIntent.makeNamed(
                definition: credentialed,
                revision: AgentDefinitionRevision.resolve(credentialed),
                resolvedExecutable: "/bin/cat",
                workspaceSessionID: WorkspaceSessionID(),
                workingDirectory: "/tmp/identity-project",
                arguments: [],
                io: .discard
            ) == .failure(.credentialStagingNotSupported)
        )

        let chained = launchIntentTestDefinition(
            keychain: [
                RuntimeResourceProfile.KeychainEntry(service: "s", account: "a", env: "E"),
            ]
        )
        #expect(
            WorkspaceLaunchIntent.makeNamed(
                definition: chained,
                revision: AgentDefinitionRevision.resolve(chained),
                resolvedExecutable: "/bin/cat",
                workspaceSessionID: WorkspaceSessionID(),
                workingDirectory: "/tmp/identity-project",
                arguments: [],
                io: .discard
            ) == .failure(.credentialStagingNotSupported)
        )
    }

    // MARK: - Custom validation

    @Test func customRejectsBadDigest() throws {
        for bad in ["", "xyz", String(repeating: "A", count: 64), String(repeating: "a", count: 63),
            String(repeating: "a", count: 65), String(repeating: "g", count: 64),
            String(repeating: " ", count: 64)]
        {
            let result = WorkspaceLaunchIntent.makeCustom(
                executable: "/usr/local/bin/agent",
                expectedContentDigestSHA256: bad,
                workspaceSessionID: WorkspaceSessionID(),
                workingDirectory: "/tmp/custom-project",
                arguments: [],
                io: .discard
            )
            #expect(result == .failure(.invalidExpectedDigest))
        }
    }

    @Test func customAcceptsBoundaryDigests() throws {
        for good in [String(repeating: "0", count: 64), String(repeating: "f", count: 64),
            String(repeating: "a0", count: 32)]
        {
            let intent = try WorkspaceLaunchIntent.makeCustom(
                executable: "/usr/local/bin/agent",
                expectedContentDigestSHA256: good,
                workspaceSessionID: WorkspaceSessionID(),
                workingDirectory: "/tmp/custom-project",
                arguments: [],
                io: .discard
            ).get()
            guard case .custom(let custom) = intent.target else {
                Issue.record("expected custom target")
                continue
            }
            #expect(custom.expectedContentDigestSHA256 == good)
        }
    }

    // MARK: - Common validation

    @Test func rejectsBadWorkingDirectory() throws {
        for bad in ["", "relative", "/", "/a/../b", "/a/./b", "/a//b", "/a/", "/a\nb", "/a\rb",
            "/a\0b", "/bin/" + String(repeating: "a", count: 1020)]
        {
            let result = WorkspaceLaunchIntent.makeCustom(
                executable: "/usr/local/bin/agent",
                expectedContentDigestSHA256: String(repeating: "a", count: 64),
                workspaceSessionID: WorkspaceSessionID(),
                workingDirectory: bad,
                arguments: [],
                io: .discard
            )
            #expect(result == .failure(.invalidWorkingDirectory))
        }
    }

    @Test func rejectsTooManyArguments() throws {
        let many = Array(repeating: "a", count: 65)
        #expect(
            WorkspaceLaunchIntent.makeCustom(
                executable: "/usr/local/bin/agent",
                expectedContentDigestSHA256: String(repeating: "a", count: 64),
                workspaceSessionID: WorkspaceSessionID(),
                workingDirectory: "/tmp/custom-project",
                arguments: many,
                io: .discard
            ) == .failure(.tooManyArguments)
        )
        let boundary = Array(repeating: "a", count: 64)
        #expect(
            try WorkspaceLaunchIntent.makeCustom(
                executable: "/usr/local/bin/agent",
                expectedContentDigestSHA256: String(repeating: "a", count: 64),
                workspaceSessionID: WorkspaceSessionID(),
                workingDirectory: "/tmp/custom-project",
                arguments: boundary,
                io: .discard
            ).get().arguments.count == 64
        )
    }

    @Test func rejectsBadArgument() throws {
        for bad in ["has\0nul", String(repeating: "a", count: 8193)] {
            #expect(
                WorkspaceLaunchIntent.makeCustom(
                    executable: "/usr/local/bin/agent",
                    expectedContentDigestSHA256: String(repeating: "a", count: 64),
                    workspaceSessionID: WorkspaceSessionID(),
                    workingDirectory: "/tmp/custom-project",
                    arguments: [bad],
                    io: .discard
                ) == .failure(.invalidArgument)
            )
        }
        let boundary = try WorkspaceLaunchIntent.makeCustom(
            executable: "/usr/local/bin/agent",
            expectedContentDigestSHA256: String(repeating: "a", count: 64),
            workspaceSessionID: WorkspaceSessionID(),
            workingDirectory: "/tmp/custom-project",
            arguments: ["", String(repeating: "a", count: 8192)],
            io: .discard
        ).get()
        #expect(boundary.arguments.count == 2)
    }

    @Test func rejectsBadTerminalDimensions() throws {
        for dims in [(0, 24), (24, 0), (513, 24), (24, 513), (-1, 24), (24, -1)] {
            #expect(
                WorkspaceLaunchIntent.makeCustom(
                    executable: "/usr/local/bin/agent",
                    expectedContentDigestSHA256: String(repeating: "a", count: 64),
                    workspaceSessionID: WorkspaceSessionID(),
                    workingDirectory: "/tmp/custom-project",
                    arguments: [],
                    io: .pseudoTerminal(rows: dims.0, columns: dims.1)
                ) == .failure(.invalidTerminalDimensions)
            )
        }
        for dims in [(1, 1), (1, 512), (512, 1), (512, 512), (24, 80)] {
            #expect(
                try WorkspaceLaunchIntent.makeCustom(
                    executable: "/usr/local/bin/agent",
                    expectedContentDigestSHA256: String(repeating: "a", count: 64),
                    workspaceSessionID: WorkspaceSessionID(),
                    workingDirectory: "/tmp/custom-project",
                    arguments: [],
                    io: .pseudoTerminal(rows: dims.0, columns: dims.1)
                ).get().io == .pseudoTerminal(rows: dims.0, columns: dims.1)
            )
        }
    }

    @Test func validationOrderIsFixed() throws {
        // Custom checks executable before digest.
        #expect(
            WorkspaceLaunchIntent.makeCustom(
                executable: "relative",
                expectedContentDigestSHA256: "bogus",
                workspaceSessionID: WorkspaceSessionID(),
                workingDirectory: "/tmp/custom-project",
                arguments: [],
                io: .discard
            ) == .failure(.invalidExecutable)
        )
        // Common checks working directory before arguments.
        #expect(
            WorkspaceLaunchIntent.makeCustom(
                executable: "/usr/local/bin/agent",
                expectedContentDigestSHA256: String(repeating: "a", count: 64),
                workspaceSessionID: WorkspaceSessionID(),
                workingDirectory: "relative",
                arguments: ["has\0nul"],
                io: .discard
            ) == .failure(.invalidWorkingDirectory)
        )
    }

    // MARK: - Stability and mutation

    @Test func digestIsStableAcrossInvocations() throws {
        let named = try launchIntentNamed()
        #expect(named.canonicalBytes == named.canonicalBytes)
        #expect(named.canonicalDigest == named.canonicalDigest)
        let rebuilt = try launchIntentNamed()
        #expect(named.canonicalBytes == rebuilt.canonicalBytes)
        #expect(named.canonicalDigest == rebuilt.canonicalDigest)
        let custom = try launchIntentCustom()
        #expect(custom.canonicalBytes == custom.canonicalBytes)
        #expect(custom.canonicalDigest == custom.canonicalDigest)
    }

    @Test func namedFieldMutationsChangeDigest() throws {
        let baseline = try launchIntentNamed()
        let baseDigest = baseline.canonicalDigest
        // Different definition id (with matching link).
        let renamed = launchIntentTestDefinition(id: "other-agent")
        #expect(
            try launchIntentNamed(definition: renamed, resolvedExecutable: "/bin/cat")
                .canonicalDigest != baseDigest
        )
        // Same id, changed definition content (new revision).
        let hardened = launchIntentTestDefinition(
            executableRequirement: ExecutableRequirement(
                expectedContentDigestSHA256: String(repeating: "c", count: 64)
            )
        )
        #expect(
            try launchIntentNamed(definition: hardened, resolvedExecutable: "/bin/cat")
                .canonicalDigest != baseDigest
        )
        // Resolved executable.
        let moved = launchIntentTestDefinition(executableTarget: "/bin/echo")
        #expect(
            try launchIntentNamed(definition: moved, resolvedExecutable: "/bin/echo")
                .canonicalDigest != baseDigest
        )
        // Workspace scope.
        #expect(
            try launchIntentNamed(
                workspace: launchIntentUUID("ffffffff-ffff-ffff-ffff-ffffffffffff")
            ).canonicalDigest != baseDigest
        )
        // Working directory.
        #expect(
            try launchIntentNamed(workingDirectory: "/tmp/other-project").canonicalDigest
                != baseDigest
        )
        // Arguments.
        #expect(try launchIntentNamed(arguments: ["hello", "world"]).canonicalDigest != baseDigest)
        #expect(try launchIntentNamed(arguments: []).canonicalDigest != baseDigest)
        // IO mode and dimensions.
        #expect(
            try launchIntentNamed(io: .pseudoTerminal(rows: 24, columns: 80)).canonicalDigest
                != baseDigest
        )
        let pty = try launchIntentNamed(io: .pseudoTerminal(rows: 24, columns: 80))
        #expect(
            try launchIntentNamed(io: .pseudoTerminal(rows: 25, columns: 80)).canonicalDigest
                != pty.canonicalDigest
        )
        #expect(
            try launchIntentNamed(io: .pseudoTerminal(rows: 24, columns: 81)).canonicalDigest
                != pty.canonicalDigest
        )
    }

    @Test func customFieldMutationsChangeDigest() throws {
        let baseline = try launchIntentCustom()
        let baseDigest = baseline.canonicalDigest
        #expect(
            try launchIntentCustom(executable: "/usr/local/bin/other").canonicalDigest != baseDigest
        )
        #expect(
            try launchIntentCustom(digest: String(repeating: "c", count: 64)).canonicalDigest
                != baseDigest
        )
        #expect(
            try launchIntentCustom(
                workspace: launchIntentUUID("ffffffff-ffff-ffff-ffff-ffffffffffff")
            ).canonicalDigest != baseDigest
        )
        #expect(
            try launchIntentCustom(workingDirectory: "/tmp/other").canonicalDigest != baseDigest
        )
        #expect(
            try launchIntentCustom(arguments: ["--serve", "--fresh"]).canonicalDigest != baseDigest
        )
        #expect(
            try launchIntentCustom(io: .pseudoTerminal(rows: 24, columns: 80)).canonicalDigest
                != baseDigest
        )
    }

    @Test func revisionPinsAllDefinitionContent() throws {
        let baseline = try launchIntentNamed()
        let baseDigest = baseline.canonicalDigest
        let variants: [AgentDefinition] = [
            launchIntentTestDefinition(hookHost: .codex),
            launchIntentTestDefinition(agentTag: "codex"),
            launchIntentTestDefinition(requiredAssurance: .unattested),
            launchIntentTestDefinition(authorityCeiling: AgentAuthority(scopes: ["fs.read"])),
            launchIntentTestDefinition(projects: ["/tmp/identity-project", "/tmp/extra"]),
            launchIntentTestDefinition(readTrees: ["/tmp/ro"]),
            launchIntentTestDefinition(
                executableRequirement: ExecutableRequirement(
                    requiredTeamID: "ABCDE12345",
                    allowsUnsigned: true
                )
            ),
        ]
        for variant in variants {
            #expect(
                try launchIntentNamed(definition: variant, resolvedExecutable: "/bin/cat")
                    .canonicalDigest != baseDigest
            )
        }
        // Display-only text never enters the revision: same revision, same digest.
        let base = launchIntentTestDefinition()
        let relabeled = AgentDefinition(
            id: base.id,
            displayName: "Renamed",
            blurb: "new blurb",
            executableRequirement: base.executableRequirement,
            hookHost: base.hookHost,
            agentTag: base.agentTag,
            resourceProfile: base.resourceProfile,
            credentialBindings: base.credentialBindings,
            requiredAssurance: base.requiredAssurance,
            authorityCeiling: base.authorityCeiling
        )
        #expect(
            try launchIntentNamed(definition: relabeled, resolvedExecutable: "/bin/cat")
                .canonicalDigest == baseDigest
        )
    }

    @Test func variantDistinguishesNamedFromCustom() throws {
        let named = try launchIntentNamed(
            workingDirectory: "/tmp/shared",
            arguments: ["x"],
            io: .discard
        )
        let custom = try launchIntentCustom(
            executable: "/bin/cat",
            workingDirectory: "/tmp/shared",
            arguments: ["x"],
            io: .discard
        )
        #expect(named.canonicalDigest != custom.canonicalDigest)
        #expect(named.canonicalBytes != custom.canonicalBytes)
    }

    // MARK: - Argv framing attacks

    @Test func argvOrderMatters() throws {
        let forward = try launchIntentCustom(arguments: ["--foo", "bar"])
        let backward = try launchIntentCustom(arguments: ["bar", "--foo"])
        #expect(forward.canonicalDigest != backward.canonicalDigest)
    }

    @Test func argvDuplicatesMatter() throws {
        let doubled = try launchIntentCustom(arguments: ["a", "a"])
        let single = try launchIntentCustom(arguments: ["a"])
        #expect(doubled.canonicalDigest != single.canonicalDigest)
        let tripled = try launchIntentCustom(arguments: ["a", "a", "a"])
        #expect(tripled.canonicalDigest != doubled.canonicalDigest)
    }

    @Test func emptyArgumentDiffersFromNoArguments() throws {
        let empty = try launchIntentCustom(arguments: [""])
        let none = try launchIntentCustom(arguments: [])
        #expect(empty.canonicalDigest != none.canonicalDigest)
        let twoEmpty = try launchIntentCustom(arguments: ["", ""])
        #expect(twoEmpty.canonicalDigest != empty.canonicalDigest)
    }

    @Test func fieldBoundariesCannotShift() throws {
        // Under delimiter concatenation these pairs could collide; length
        // framing keeps every field distinct.
        let split = try launchIntentCustom(executable: "/x", arguments: ["yz"])
        let joined = try launchIntentCustom(executable: "/xyz", arguments: [])
        #expect(split.canonicalDigest != joined.canonicalDigest)
        let a = try launchIntentCustom(executable: "/bin/a", arguments: ["b"])
        let b = try launchIntentCustom(executable: "/bin/ab", arguments: [])
        #expect(a.canonicalDigest != b.canonicalDigest)
        let c = try launchIntentCustom(arguments: ["a", "bc"])
        let d = try launchIntentCustom(arguments: ["ab", "c"])
        #expect(c.canonicalDigest != d.canonicalDigest)
        let e = try launchIntentCustom(arguments: ["ab"])
        #expect(c.canonicalDigest != e.canonicalDigest)
        #expect(d.canonicalDigest != e.canonicalDigest)
    }

    @Test func delimiterLookingValuesCannotCollide() throws {
        // NUL itself is rejected (unpassable through exec), and covered by
        // rejectsBadArgument; everything here must bind as distinct bytes.
        let tricky = [
            "RV.WorkspaceLaunchIntent.v1",
            "RV.WorkspaceLaunchIntent.v1 ",
            " RV.WorkspaceLaunchIntent.v1",
            "\u{FFFD}",
            "\n",
            "\r\n",
            "a\nb",
            "a\rb",
            "a\tb",
            "0x00",
            "empty-prefix",
            "1\n/trusted",
            "-",
            "0",
            "1:",
            ",",
            "=",
            "\\",
            "\\n",
            "definition-id",
        ]
        var digests = Set<String>()
        for value in tricky {
            let intent = try launchIntentCustom(arguments: [value])
            digests.insert(intent.canonicalDigest.sha256Hex)
        }
        #expect(digests.count == tricky.count)
    }

    // MARK: - Unicode

    @Test func unicodeDistinctionsArePreserved() throws {
        let pairs: [(String, String)] = [
            ("caf\u{00E9}", "cafe\u{0301}"),
            ("a\u{200B}b", "ab"),
            ("a\u{200C}b", "a\u{200D}b"),
            ("a\u{202E}b", "ab"),
            ("a\u{FEFF}b", "ab"),
            ("a\nb", "a\tb"),
            ("a\nb", "ab"),
            ("Ａ", "A"),
        ]
        // The first pair is canonically equal as Swift strings but differs in
        // UTF-8 bytes; canonical binding follows exact bytes, not Swift
        // equality, so every pair here must still digest distinctly.
        #expect(pairs[0].0 == pairs[0].1)
        for (left, right) in pairs {
            #expect(left.utf8.count != right.utf8.count || Array(left.utf8) != Array(right.utf8))
            let l = try launchIntentCustom(arguments: [left])
            let r = try launchIntentCustom(arguments: [right])
            #expect(l.canonicalDigest != r.canonicalDigest)
        }
        // Same distinction through the executable path.
        let precomposed = try launchIntentCustom(executable: "/bin/caf\u{00E9}")
        let decomposed = try launchIntentCustom(executable: "/bin/cafe\u{0301}")
        #expect(precomposed.canonicalDigest != decomposed.canonicalDigest)
    }

    // MARK: - Paths

    @Test func noCanonicalPathEquivalenceIsClaimed() throws {
        let tmp = try launchIntentCustom(workingDirectory: "/tmp/foo")
        let `private` = try launchIntentCustom(workingDirectory: "/private/tmp/foo")
        #expect(tmp.canonicalDigest != `private`.canonicalDigest)
        let link = try launchIntentCustom(executable: "/tmp/agent")
        let resolved = try launchIntentCustom(executable: "/private/tmp/agent")
        #expect(link.canonicalDigest != resolved.canonicalDigest)
    }

    @Test func unresolvedSpellingConstructsButStaysDistinct() throws {
        // Fresh-review finding: construction cannot verify realpath
        // resolution (no filesystem access in the domain layer), so an
        // unresolved spelling still constructs. That is fail-closed, not a
        // bypass: the spellings digest distinctly, and the future
        // redemption equality check rejects any intent whose bound string
        // differs from live realpath. One digest never authorizes two
        // executions; resolving before construction is a liveness MUST for
        // host preparation.
        let unresolved = try launchIntentCustom(workingDirectory: "/tmp/foo")
        let resolved = try launchIntentCustom(workingDirectory: "/private/tmp/foo")
        #expect(unresolved.workingDirectory == "/tmp/foo")
        #expect(resolved.workingDirectory == "/private/tmp/foo")
        #expect(unresolved.canonicalDigest != resolved.canonicalDigest)
        #expect(unresolved.canonicalBytes != resolved.canonicalBytes)
    }

    // MARK: - Long inputs

    @Test func longInputsAreBoundWithoutTruncation() throws {
        let stem = "/bin/" + String(repeating: "a", count: 1018)
        let first = try launchIntentCustom(executable: stem + "a")
        let second = try launchIntentCustom(executable: stem + "b")
        #expect(first.canonicalDigest != second.canonicalDigest)
        let argStem = String(repeating: "a", count: 8191)
        let argFirst = try launchIntentCustom(arguments: [argStem + "a"])
        let argSecond = try launchIntentCustom(arguments: [argStem + "b"])
        #expect(argFirst.canonicalDigest != argSecond.canonicalDigest)
        var many = (0..<64).map { "arg-\($0)" }
        let full = try launchIntentCustom(arguments: many)
        many.removeLast()
        let dropped = try launchIntentCustom(arguments: many)
        #expect(full.canonicalDigest != dropped.canonicalDigest)
    }

    // MARK: - Canonical structure

    @Test func canonicalBytesHaveDocumentedLayout() throws {
        let intent = try launchIntentNamed()
        let bytes = intent.canonicalBytes
        let domain = Array("RV.WorkspaceLaunchIntent.v1".utf8)
        #expect(domain.count == 27)
        #expect(bytes.count > domain.count + 16)
        #expect(Array(bytes.prefix(4)) == [0x00, 0x00, 0x00, 0x1B])
        #expect(Array(bytes[4..<(4 + domain.count)]) == domain)
        let versionStart = 4 + domain.count
        #expect(Array(bytes[versionStart..<(versionStart + 4)]) == [0x00, 0x00, 0x00, 0x01])
        #expect(bytes[versionStart + 4] == 0x00)
        let custom = try launchIntentCustom()
        let customBytes = custom.canonicalBytes
        #expect(Array(customBytes.prefix(4 + domain.count)) == Array(bytes.prefix(4 + domain.count)))
        #expect(customBytes[versionStart + 4] == 0x01)
    }

    @Test func digestIsLowercaseHexSHA256() throws {
        let intent = try launchIntentNamed()
        let hex = intent.canonicalDigest.sha256Hex
        #expect(hex.utf8.count == 64)
        #expect(hex.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) })
    }

    // MARK: - Fixed cross-implementation vectors

    @Test func vectorNamedBasic() throws {
        let intent = try launchIntentFixtureNamedBasic()
        #expect(
            launchIntentHex(intent.canonicalBytes)
                == "0000001b52562e576f726b73706163654c61756e6368496e74656e742e763100000001000000"
                + "000d747275737465642d6167656e740000004035393032616531393433643361633832326131"
                + "6339393561653931396539626334353438653665386137366163373331646235313731343661"
                + "31386138336536000000082f62696e2f6361740123456789abcdef0123456789abcdef000000"
                + "152f746d702f6964656e746974792d70726f6a656374000000010000000568656c6c6f0000"
        )
        #expect(
            intent.canonicalDigest.sha256Hex
                == "457319951f00a5905524b5dbf95d4c4ac46fe698725a106f3ea1617e1903e505"
        )
    }

    @Test func vectorNamedEmptyArg() throws {
        let intent = try launchIntentFixtureNamedEmptyArg()
        #expect(
            launchIntentHex(intent.canonicalBytes)
                == "0000001b52562e576f726b73706163654c61756e6368496e74656e742e763100000001000000"
                + "000d747275737465642d6167656e740000004035393032616531393433643361633832326131"
                + "6339393561653931396539626334353438653665386137366163373331646235313731343661"
                + "31386138336536000000082f62696e2f6361740123456789abcdef0123456789abcdef000000"
                + "152f746d702f6964656e746974792d70726f6a65637400000001000000000100000018000000"
                + "5000"
        )
        #expect(
            intent.canonicalDigest.sha256Hex
                == "7430a985ba4788baded9c9044b1e71571e442ff806d0d6d1fb9c956ddce80823"
        )
    }

    @Test func vectorCustomBasic() throws {
        let intent = try launchIntentFixtureCustomBasic()
        #expect(
            launchIntentHex(intent.canonicalBytes)
                == "0000001b52562e576f726b73706163654c61756e6368496e74656e742e763100000001010000"
                + "00142f7573722f6c6f63616c2f62696e2f6167656e7400000040616261626162616261626162"
                + "6162616261626162616261626162616261626162616261626162616261626162616261626162"
                + "6162616261626162616261626162aaaaaaaabbbbccccddddeeeeeeeeeeee000000132f746d70"
                + "2f637573746f6d2d70726f6a65637400000003000000072d2d7365727665000000062d2d706f"
                + "727400000004383038300000"
        )
        #expect(
            intent.canonicalDigest.sha256Hex
                == "6df039cab25e38e3849b74da86fecdb9171fbf5f9885fb82354956ac7a57b86c"
        )
    }

    @Test func vectorUnicodeEdge() throws {
        let intent = try launchIntentFixtureUnicodeEdge()
        #expect(
            launchIntentHex(intent.canonicalBytes)
                == "0000001b52562e576f726b73706163654c61756e6368496e74656e742e763100000001010000"
                + "000a2f62696e2f636166c3a90000004030313031303130313031303130313031303130313031"
                + "3031303130313031303130313031303130313031303130313031303130313031303130313031"
                + "30313031ffffffffffffffffffffffffffffffff000000142f746d702f756e69636f64652d70"
                + "726f6a656374000000050000000365cc8100000006e280ae72746c0000000361096200000003"
                + "780a79000000077a77e2808b737001000000010000020000"
        )
        #expect(
            intent.canonicalDigest.sha256Hex
                == "a705cff969da5840951b7d93ef824351e83c60c227d2a6923801bf72c1d63750"
        )
    }

    // MARK: - Summary projection

    @Test func summaryIsStructuredAndDoesNotMutateIntent() throws {
        let named = try launchIntentNamed(arguments: ["--flag", "value with spaces"])
        let before = named.canonicalBytes
        let summary = named.auditSummary
        #expect(summary.kind == .named)
        #expect(summary.definitionID == "trusted-agent")
        #expect(summary.definitionRevisionDigest == AgentDefinitionRevision.resolve(launchIntentTestDefinition()).digestHex)
        #expect(summary.executable == "/bin/cat")
        #expect(summary.expectedContentDigestSHA256 == nil)
        #expect(summary.arguments == ["--flag", "value with spaces"])
        #expect(summary.io == .discard)
        #expect(summary.environment == .containedProjectionV1)
        #expect(named.canonicalBytes == before)
        #expect(named.canonicalDigest == named.canonicalDigest)

        let custom = try launchIntentCustom()
        let customSummary = custom.auditSummary
        #expect(customSummary.kind == .custom)
        #expect(customSummary.definitionID == nil)
        #expect(customSummary.definitionRevisionDigest == nil)
        #expect(customSummary.expectedContentDigestSHA256 == String(repeating: "ab", count: 32))
    }

    // MARK: - Property-style

    @Test func randomSingleFieldMutationsChangeDigest() throws {
        var rng: UInt64 = 0x1234_5678_9ABC_DEF1
        func next(_ bound: UInt64) -> UInt64 {
            rng ^= rng << 13
            rng ^= rng >> 7
            rng ^= rng << 17
            return rng % bound
        }
        let alphabet = ["a", "b", "", "--flag", "x y", "uni-\u{00E9}", "\t", "0"]
        for _ in 0..<200 {
            let argc = Int(next(5))
            var args: [String] = []
            for _ in 0..<argc {
                args.append(alphabet[Int(next(UInt64(alphabet.count)))])
            }
            let io: WorkspaceLaunchIO =
                next(2) == 0
                ? .discard
                : .pseudoTerminal(rows: 1 + Int(next(512)), columns: 1 + Int(next(512)))
            let base = try launchIntentCustom(arguments: args, io: io)
            let baseDigest = base.canonicalDigest
            let choice = next(6)
            let mutant: WorkspaceLaunchIntent
            switch choice {
            case 0:
                mutant = try launchIntentCustom(
                    executable: "/bin/mutant-\(next(1000))",
                    arguments: args,
                    io: io
                )
            case 1:
                var bytes = [UInt8](repeating: 0, count: 32)
                for index in bytes.indices {
                    bytes[index] = UInt8(truncatingIfNeeded: next(256))
                }
                mutant = try launchIntentCustom(
                    digest: launchIntentHex(bytes),
                    arguments: args,
                    io: io
                )
            case 2:
                mutant = try launchIntentCustom(
                    workingDirectory: "/tmp/mutant-\(next(1000))",
                    arguments: args,
                    io: io
                )
            case 3:
                mutant = try launchIntentCustom(arguments: args + ["mutant-\(next(1000))"], io: io)
            case 4:
                mutant = try launchIntentCustom(
                    arguments: args,
                    io: .pseudoTerminal(rows: 1 + Int(next(512)), columns: 1 + Int(next(512)))
                )
                if mutant.canonicalDigest == baseDigest {
                    continue
                }
            default:
                mutant = try launchIntentCustom(
                    workspace: UUID(),
                    arguments: args,
                    io: io
                )
            }
            #expect(mutant.canonicalDigest != baseDigest)
        }
    }

    @Test func randomArgvPermutationsAreDistinct() throws {
        var rng: UInt64 = 0xDEAD_BEEF_CAFE_F00D
        func next(_ bound: UInt64) -> UInt64 {
            rng ^= rng << 13
            rng ^= rng >> 7
            rng ^= rng << 17
            return rng % bound
        }
        let alphabet = ["a", "b", "c", ""]
        for _ in 0..<50 {
            var args: [String] = []
            for _ in 0..<3 {
                args.append(alphabet[Int(next(UInt64(alphabet.count)))])
            }
            let rotations = [args, [args[2], args[0], args[1]], [args[1], args[2], args[0]]]
            var unique: [[String]] = []
            for rotation in rotations where unique.contains(rotation) == false {
                unique.append(rotation)
            }
            var digests = Set<String>()
            for rotation in unique {
                digests.insert(
                    try launchIntentCustom(arguments: rotation).canonicalDigest.sha256Hex
                )
            }
            #expect(digests.count == unique.count)
        }
    }
}
