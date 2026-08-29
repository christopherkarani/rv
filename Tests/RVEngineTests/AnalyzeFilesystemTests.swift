import Testing
import RVDomain
@testable import RVEngine

@Suite("AnalyzeFilesystem")
struct AnalyzeFilesystemTests {
    private let repo = FilesystemAnalysisContext(
        workingDirectory: WorkingDirectory(validating: "/repo"),
        repositoryRoot: RepositoryRoot(validating: "/repo")
    )

    @Test func deleteGeneratedAndSource_haveDistinctResourceMetadata() {
        let generated = analyzeFilesystem(
            ShellCommand(rawValue: "rm .build/artifact"),
            context: repo
        )
        let source = analyzeFilesystem(
            ShellCommand(rawValue: "rm Sources/Foo.swift"),
            context: repo
        )
        guard case .filesystem(let generatedAction) = generated else {
            Issue.record("expected filesystem analysis for generated delete")
            return
        }
        guard case .filesystem(let sourceAction) = source else {
            Issue.record("expected filesystem analysis for source delete")
            return
        }
        #expect(generatedAction.resources.resourceKind == .generatedOutput)
        #expect(sourceAction.resources.resourceKind == .sourceCode)
        #expect(generatedAction.resources.filesystemScope == .insideRepository)
        #expect(sourceAction.resources.filesystemScope == .insideRepository)
        #expect(generatedAction.explainKind == "generated output")
        #expect(sourceAction.explainKind == "source code")
        #expect(generatedAction.explainScope == "inside repo")
        #expect(generated != source)
    }

    @Test func parentTraversal_resolvesOutsideRepository() {
        let analysis = analyzeFilesystem(
            ShellCommand(rawValue: "rm ../outside-file"),
            context: repo
        )
        guard case .filesystem(.delete(let targets, _, _)) = analysis else {
            Issue.record("expected delete, got \(analysis)")
            return
        }
        #expect(targets.count == 1)
        #expect(targets[0].canonical == "/outside-file")
        #expect(targets[0].scope == .outsideRepository)
        #expect(targets[0].followedSymlink == false)
    }

    @Test func symlinkEscapeFact_usesResolvedOutsideTarget() {
        let context = FilesystemAnalysisContext(
            workingDirectory: WorkingDirectory(validating: "/repo"),
            repositoryRoot: RepositoryRoot(validating: "/repo"),
            facts: [
                FilesystemPathFact(
                    apparent: "link",
                    canonical: "/tmp/outside-file",
                    followedSymlink: true,
                    resolution: .resolved
                ),
            ]
        )
        let analysis = analyzeFilesystem(ShellCommand(rawValue: "rm link"), context: context)
        guard case .filesystem(.delete(let targets, _, _)) = analysis else {
            Issue.record("expected delete, got \(analysis)")
            return
        }
        #expect(targets[0].canonical == "/tmp/outside-file")
        #expect(targets[0].scope == .outsideRepository)
        #expect(targets[0].followedSymlink)
        #expect(targets[0].apparent == "link")
    }

    @Test func homeAliases_resolveToProtectedScope() {
        let context = FilesystemAnalysisContext(
            workingDirectory: WorkingDirectory(validating: "/isolated-home/project"),
            repositoryRoot: RepositoryRoot(validating: "/isolated-home/project"),
            homeDirectory: "/isolated-home"
        )
        let commands = [
            "rm ~/.ssh/config",
            "rm $HOME/.ssh/config",
            "rm ${HOME}/.ssh/config",
            "rm ../.ssh/config",
        ]
        for command in commands {
            let analysis = analyzeFilesystem(ShellCommand(rawValue: command), context: context)
            guard case .filesystem(let action) = analysis else {
                Issue.record("expected filesystem analysis for \(command)")
                continue
            }
            #expect(action.primaryTarget?.scope == .protectedPath)
            #expect(action.primaryTarget?.canonical == "/isolated-home/.ssh/config")
            #expect(action.primaryTarget?.protectedMatch?.pattern == "home-ssh")
            #expect(action.primaryTarget?.protectedMatch?.category == .ssh)
            #expect(action.effects.kinds.contains(.protectedPathMutation))
            #expect(action.explainCategory == "ssh")
            #expect(action.explainCatalogRule == "core.secrets/home-ssh")
        }
    }

