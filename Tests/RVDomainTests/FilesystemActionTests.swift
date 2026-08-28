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
        #expect(action.explainCategory == nil)
        let labelled = FilesystemTarget(
            apparent: "link",
            canonical: "/home/.ssh/id_rsa",
            scope: .protectedPath,
            kind: .unknown,
            followedSymlink: true,
            resolution: .resolved,
            protectedMatch: SecretPathMatch(pattern: "home-ssh", category: .ssh)
        )
        let labelledAction = FilesystemAction.delete(
            targets: [labelled],
            recursive: false,
            force: false
        )
        #expect(labelledAction.explainCategory == "ssh")
        #expect(labelledAction.explainCatalogRule == "core.secrets/home-ssh")
        #expect(labelledAction.resources.protectedMatch?.pattern == "home-ssh")
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
        #expect(action.effects.kinds.contains(.unresolvedFilesystem))
    }

    @Test func operations_areDistinguished() {
        let inside = FilesystemTarget(
            apparent: "file",
            canonical: "/repo/file",
            scope: .insideRepository,
            kind: .unknown
        )
        #expect(FilesystemAction.read(targets: [inside]).operationKind == .read)
        #expect(FilesystemAction.overwrite(targets: [inside]).operationKind == .write)
        #expect(FilesystemAction.create(targets: [inside]).operationKind == .create)
        #expect(
            FilesystemAction.move(sources: [inside], destination: inside).operationKind == .move
        )
        #expect(
            FilesystemAction.delete(targets: [inside], recursive: false, force: false).operationKind
                == .delete
        )
        #expect(FilesystemAction.create(targets: [inside]).effects.kinds == [.filesystemCreate])
        #expect(FilesystemAction.read(targets: [inside]).effects.kinds == [.filesystemRead])
    }

    @Test func unknownTarget_outranksInsideForFailClosed() {
        let inside = FilesystemTarget(
            apparent: "ok",
            canonical: "/repo/ok",
            scope: .insideRepository,
            kind: .unknown
        )
        let unknown = FilesystemTarget(
            apparent: "gone",
            canonical: "/gone",
            scope: .unknown,
            kind: .unknown,
            resolution: .uncertain
        )
        let action = FilesystemAction.delete(
            targets: [inside, unknown],
            recursive: false,
            force: false
        )
        #expect(action.primaryTarget?.scope == .unknown)
        #expect(action.effects.kinds.contains(.unresolvedFilesystem))
        #expect(action.resources.filesystemScope == .unknown)
    }

    @Test func outsideWrite_addsIndependentEffect() {
        let target = FilesystemTarget(
            apparent: "../outside-file",
            canonical: "/tmp/outside-file",
            scope: .outsideRepository,
            kind: .unknown
        )
        let action = FilesystemAction.overwrite(targets: [target])
        #expect(action.effects.kinds.contains(.outsideRepositoryMutation))
        #expect(action.effects.kinds.contains(.filesystemOverwrite))
        #expect(
            FilesystemAction.read(targets: [target]).effects.kinds
                .contains(.outsideRepositoryMutation) == false
        )
    }
}
