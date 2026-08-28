import Testing
import RVDomain

@Suite("FilesystemAction")
struct FilesystemActionTests {
    @Test func generatedAndSourceDeletes_haveDistinctMetadata() {
        let generated = FilesystemTarget(
            apparent: ".build/foo",
            canonical: "/repo/.build/foo",
            scope: .insideRepository,
            kind: .generatedOutput
        )
        let source = FilesystemTarget(
            apparent: "Sources/Foo.swift",
            canonical: "/repo/Sources/Foo.swift",
            scope: .insideRepository,
            kind: .sourceCode
        )
        let deleteGenerated = FilesystemAction.delete(
            targets: [generated],
            recursive: false,
            force: false
        )
        let deleteSource = FilesystemAction.delete(
            targets: [source],
            recursive: false,
            force: false
        )
        #expect(deleteGenerated.resources.resourceKind == .generatedOutput)
        #expect(deleteSource.resources.resourceKind == .sourceCode)
        #expect(deleteGenerated.resources.resourceKind != deleteSource.resources.resourceKind)
        #expect(deleteGenerated.explainKind == "generated output")
        #expect(deleteSource.explainKind == "source code")
        #expect(deleteGenerated.effects.kinds == [.filesystemDelete])
        #expect(deleteSource.effects.kinds == [.filesystemDelete])
    }

    @Test func protectedTarget_addsNonOverridableEffect() {
        let target = FilesystemTarget(
            apparent: "link",
            canonical: "/home/.ssh/id_rsa",
            scope: .protectedPath,
            kind: .unknown,
            followedSymlink: true,
            resolution: .resolved
        )
        let action = FilesystemAction.delete(targets: [target], recursive: false, force: false)
        #expect(action.effects.kinds.contains(.protectedPathMutation))
        #expect(action.explainScope == "protected path")
        let proposed = action.proposedAction(
            command: ShellCommand(rawValue: "rm link"),
            workingDirectory: WorkingDirectory(validating: "/repo")
        )
        #expect(proposed.effects.kinds.contains(.protectedPathMutation))
        #expect(proposed.resources.filesystemScope == .protectedPath)
    }

    @Test func uncertainProtected_doesNotAddExtraDenyEffect() {
        let target = FilesystemTarget(
            apparent: "maybe",
            canonical: "/repo/maybe",
            scope: .protectedPath,
            kind: .unknown,
            resolution: .uncertain
        )
        let action = FilesystemAction.delete(targets: [target], recursive: false, force: false)
        #expect(action.effects.kinds.contains(.protectedPathMutation) == false)
    }
}