    @Test func inRepoOrdinaryFile_isNotProtectedByDefault() {
        let analysis = analyzeFilesystem(
            ShellCommand(rawValue: "rm Sources/Foo.swift"),
            context: repo
        )
        guard case .filesystem(let action) = analysis else {
            Issue.record("expected filesystem analysis")
            return
        }
        #expect(action.primaryTarget?.scope == .insideRepository)
        #expect(action.primaryTarget?.protectedMatch == nil)
        #expect(action.effects.kinds.contains(.protectedPathMutation) == false)
    }

    @Test func keychainAndCloudHomes_areProtectedCategories() {
        let context = FilesystemAnalysisContext(
            workingDirectory: WorkingDirectory(validating: "/repo"),
            repositoryRoot: RepositoryRoot(validating: "/repo"),
            homeDirectory: "/isolated-home"
        )
        let rows: [(String, String, SecretPathCategory)] = [
            ("rm ~/.aws/config", "home-aws", .cloud),
            ("rm ~/Library/Keychains/login.keychain-db", "home-keychains", .keychain),
            ("rm $HOME/.gnupg/trustdb.gpg", "home-gnupg", .keychain),
            ("rm ${HOME}/.local/share/keyrings/login.keyring", "home-keyrings", .keychain),
        ]
        for (command, pattern, category) in rows {
            let analysis = analyzeFilesystem(ShellCommand(rawValue: command), context: context)
            guard case .filesystem(let action) = analysis else {
                Issue.record("expected filesystem analysis for \(command)")
                continue
            }
            #expect(action.primaryTarget?.scope == .protectedPath)
            #expect(action.primaryTarget?.protectedMatch?.pattern == pattern)
            #expect(action.primaryTarget?.protectedMatch?.category == category)
        }
    }

    @Test func symlinkToProtected_isProtectedScope() {
        let context = FilesystemAnalysisContext(
            workingDirectory: WorkingDirectory(validating: "/repo"),
            repositoryRoot: RepositoryRoot(validating: "/repo"),
            facts: [
                FilesystemPathFact(
                    apparent: "link",
                    canonical: "/isolated-home/.ssh/id_rsa",
                    followedSymlink: true,
                    resolution: .resolved
                ),
            ]
        )
        let analysis = analyzeFilesystem(ShellCommand(rawValue: "rm link"), context: context)
        guard case .filesystem(let action) = analysis else {
            Issue.record("expected filesystem analysis")
            return
        }
        #expect(action.primaryTarget?.scope == .protectedPath)
        #expect(action.effects.kinds.contains(.protectedPathMutation))
        #expect(action.primaryTarget?.protectedMatch?.pattern == "id-rsa")
        #expect(action.primaryTarget?.protectedMatch?.category == .ssh)
    }

    @Test func relativeTraversalChains_resolveOutsideBeforePolicy() {
        let chains = [
            "rm ../../outside-file",
            "rm foo/../../outside-file",
            "rm ././../outside-file",
            "rm foo/bar/../../../outside-file",
        ]
        for command in chains {
            let analysis = analyzeFilesystem(ShellCommand(rawValue: command), context: repo)
            guard case .filesystem(.delete(let targets, _, _)) = analysis else {
                Issue.record("expected delete for \(command), got \(analysis)")
                continue
            }
            #expect(targets[0].canonical == "/outside-file")
            #expect(targets[0].scope == .outsideRepository)
            #expect(targets[0].apparent.contains(".."))
        }
    }

