import Foundation
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
        let match = SecretPathMatch(pattern: "home-ssh", category: .ssh)
        let target = FilesystemTarget(
            apparent: "link",
            canonical: "/home/.ssh/id_rsa",
            scope: .protectedPath(match),
            kind: .unknown,
            followedSymlink: true,
            resolution: .resolved
        )
        let action = FilesystemAction.delete(targets: [target], recursive: false, force: false)
        #expect(action.effects.kinds.contains(.protectedPathMutation))
        #expect(action.explainScope == "protected path")
        #expect(action.explainCategory == "ssh")
        #expect(action.explainCatalogRule == "core.secrets/home-ssh")
        #expect(action.resources.filesystemScope?.protectedMatch == match)
        #expect(target.protectedMatch == match)
        let proposed = action.proposedAction(
            command: ShellCommand(rawValue: "rm link"),
            workingDirectory: WorkingDirectory(validating: "/repo")
        )
        #expect(proposed.effects.kinds.contains(.protectedPathMutation))
        #expect(proposed.resources.filesystemScope == .protectedPath(match))
        #expect(proposed.resources.filesystemScope?.protectedMatch == match)
    }

    @Test func uncertainProtected_doesNotAddExtraDenyEffect() {
        let target = FilesystemTarget(
            apparent: "maybe",
            canonical: "/repo/maybe",
            scope: .unknown,
            kind: .unknown,
            resolution: .uncertain
        )
        let action = FilesystemAction.delete(targets: [target], recursive: false, force: false)
        #expect(action.effects.kinds.contains(.protectedPathMutation) == false)
        #expect(action.effects.kinds.contains(.unresolvedFilesystem))
        #expect(action.primaryTarget?.scope == .unknown)
        #expect(action.resources.filesystemScope?.protectedMatch == nil)
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

    @Test func primaryTarget_ranksProtectedSourceOverProtectedUnknownRegardlessOfMatchPayload() {
        let sshUnknown = FilesystemTarget(
            apparent: "id_rsa",
            canonical: "/home/.ssh/id_rsa",
            scope: .protectedPath(SecretPathMatch(pattern: "id-rsa", category: .ssh)),
            kind: .unknown
        )
        let cloudSource = FilesystemTarget(
            apparent: "credentials",
            canonical: "/home/.aws/credentials",
            scope: .protectedPath(SecretPathMatch(pattern: "home-aws", category: .cloud)),
            kind: .sourceCode
        )
        let sshFirst = FilesystemAction.delete(
            targets: [sshUnknown, cloudSource],
            recursive: false,
            force: false
        )
        let sourceFirst = FilesystemAction.delete(
            targets: [cloudSource, sshUnknown],
            recursive: false,
            force: false
        )
        #expect(sshFirst.primaryTarget == cloudSource)
        #expect(sourceFirst.primaryTarget == cloudSource)
        #expect(sshFirst.explainKind == "source code")
        #expect(sshFirst.explainCategory == "cloud")
        #expect(sshFirst.explainCatalogRule == "core.secrets/home-aws")
        #expect(sshFirst.resources.resourceKind == .sourceCode)
        #expect(sshFirst.resources.filesystemScope?.protectedMatch?.category == .cloud)
    }

    @Test func actionResources_encodeOmitsProtectedMatchAndDecodeIgnoresLegacyKey() throws {
        let match = SecretPathMatch(pattern: "home-ssh", category: .ssh)
        let target = FilesystemTarget(
            apparent: "link",
            canonical: "/home/.ssh/id_rsa",
            scope: .protectedPath(match),
            kind: .unknown
        )
        let action = FilesystemAction.delete(targets: [target], recursive: false, force: false)
        #expect(action.resources.filesystemScope?.protectedMatch == match)
        let encoded = try JSONEncoder().encode(action.resources)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["protectedMatch"] == nil)

        var legacy = object
        legacy["protectedMatch"] = ["pattern": "home-ssh", "category": "ssh"]
        let decoded = try JSONDecoder().decode(
            ActionResources.self,
            from: try JSONSerialization.data(withJSONObject: legacy)
        )
        #expect(decoded.filesystemScope?.protectedMatch == match)
        #expect(decoded.path == "/home/.ssh/id_rsa")
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
