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