    @Test func uncertainResolution_isUnknownNotInside() {
        let context = FilesystemAnalysisContext(
            workingDirectory: WorkingDirectory(validating: "/repo"),
            repositoryRoot: RepositoryRoot(validating: "/repo"),
            facts: [
                FilesystemPathFact(
                    apparent: "file",
                    canonical: "/repo/file",
                    resolution: .uncertain
                ),
            ]
        )
        let analysis = analyzeFilesystem(ShellCommand(rawValue: "rm file"), context: context)
        guard case .filesystem(.delete(let targets, _, _)) = analysis else {
            Issue.record("expected delete, got \(analysis)")
            return
        }
        #expect(targets[0].canonical == "/repo/file")
        #expect(targets[0].scope == .unknown)
        #expect(targets[0].resolution == .uncertain)
    }

    @Test func operations_areDistinguished() {
        guard case .filesystem(let created) =
            analyzeFilesystem(ShellCommand(rawValue: "touch new.swift"), context: repo)
        else {
            Issue.record("expected create")
            return
        }
        guard case .filesystem(let written) =
            analyzeFilesystem(ShellCommand(rawValue: "echo hi > Sources/Foo.swift"), context: repo)
        else {
            Issue.record("expected write")
            return
        }
        guard case .filesystem(let read) =
            analyzeFilesystem(ShellCommand(rawValue: "cat Sources/Foo.swift"), context: repo)
        else {
            Issue.record("expected read")
            return
        }
        #expect(created.operationKind == .create)
        #expect(written.operationKind == .write)
        #expect(read.operationKind == .read)
        #expect(created.resources.filesystemScope == .insideRepository)
        #expect(written.resources.filesystemScope == .insideRepository)
        #expect(read.resources.filesystemScope == .insideRepository)
    }

    @Test func caseSensitiveRoot_doesNotMatchDifferentCaseOnLinux() {
        #if os(Linux)
        let analysis = analyzeFilesystem(
            ShellCommand(rawValue: "rm /REPO/file"),
            context: repo
        )
        guard case .filesystem(.delete(let targets, _, _)) = analysis else {
            Issue.record("expected delete, got \(analysis)")
            return
        }
        #expect(targets[0].canonical == "/REPO/file")
        #expect(targets[0].scope == .outsideRepository)
        #endif
    }

    @Test func unsupportedSyntax_isUnknown() {
        #expect(analyzeFilesystem(ShellCommand(rawValue: "echo hello")) == .unknown)
        #expect(analyzeFilesystem(ShellCommand(rawValue: "rm --weird-flag file")) == .unknown)
        #expect(analyzeFilesystem(ShellCommand(rawValue: "rm $FILE")) == .unknown)
        #expect(
            analyzeFilesystem(ShellCommand(rawValue: "bash -c 'rm -rf Sources'")) == .unknown
        )
        #expect(
            analyzeFilesystem(ShellCommand(rawValue: "rm file && echo done")) == .unknown
        )
    }

    @Test func highValueOperations_parse() {
        #expect(
            {
                guard case .filesystem(.delete(_, let recursive, let force)) =
                    analyzeFilesystem(ShellCommand(rawValue: "rm -rf .build"), context: repo)
                else { return false }
                return recursive && force
            }()
        )
        guard case .filesystem(.move(let sources, let destination)) =
            analyzeFilesystem(ShellCommand(rawValue: "mv Sources/Foo.swift /tmp/out"), context: repo)
        else {
            Issue.record("expected move")
            return
        }
        #expect(sources[0].kind == .sourceCode)
        #expect(destination.scope == .outsideRepository)

        guard case .filesystem(.overwrite(let targets)) =
            analyzeFilesystem(
                ShellCommand(rawValue: "echo hi > Sources/Foo.swift"),
                context: repo
            )
        else {
            Issue.record("expected overwrite")
            return
        }
        #expect(targets[0].kind == .sourceCode)

        guard case .filesystem(.chmod(let chmodTargets, let mode, _)) =
            analyzeFilesystem(ShellCommand(rawValue: "chmod 000 Sources/Foo.swift"), context: repo)
        else {
            Issue.record("expected chmod")
            return
        }
        #expect(mode == "000")
        #expect(chmodTargets[0].kind == .sourceCode)
    }
}
