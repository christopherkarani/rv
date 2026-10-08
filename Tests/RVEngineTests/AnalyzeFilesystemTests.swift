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
            homeDirectory: HomePath(validating: "/isolated-home")
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
            #expect(
                action.primaryTarget?.scope
                    == .protectedPath(SecretPathMatch(pattern: "home-ssh", category: .ssh))
            )
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
            homeDirectory: HomePath(validating: "/isolated-home")
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
            #expect(
                action.primaryTarget?.scope
                    == .protectedPath(SecretPathMatch(pattern: pattern, category: category))
            )
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
        #expect(
            action.primaryTarget?.scope
                == .protectedPath(SecretPathMatch(pattern: "id-rsa", category: .ssh))
        )
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
        #expect(targets[0].protectedMatch == nil)
    }

    @Test func uncertainCatalogShapedPath_isUnknownNotProtected() {
        let context = FilesystemAnalysisContext(
            workingDirectory: WorkingDirectory(validating: "/repo"),
            repositoryRoot: RepositoryRoot(validating: "/repo"),
            facts: [
                FilesystemPathFact(
                    apparent: "id_rsa",
                    canonical: "/isolated-home/.ssh/id_rsa",
                    resolution: .uncertain
                ),
            ]
        )
        let analysis = analyzeFilesystem(ShellCommand(rawValue: "rm id_rsa"), context: context)
        guard case .filesystem(let action) = analysis else {
            Issue.record("expected filesystem analysis")
            return
        }
        #expect(action.primaryTarget?.scope == .unknown)
        #expect(action.primaryTarget?.protectedMatch == nil)
        #expect(action.effects.kinds.contains(.protectedPathMutation) == false)
        #expect(action.effects.kinds.contains(.unresolvedFilesystem))
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
        #expect(
            analyzeFilesystem(ShellCommand(rawValue: "bash -c 'rm -rf Sources'")) == .unknown
        )
        #expect(
            analyzeFilesystem(ShellCommand(rawValue: "rm file && echo done")) == .unknown
        )
    }

    // MARK: - P10e7 (A-F4/C-F4): dynamic mutation paths fail closed as outside

    @Test func dynamicMutationPath_classifiesOutside() {
        guard case .filesystem(.delete(let targets, _, _)) =
            analyzeFilesystem(ShellCommand(rawValue: "rm $FILE"), context: repo)
        else {
            Issue.record("expected delete for dynamic rm")
            return
        }
        #expect(targets.count == 1)
        #expect(targets[0].apparent == "$FILE")
        #expect(targets[0].scope == .outsideRepository)
    }

    @Test func staticOutside_survivesDynamicOperands() {
        guard case .filesystem(.overwrite(let targets)) =
            analyzeFilesystem(ShellCommand(rawValue: "cp $f /tmp/eve"), context: repo)
        else {
            Issue.record("expected overwrite for cp with dynamic source")
            return
        }
        #expect(targets.contains(where: { $0.scope == .outsideRepository }))
        guard case .filesystem(.overwrite(let redirectTargets)) =
            analyzeFilesystem(ShellCommand(rawValue: "echo hi > $f > /tmp/eve"), context: repo)
        else {
            Issue.record("expected overwrite for mixed redirect")
            return
        }
        #expect(redirectTargets.contains(where: { $0.apparent == "/tmp/eve" }))
    }

    @Test func dynamicReadsAndData_stayUnclaimed() {
        #expect(analyzeFilesystem(ShellCommand(rawValue: "cat $f")) == .unknown)
        #expect(analyzeFilesystem(ShellCommand(rawValue: "echo $x")) == .unknown)
    }

    @Test func homeAlias_isNotDynamic() {
        // `$HOME` expands lexically: still a classified (non-blind) target.
        guard case .filesystem(.delete(let targets, _, _)) =
            analyzeFilesystem(ShellCommand(rawValue: "rm $HOME/.ssh/config"), context: repo)
        else {
            Issue.record("expected delete for home-alias rm")
            return
        }
        #expect(targets[0].apparent == "$HOME/.ssh/config")
    }

    // MARK: - P10e11 (C-F7): dynamic argv0 fails closed as outside overwrite

    private func segmentActions(_ raw: String) -> [FilesystemAction] {
        parseFilesystemSegments(
            Normalize.matchingView(of: raw).rawValue,
            context: repo,
            assignmentValues: ShellPipeline.collectTopLevelAssignmentValues(
                ShellPipeline.peelStage(raw)
            )
        )
    }

    @Test func dynamicArgv0_failsClosedAsOutsideOverwrite() {
        for raw in ["$(echo git) push", "`echo git` push", "$CMD push"] {
            let actions = segmentActions(raw)
            guard case .overwrite(let targets) = actions.first else {
                Issue.record("expected overwrite for dynamic argv0: \(raw)")
                continue
            }
            #expect(targets.count == 1)
            #expect(targets[0].scope == .outsideRepository)
        }
    }

    @Test func dynamicArgv0_variableCarryoverFailsClosed() {
        // `X=git; $($X) push`: the assignment segment stays inert, every
        // dynamic-argv0 segment fails closed (inner emission may yield
        // more than one fail-closed action; all must be outside).
        let actions = segmentActions("X=git; $($X) push")
        #expect(actions.isEmpty == false)
        for action in actions {
            guard case .overwrite(let targets) = action else {
                Issue.record("expected overwrite for carried dynamic argv0")
                continue
            }
            #expect(targets.allSatisfy { $0.scope == .outsideRepository })
        }
    }

    @Test func staticUnknownVerb_staysUnclaimed() {
        #expect(segmentActions("echo hi").isEmpty)
        #expect(segmentActions("frobnicate a b").isEmpty)
    }

    @Test func homeAliasHead_staysUnclaimed() {
        // `$HOME/bin/tool` expands lexically: not a hidden verb.
        #expect(segmentActions("$HOME/bin/tool args").isEmpty)
    }

    @Test func dynamicVerbWithParseableRedirect_claimsOutside() {
        // M-04: the redirect parse must not launder a dynamic verb.
        guard case .filesystem(.overwrite(let targets)) =
            analyzeFilesystem(ShellCommand(rawValue: "$CMD > Sources/inner.txt"), context: repo)
        else {
            Issue.record("expected overwrite for dynamic verb plus redirect")
            return
        }
        #expect(targets.contains(where: { $0.apparent == "Sources/inner.txt" }))
        #expect(targets.contains(where: {
            $0.apparent == "$CMD" && $0.scope == .outsideRepository
        }))
        let actions = segmentActions("$CMD > Sources/inner.txt")
        #expect(actions.contains(where: {
            $0.targets.contains(where: { $0.scope == .outsideRepository })
        }))
        // Static verbs are untouched: no unioned dynamic target.
        guard case .filesystem(.overwrite(let staticTargets)) =
            analyzeFilesystem(ShellCommand(rawValue: "echo hi > Sources/inner.txt"), context: repo)
        else {
            Issue.record("expected overwrite for static redirect")
            return
        }
        #expect(staticTargets.count == 1)
    }

    @Test func unboundedWriteSentinel_isOutsideWithoutRoot() {
        // M-02: the sentinel is an unbounded write, not the fs root — it
        // must deny even when no repository root is known (unprobed worlds
        // skip the unresolved tighten, so `.unknown` silently allowed).
        let target = classifyFilesystemTarget("/", context: .empty)
        #expect(target.scope == .outsideRepository)
        guard case .filesystem(.overwrite(let targets)) =
            analyzeFilesystem(ShellCommand(rawValue: "tar -x -P -f a.tar"))
        else {
            Issue.record("expected overwrite for absolute-name tar extract")
            return
        }
        #expect(targets.contains(where: { $0.scope == .outsideRepository }))
    }

    @Test func substitutionValueSegment_doesNotFailClosed() {
        // M-24: `X=$(date) cmd` assigns; the VALUE segment is not a command
        // and must not trip C-F7. Its inners still evaluate.
        #expect(segmentActions("X=$(date) echo hi").isEmpty)
        #expect(segmentActions("X=`date` echo hi").isEmpty)
        #expect(segmentActions("X=\"$(date)\" echo hi").isEmpty)
        #expect(segmentActions("A=1 X=$(date) B=2 echo hi").isEmpty)
        let risky = segmentActions("X=$(touch /tmp/evil) echo hi")
        #expect(risky.contains(where: {
            $0.targets.contains(where: {
                $0.apparent == "/tmp/evil" && $0.scope == .outsideRepository
            })
        }))
        // A TYPED standalone substitution still fails closed: its output
        // re-executes as a command.
        let typed = segmentActions("$(echo git) push")
        #expect(typed.contains(where: {
            $0.targets.contains(where: { $0.scope == .outsideRepository })
        }))
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

    /// Pins helpers that move with the AnalyzeFilesystem split. Existing
    /// `analyzeFilesystem` tests cover the composition, not these entry points.
    @Test func lexicalPathAndClassify_pinHomeJoinCollapseAndRepoScope() {
        let home = HomePath(validating: "/isolated-home")
        let cwd = WorkingDirectory(validating: "/isolated-home/project")
        let context = FilesystemAnalysisContext(
            workingDirectory: cwd,
            repositoryRoot: RepositoryRoot(validating: "/isolated-home/project"),
            homeDirectory: home
        )

        #expect(
            lexicalFilesystemPath(
                "~/.ssh/config",
                workingDirectory: cwd,
                homeDirectory: home
            ) == "/isolated-home/.ssh/config"
        )
        #expect(
            lexicalFilesystemPath(
                "$HOME/.ssh/config",
                workingDirectory: cwd,
                homeDirectory: home
            ) == "/isolated-home/.ssh/config"
        )
        #expect(
            lexicalFilesystemPath(
                "../outside-file",
                workingDirectory: cwd,
                homeDirectory: home
            ) == "/isolated-home/outside-file"
        )
        #expect(
            lexicalFilesystemPath(
                "Sources/Foo.swift",
                workingDirectory: cwd,
                homeDirectory: home
            ) == "/isolated-home/project/Sources/Foo.swift"
        )

        let ssh = classifyFilesystemTarget("~/.ssh/config", context: context)
        #expect(ssh.canonical == "/isolated-home/.ssh/config")
        #expect(ssh.scope == .protectedPath(SecretPathMatch(pattern: "home-ssh", category: .ssh)))
        #expect(ssh.resolution == .lexical)

        let source = classifyFilesystemTarget("Sources/Foo.swift", context: context)
        #expect(source.canonical == "/isolated-home/project/Sources/Foo.swift")
        #expect(source.scope == .insideRepository)
        #expect(source.kind == .sourceCode)

        let outside = classifyFilesystemTarget("../outside-file", context: context)
        #expect(outside.canonical == "/isolated-home/outside-file")
        #expect(outside.scope == .outsideRepository)
    }
}
