#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
import RVDomain
import RVIsolation
import RVPolicy
import RVTheme
import Synchronization
@testable import RVCLI

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func touch(_ path: String, _ contents: String = "x") throws {
    try FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
}

private func exists(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
}

/// Launchctl whose bootout records whether rv's binaries were still there.
private final class BinaryWitnessLaunchctl: LaunchctlApplying {
    let rvd: String
    private(set) var rvdPresentAtBootout: [Bool] = []

    init(rvd: String) { self.rvd = rvd }

    func bootstrap(domain _: String, plist _: URL) throws {}

    func bootout(domain _: String, label _: String) throws {
        rvdPresentAtBootout.append(FileManager.default.fileExists(atPath: rvd))
    }
}

@Suite struct UninstallCompletenessTests {
    @Test func removesEverythingInstallShInstallsAndNothingForeign() throws {
        try withTempHome { home, layout, launchctl in
            let bin = layout.localBinDirectory
            for name in InstallManifest.binFiles {
                try touch(bin + "/" + name)
            }
            try touch(bin + "/" + InstallManifest.stagingName("rv"))
            try touch(bin + "/rv_RVPacks.bundle/packs/core.json")
            try touch(bin + "/libFoundation.so")
            try touch(bin + "/libswiftCore.so")
            try touch(bin + "/" + InstallManifest.swiftLibsListName, "libFoundation.so\nlibswiftCore.so\n")
            try touch(layout.approvalsApp + "/Contents/MacOS/rv-mcp-custodian")
            // Foreign neighbours: same dir, never named by install.sh.
            try touch(bin + "/other-tool")
            try touch(bin + "/libforeign.so")
            try touch(home.appendingPathComponent("Applications/Other.app/x").path)

            let outcome = SetupRun.uninstall(env(home: home, launchctl: launchctl))

            #expect(outcome.exitCode == 0, "\(outcome.stderr)")
            for name in InstallManifest.binFiles {
                #expect(exists(bin + "/" + name) == false, "\(name) survived")
            }
            #expect(exists(bin + "/" + InstallManifest.stagingName("rv")) == false)
            #expect(exists(bin + "/rv_RVPacks.bundle") == false)
            #expect(exists(bin + "/libFoundation.so") == false)
            #expect(exists(bin + "/libswiftCore.so") == false)
            #expect(exists(bin + "/" + InstallManifest.swiftLibsListName) == false)
            #expect(exists(layout.approvalsApp) == false)
            #expect(exists(bin + "/other-tool"))
            #expect(exists(bin + "/libforeign.so"))
            #expect(exists(home.appendingPathComponent("Applications/Other.app/x").path))
        }
    }

    @Test func recordedLibraryListCannotNameAPathOutsideTheBinDir() {
        #expect(InstallManifest.isLibraryName("libFoundation.so"))
        #expect(InstallManifest.isLibraryName("libicuuc.so.74"))
        #expect(InstallManifest.isLibraryName("../libx.so") == false)
        #expect(InstallManifest.isLibraryName("/etc/libx.so") == false)
        #expect(InstallManifest.isLibraryName("rv") == false)
        #expect(InstallManifest.isLibraryName("libx.dylib") == false)
    }

    @Test func stopsTheServiceBeforeDeletingBinaries() throws {
        try withTempHome { home, layout, _ in
            try touch(layout.localRvd)
            let launchctl = BinaryWitnessLaunchctl(rvd: layout.localRvd)
            let outcome = SetupRun.uninstall(env(home: home, launchctl: launchctl))
            #expect(outcome.exitCode == 0)
            #expect(launchctl.rvdPresentAtBootout.isEmpty == false)
            #expect(launchctl.rvdPresentAtBootout.allSatisfy { $0 })
            #expect(exists(layout.localRvd) == false)
        }
    }

    @Test func bootoutFailureLeavesTheInstallIntact() throws {
        try withTempHome { home, layout, _ in
            try touch(layout.localRv)
            try touch(layout.localRvd)
            try touch(layout.localBinDirectory + "/rv_RVPacks.bundle/core.json")
            let outcome = SetupRun.uninstall(env(home: home, launchctl: FailingLaunchctl()))
            #expect(outcome.exitCode == EX_UNAVAILABLE)
            #expect(exists(layout.localRv))
            #expect(exists(layout.localRvd))
            #expect(exists(layout.localBinDirectory + "/rv_RVPacks.bundle/core.json"))
        }
    }

    @Test func keepsJudgeWeightsByDefaultAndSaysHowToRemoveThem() throws {
        try withTempHome { home, layout, launchctl in
            try touch(layout.modelsDirectory + "/laya-ft-v2-coreml/weights.bin")
            let outcome = SetupRun.uninstall(env(home: home, launchctl: launchctl))
            #expect(outcome.exitCode == 0)
            #expect(exists(layout.modelsDirectory + "/laya-ft-v2-coreml/weights.bin"))
            #expect(outcome.stderr.contains("kept judge weights at \(layout.modelsDirectory)"))
            #expect(outcome.stderr.contains("rv uninstall --remove-models"))
        }
    }

    @Test func removeModelsDeletesTheWeightsAndTheConfigDir() throws {
        try withTempHome { home, layout, launchctl in
            try touch(layout.modelsDirectory + "/laya-ft-v2-coreml/weights.bin")
            let outcome = SetupRun.uninstall(env(home: home, launchctl: launchctl), removeModels: true)
            #expect(outcome.exitCode == 0)
            #expect(exists(layout.modelsDirectory) == false)
            #expect(exists(layout.configDirectory) == false)
            #expect(outcome.stderr.contains("kept judge weights") == false)
        }
    }

    @Test func removeModelsFlagParses() throws {
        let command = try Uninstall.parse(["--remove-models"])
        #expect(command.removeModels)
        #expect(try Uninstall.parse([]).removeModels == false)
    }

    /// Plain uninstall keeps the user's secrets, MCP state and audit log,
    /// and says what it kept and how to remove it: afterwards no rv binary
    /// is left to do it.
    @Test func plainUninstallNamesWhatItKeptAndHowToRemoveIt() throws {
        try withTempHome { home, layout, launchctl in
            try writeUserData(layout)
            let outcome = SetupRun.uninstall(env(home: home, launchctl: launchctl))
            #expect(outcome.exitCode == 0, "\(outcome.stderr)")
            for name in ["secrets.json", "mcp.json", "audit.jsonl"] {
                #expect(exists(layout.configDirectory + "/" + name), "\(name) was not kept")
            }
            let note = outcome.stderr
            #expect(note.contains(layout.configDirectory), "\(note)")
            for name in ["secrets.json", "mcp.json", "audit.jsonl"] {
                #expect(note.contains(name), "\(name) missing from: \(note)")
            }
            #expect(note.contains("2 secret values"), "\(note)")
            #expect(note.contains(SecretKeychain.storeName), "\(note)")
            #expect(note.contains("GH_TOKEN") && note.contains("NPM_TOKEN"), "\(note)")
            #expect(note.contains("EXT_TOKEN") == false, "an external item is not rv's: \(note)")
            #expect(note.contains("rv uninstall --purge"), "\(note)")
            #expect(note.contains("rm -rf \(layout.configDirectory)"), "\(note)")
            #if canImport(Security)
            #expect(note.contains("security delete-generic-password -s rv.secrets -a GH_TOKEN"), "\(note)")
            #expect(note.contains("security delete-generic-password -s rv.secrets -a NPM_TOKEN"), "\(note)")
            #else
            #expect(note.contains("secret-tool clear service rv.secrets account GH_TOKEN"), "\(note)")
            #expect(note.contains("secret-tool clear service rv.secrets account NPM_TOKEN"), "\(note)")
            #endif
        }
    }

    @Test func purgeDeletesTheValuesRvStoredAndAllOfItsData() throws {
        try withTempHome { home, layout, launchctl in
            try writeUserData(layout)
            try touch(layout.modelsDirectory + "/laya-ft-v2-coreml/weights.bin")
            let logs = home.appendingPathComponent(platformLogDirectory).path
            let cache = home.appendingPathComponent(platformMCPCacheDirectory).path
            let runtime = home.appendingPathComponent("run/user/501/rv").path
            try touch(logs + "/rvd.log")
            try touch(cache + "/server/scratch")
            try touch(runtime + "/evaluate.sock")
            // Outside rv's paths, reached through a symlink in rv's config
            // dir: unlinked, never followed.
            let outside = home.appendingPathComponent("outside/keep.txt").path
            try touch(outside)
            try FileManager.default.createSymbolicLink(
                atPath: layout.configDirectory + "/linked",
                withDestinationPath: home.appendingPathComponent("outside").path)
            let store = RecordingSecretStore()
            var environment = env(home: home, launchctl: launchctl)
            environment.secretKeychain = store.writer
            environment.runtimeSocketDirectories = [runtime]

            let outcome = SetupRun.uninstall(environment, purge: true)

            #expect(outcome.exitCode == 0, "\(outcome.stderr)")
            #expect(outcome.stderr.isEmpty, "\(outcome.stderr)")
            #expect(store.deleted.withLock { $0 }.sorted() == ["rv.secrets/GH_TOKEN", "rv.secrets/NPM_TOKEN"])
            #expect(exists(layout.configDirectory) == false)
            #expect(exists(logs) == false)
            #expect(exists(cache) == false)
            #expect(exists(runtime) == false)
            #expect(exists(outside), "a symlink out of rv's config dir was followed")
        }
    }

    /// An inherited `XDG_RUNTIME_DIR` can name any directory (`$HOME`,
    /// `~/src`): a `rv` there holding more than rvd's socket is the user's,
    /// not rvd's, so purge refuses it and plain uninstall prints no `rm -rf`.
    @Test func uninstallDoesNotRemoveARuntimeDirectoryHoldingMoreThanTheSocket() throws {
        try withTempHome { home, _, launchctl in
            let runtime = home.appendingPathComponent("src/rv").path
            try touch(runtime + "/evaluate.sock")
            try touch(runtime + "/Package.swift")
            var environment = env(home: home, launchctl: launchctl)
            environment.secretKeychain = RecordingSecretStore().writer
            environment.runtimeSocketDirectories = [runtime]

            let plain = SetupRun.uninstall(environment)
            #expect(
                plain.stderr.split(separator: "\n").contains { $0.contains("rm -rf") && $0.contains(runtime) } == false,
                "\(plain.stderr)")
            #expect(exists(runtime + "/Package.swift"))

            let outcome = SetupRun.uninstall(environment, purge: true)

            #expect(outcome.exitCode != 0, "\(outcome.stderr)")
            #expect(exists(runtime + "/Package.swift"), "purge deleted a runtime dir rvd did not fill")
            #expect(outcome.stderr.contains(runtime), "\(outcome.stderr)")
            #expect(outcome.stderr.contains("Package.swift"), "\(outcome.stderr)")
        }
    }

    @Test func purgeNamesASecretValueItCouldNotDeleteAndFails() throws {
        try withTempHome { home, layout, launchctl in
            try writeUserData(layout)
            try touch(layout.localRv)
            try touch(layout.localRvd)
            let state = home.appendingPathComponent(platformLogDirectory + "/rvd.log").path
            try touch(state)
            let store = RecordingSecretStore(failing: ["GH_TOKEN"])
            var environment = env(home: home, launchctl: launchctl)
            environment.secretKeychain = store.writer

            let outcome = SetupRun.uninstall(environment, purge: true)

            #expect(outcome.exitCode != 0)
            #expect(outcome.stderr.contains("could not delete 1 secret value"), "\(outcome.stderr)")
            #expect(outcome.stderr.contains("GH_TOKEN"), "\(outcome.stderr)")
            #expect(outcome.stderr.contains("NPM_TOKEN") == false, "\(outcome.stderr)")
            #expect(store.deleted.withLock { $0 }.sorted() == ["rv.secrets/GH_TOKEN", "rv.secrets/NPM_TOKEN"])
            // The rest still went; secrets.json stays, it names the value.
            #expect(exists(layout.localRv) == false)
            #expect(exists(layout.localRvd) == false)
            #expect(exists(state) == false)
            #expect(exists(layout.configDirectory + "/secrets.json"))
            #expect(exists(layout.configDirectory + "/mcp.json") == false)
            #expect(exists(layout.configDirectory + "/audit.jsonl") == false)
        }
    }

    @Test func purgeFlagParses() throws {
        #expect(try Uninstall.parse(["--purge"]).purge)
        #expect(try Uninstall.parse([]).purge == false)
    }

    /// `ln -sfn ~/src ~/.local/state` must not make purge delete `~/src/rv`.
    @Test func purgeDoesNotFollowASymlinkedParentOfItsDataDirectories() throws {
        try withTempHome { home, _, launchctl in
            let owned = [
                home.appendingPathComponent(platformLogDirectory).path,
                home.appendingPathComponent(platformMCPCacheDirectory).path,
            ]
            var decoys: [String] = []
            for (index, path) in owned.enumerated() {
                let parent = (path as NSString).deletingLastPathComponent
                let decoy = home.appendingPathComponent("decoy-\(index)").path
                let kept = decoy + "/" + (path as NSString).lastPathComponent + "/keep.txt"
                try touch(kept)
                try FileManager.default.createDirectory(
                    atPath: (parent as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(atPath: parent, withDestinationPath: decoy)
                decoys.append(kept)
            }
            var environment = env(home: home, launchctl: launchctl)
            environment.secretKeychain = RecordingSecretStore().writer

            let outcome = SetupRun.uninstall(environment, purge: true)

            #expect(outcome.exitCode != 0, "\(outcome.stderr)")
            for decoy in decoys {
                #expect(exists(decoy), "purge deleted \(decoy) through a symlinked parent")
            }
            for path in owned {
                #expect(outcome.stderr.contains(path), "\(path) not reported: \(outcome.stderr)")
            }
        }
    }

    @Test func purgeDoesNotEnterASymlinkedConfigDirectory() throws {
        try withTempHome { home, layout, launchctl in
            let target = home.appendingPathComponent("elsewhere/rv").path
            try writeUserData(configDirectory: target)
            try touch(target + "/config.json", "{}")
            try FileManager.default.createDirectory(
                atPath: (layout.configDirectory as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: layout.configDirectory, withDestinationPath: target)
            let store = RecordingSecretStore()
            var environment = env(home: home, launchctl: launchctl)
            environment.secretKeychain = store.writer

            let outcome = SetupRun.uninstall(environment, purge: true)

            #expect(outcome.exitCode != 0, "\(outcome.stderr)")
            #expect(store.deleted.withLock { $0 }.isEmpty, "values deleted while their definitions stay behind a link")
            for name in ["secrets.json", "mcp.json", "audit.jsonl", "config.json"] {
                #expect(exists(target + "/" + name), "purge deleted \(name) through the symlinked config dir")
            }
            #expect(outcome.stderr.contains(layout.configDirectory), "\(outcome.stderr)")
            #expect(outcome.stderr.contains(target), "\(outcome.stderr)")
        }
    }

    @Test func purgeWithAnUnreadableSecretsFileDeletesNoValueAndKeepsIt() throws {
        try withTempHome { home, layout, launchctl in
            try touch(layout.configDirectory + "/secrets.json", "not json")
            let store = RecordingSecretStore()
            var environment = env(home: home, launchctl: launchctl)
            environment.secretKeychain = store.writer

            let outcome = SetupRun.uninstall(environment, purge: true)

            #expect(outcome.exitCode != 0, "\(outcome.stderr)")
            #expect(store.deleted.withLock { $0 }.isEmpty)
            #expect(exists(layout.configDirectory + "/secrets.json"))
            #expect(outcome.stderr.contains("secrets.json"), "\(outcome.stderr)")
        }
    }

    /// Only `keychain rv.secrets/<its own name>` is a value rv stored.
    @Test func purgeLeavesAnRvSecretsItemNamedByAnotherAccount() throws {
        try withTempHome { home, layout, launchctl in
            let secrets = SecretsConfiguration(secrets: [
                SecretDefinition(
                    name: "ALIAS", source: .keychain(service: SecretKeychain.service, account: "OTHER"),
                    delivery: .environment),
            ])
            try secrets.write(configDirectory: URL(fileURLWithPath: layout.configDirectory, isDirectory: true)).get()
            let store = RecordingSecretStore()
            var environment = env(home: home, launchctl: launchctl)
            environment.secretKeychain = store.writer

            let outcome = SetupRun.uninstall(environment, purge: true)

            #expect(outcome.exitCode == 0, "\(outcome.stderr)")
            #expect(store.deleted.withLock { $0 }.isEmpty)
        }
    }

    @Test func robotOutputDoesNotClaimCompleteWhenPurgeLeavesAValue() throws {
        try withTempHome { home, layout, launchctl in
            try writeUserData(layout)
            var environment = env(home: home, launchctl: launchctl)
            environment.secretKeychain = RecordingSecretStore(failing: ["GH_TOKEN"]).writer

            let outcome = SetupRun.uninstall(environment, purge: true, appearance: .robot)

            #expect(outcome.exitCode != 0)
            #expect(outcome.stdout.contains("Uninstall complete") == false, "\(outcome.stdout)")
            #expect(outcome.stdout.contains("incomplete"), "\(outcome.stdout)")
        }
    }

    /// An owned path that survives fails the command, and the values purge
    /// could not delete are still named.
    @Test func purgeNamesUndeletedValuesWhenAnOwnedPathSurvives() throws {
        // Root ignores the mode that keeps the file below.
        guard getuid() != 0 else { return }
        try withTempHome { home, layout, launchctl in
            try writeUserData(layout)
            let stuck = layout.modelsDirectory + "/stuck"
            try touch(stuck + "/weights.bin")
            chmod(stuck, 0o500)
            defer { chmod(stuck, 0o700) }
            var environment = env(home: home, launchctl: launchctl)
            environment.secretKeychain = RecordingSecretStore(failing: ["GH_TOKEN"]).writer

            let outcome = SetupRun.uninstall(environment, purge: true)

            #expect(outcome.exitCode == EX_SOFTWARE, "\(outcome.stderr)")
            #expect(outcome.stderr.contains("owned path still exists"), "\(outcome.stderr)")
            #expect(outcome.stderr.contains("GH_TOKEN"), "\(outcome.stderr)")
        }
    }

    /// HOME's spelling (`/home/u/`, `/home//u`) must not make purge refuse
    /// rv's own directories.
    @Test(arguments: [HomeSpelling.trailingSlash, .doubledSlash])
    func purgeAcceptsAnOrdinaryHomeSpelledWithExtraSlashes(_ spelling: HomeSpelling) throws {
        try withTempHome { home, layout, launchctl in
            try writeUserData(layout)
            let logs = home.appendingPathComponent(platformLogDirectory).path
            let cache = home.appendingPathComponent(platformMCPCacheDirectory).path
            try touch(logs + "/rvd.log")
            try touch(cache + "/server/scratch")
            let store = RecordingSecretStore()
            var environment = env(home: home, launchctl: launchctl)
            environment.home = testHomeDirectory(spelling.spell(home))
            environment.secretKeychain = store.writer

            let outcome = SetupRun.uninstall(environment, purge: true)

            #expect(outcome.exitCode == 0, "\(outcome.stderr)")
            #expect(outcome.stderr.isEmpty, "\(outcome.stderr)")
            #expect(store.deleted.withLock { $0 }.sorted() == ["rv.secrets/GH_TOKEN", "rv.secrets/NPM_TOKEN"])
            #expect(exists(layout.configDirectory) == false)
            #expect(exists(logs) == false)
            #expect(exists(cache) == false)
        }
    }

    /// HOME reached through a symlink and spelled with an extra slash: every
    /// target under it, rvd's log dir included, takes the under-HOME rule.
    @Test(arguments: [HomeSpelling.trailingSlash, .doubledSlash])
    func purgeAcceptsALinkedHomeSpelledWithExtraSlashes(_ spelling: HomeSpelling) throws {
        try withTempHome { home, layout, launchctl in
            try writeUserData(layout)
            let logs = home.appendingPathComponent(platformLogDirectory).path
            let cache = home.appendingPathComponent(platformMCPCacheDirectory).path
            try touch(logs + "/rvd.log")
            try touch(cache + "/server/scratch")
            let link = FileManager.default.temporaryDirectory
                .appendingPathComponent("rv-home-link-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: home.path)
            defer { try? FileManager.default.removeItem(atPath: link.path) }
            let store = RecordingSecretStore()
            var environment = env(home: home, launchctl: launchctl)
            environment.home = testHomeDirectory(spelling.spell(link))
            environment.secretKeychain = store.writer

            let outcome = SetupRun.uninstall(environment, purge: true)

            #expect(outcome.exitCode == 0, "\(outcome.stderr)")
            #expect(outcome.stderr.isEmpty, "\(outcome.stderr)")
            #expect(store.deleted.withLock { $0 }.sorted() == ["rv.secrets/GH_TOKEN", "rv.secrets/NPM_TOKEN"])
            #expect(exists(layout.configDirectory) == false)
            #expect(exists(logs) == false)
            #expect(exists(cache) == false)
        }
    }

    #if os(Linux)
    /// Resolved paths compare by bytes: on Linux an NFC and an NFD spelling
    /// of a name are two directories, though Swift's `==` calls them equal.
    @Test func purgeRefusalComparesResolvedPathsByBytes() throws {
        try withTempHome { home, _, _ in
            let root = try #require(realPath(home.path))
            let nfc = root + "/caf\u{E9}"
            let nfd = root + "/cafe\u{301}"
            #expect(mkdir(nfd, 0o700) == 0)
            #expect(mkdir(nfd + "/rv", 0o700) == 0)
            #expect(symlink(nfd, nfc) == 0)

            let refusal = SetupRun.purgeRefusal(nfc + "/rv", home: root, files: FileOps(fileManager: .default))

            #expect(refusal != nil, "a parent resolving to a differently spelled sibling was accepted")
        }
    }
    #endif

    /// A link two levels up (`~/.local` for `~/.local/state/rv`) is refused
    /// too, and the note names where the path really is.
    @Test func purgeDoesNotFollowASymlinkedGrandparentAndNamesWhereItResolves() throws {
        try withTempHome { home, _, launchctl in
            let logs = home.appendingPathComponent(platformLogDirectory).path
            let parent = (logs as NSString).deletingLastPathComponent
            let grandparent = (parent as NSString).deletingLastPathComponent
            let below = (parent as NSString).lastPathComponent + "/" + (logs as NSString).lastPathComponent
            let decoy = home.appendingPathComponent("decoy-grand").path
            try touch(decoy + "/" + below + "/keep.txt")
            try FileManager.default.createSymbolicLink(atPath: grandparent, withDestinationPath: decoy)
            var environment = env(home: home, launchctl: launchctl)
            environment.secretKeychain = RecordingSecretStore().writer

            let outcome = SetupRun.uninstall(environment, purge: true)

            #expect(outcome.exitCode == EX_UNAVAILABLE, "\(outcome.stderr)")
            #expect(exists(decoy + "/" + below + "/keep.txt"))
            #expect(outcome.stderr.contains(logs), "\(outcome.stderr)")
            #expect(outcome.stderr.contains("decoy-grand/" + below), "\(outcome.stderr)")
        }
    }

    /// `~/.config` itself a link: the config dir is not entered and no
    /// value its secrets.json names is deleted.
    @Test func purgeDoesNotEnterAConfigDirUnderASymlinkedDotConfig() throws {
        try withTempHome { home, layout, launchctl in
            let decoy = home.appendingPathComponent("decoy-config").path
            try writeUserData(configDirectory: decoy + "/rv")
            try FileManager.default.createSymbolicLink(
                atPath: (layout.configDirectory as NSString).deletingLastPathComponent, withDestinationPath: decoy)
            let store = RecordingSecretStore()
            var environment = env(home: home, launchctl: launchctl)
            environment.secretKeychain = store.writer

            let outcome = SetupRun.uninstall(environment, purge: true)

            #expect(outcome.exitCode == EX_UNAVAILABLE, "\(outcome.stderr)")
            #expect(store.deleted.withLock { $0 }.isEmpty)
            for name in ["secrets.json", "mcp.json", "audit.jsonl"] {
                #expect(exists(decoy + "/rv/" + name), "purge deleted \(name) under a symlinked ~/.config")
            }
            #expect(outcome.stderr.contains(layout.configDirectory), "\(outcome.stderr)")
            #expect(outcome.stderr.contains("decoy-config/rv"), "\(outcome.stderr)")
        }
    }

    /// Plain uninstall never enters the cache: under a symlinked parent it
    /// is kept, said truthfully, and no by-hand command goes through it.
    @Test func plainUninstallDescribesADirectoryUnderASymlinkAsKept() throws {
        try withTempHome { home, _, launchctl in
            let cache = home.appendingPathComponent(platformMCPCacheDirectory).path
            let parent = (cache as NSString).deletingLastPathComponent
            let decoy = home.appendingPathComponent("decoy-cache").path
            try touch(decoy + "/rv-mcp/server/scratch")
            try FileManager.default.createDirectory(
                atPath: (parent as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: parent, withDestinationPath: decoy)

            let outcome = SetupRun.uninstall(env(home: home, launchctl: launchctl))

            #expect(outcome.exitCode == 0, "\(outcome.stderr)")
            #expect(exists(decoy + "/rv-mcp/server/scratch"))
            #expect(outcome.stderr.contains("not entered") == false, "\(outcome.stderr)")
            #expect(outcome.stderr.contains(cache + ": kept"), "\(outcome.stderr)")
            #expect(outcome.stderr.contains("decoy-cache/rv-mcp"), "\(outcome.stderr)")
            #expect(outcome.stderr.contains("rm -rf " + cache) == false, "\(outcome.stderr)")
            // --purge would refuse it too, so nothing may promise it removes all of it.
            #expect(outcome.stderr.contains("all of it") == false, "\(outcome.stderr)")
        }
    }

    /// `~/.config` a link (dotfiles): --purge would refuse the config dir and
    /// delete none of its values, so plain uninstall must not promise it.
    @Test func plainUninstallDoesNotPromisePurgeRemovesAConfigDirUnderASymlink() throws {
        try withTempHome { home, layout, launchctl in
            let decoy = home.appendingPathComponent("dotfiles-config").path
            try writeUserData(configDirectory: decoy + "/rv")
            try FileManager.default.createSymbolicLink(
                atPath: (layout.configDirectory as NSString).deletingLastPathComponent, withDestinationPath: decoy)

            let outcome = SetupRun.uninstall(env(home: home, launchctl: launchctl))

            #expect(outcome.exitCode == 0, "\(outcome.stderr)")
            #expect(exists(decoy + "/rv/secrets.json"))
            #expect(outcome.stderr.contains("all of it") == false, "\(outcome.stderr)")
            #expect(
                outcome.stderr.contains("not the config directory or its secret values"), "\(outcome.stderr)")
            #expect(outcome.stderr.contains(layout.configDirectory + ": kept"), "\(outcome.stderr)")
            #expect(outcome.stderr.contains("dotfiles-config/rv"), "\(outcome.stderr)")
            #expect(outcome.stderr.contains("rm -rf " + layout.configDirectory) == false, "\(outcome.stderr)")
        }
    }

    @Test func prettyOutputDoesNotClaimCompleteWhenPurgeLeavesAValue() throws {
        try withTempHome { home, layout, launchctl in
            try writeUserData(layout)
            try touch(layout.localRv)
            var environment = env(home: home, launchctl: launchctl)
            environment.secretKeychain = RecordingSecretStore(failing: ["GH_TOKEN"]).writer

            let outcome = SetupRun.uninstall(environment, purge: true, appearance: .pretty(colorOffPalette))

            #expect(outcome.exitCode == EX_UNAVAILABLE)
            #expect(outcome.stdout.contains("Uninstall complete") == false, "\(outcome.stdout)")
            #expect(outcome.stdout.contains("Uninstall incomplete"), "\(outcome.stdout)")
        }
    }

    /// Outside HOME (the runtime socket dir) the parent must resolve to itself.
    @Test func purgeRefusalOutsideHomeAcceptsARealPathAndRefusesALinkedOne() throws {
        try withTempHome { home, _, _ in
            let outside = FileManager.default.temporaryDirectory
                .appendingPathComponent("rv-runtime-\(UUID().uuidString)").path
            defer { try? FileManager.default.removeItem(atPath: outside) }
            try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
            let root = try #require(realPath(outside))
            let files = FileOps(fileManager: .default)
            try FileManager.default.createDirectory(atPath: root + "/user/501/rv", withIntermediateDirectories: true)
            #expect(SetupRun.purgeRefusal(root + "/user/501/rv", home: home.path, files: files) == nil)

            try FileManager.default.createSymbolicLink(atPath: root + "/linked", withDestinationPath: root + "/user")
            let refusal = SetupRun.purgeRefusal(root + "/linked/501/rv", home: home.path, files: files)
            #expect(refusal?.contains(root + "/user/501/rv") == true, "\(refusal ?? "accepted")")

            try FileManager.default.createSymbolicLink(atPath: root + "/user/502", withDestinationPath: root + "/user/501")
            let leaf = SetupRun.purgeRefusal(root + "/user/502", home: home.path, files: files)
            #expect(leaf?.contains("symlink") == true, "\(leaf ?? "accepted")")
        }
    }

    /// macOS keeps `rv mcp connect`'s OAuth tokens in the Keychain under
    /// `rv.mcp.oauth`; each server's lock file in `mcp-oauth/` names one.
    @Test func purgeDeletesTheMCPOAuthTokensRvStoredInTheKeychain() throws {
        try withTempHome { home, layout, launchctl in
            try writeUserData(layout)
            try writeOAuthLocks(layout, servers: ["github", "linear"])
            let store = RecordingSecretStore()
            var environment = env(home: home, launchctl: launchctl)
            environment.secretKeychain = store.writer
            environment.mcpOAuthInKeychain = true

            let outcome = SetupRun.uninstall(environment, purge: true)

            #expect(outcome.exitCode == 0, "\(outcome.stderr)")
            #expect(outcome.stderr.isEmpty, "\(outcome.stderr)")
            #expect(
                store.deleted.withLock { $0 }.sorted() == [
                    "rv.mcp.oauth/github", "rv.mcp.oauth/linear", "rv.secrets/GH_TOKEN", "rv.secrets/NPM_TOKEN",
                ])
            #expect(exists(layout.configDirectory) == false)
        }
    }

    @Test func purgeNamesMCPOAuthTokensItCouldNotDeleteAndFails() throws {
        try withTempHome { home, layout, launchctl in
            try writeOAuthLocks(layout, servers: ["github", "linear"])
            var environment = env(home: home, launchctl: launchctl)
            environment.secretKeychain = RecordingSecretStore(failing: ["github"]).writer
            environment.mcpOAuthInKeychain = true

            let outcome = SetupRun.uninstall(environment, purge: true)

            #expect(outcome.exitCode != 0)
            #expect(outcome.stderr.contains("could not delete 1 MCP server's OAuth tokens"), "\(outcome.stderr)")
            #expect(outcome.stderr.contains("security delete-generic-password -s rv.mcp.oauth -a github"), "\(outcome.stderr)")
            #expect(outcome.stderr.contains("linear") == false, "\(outcome.stderr)")
            // The lock files name the tokens still stored.
            #expect(exists(layout.configDirectory + "/mcp-oauth/.github.lock"))
        }
    }

    @Test func plainUninstallNamesTheMCPOAuthTokensItKept() throws {
        try withTempHome { home, layout, launchctl in
            try writeOAuthLocks(layout, servers: ["github"])
            let store = RecordingSecretStore()
            var environment = env(home: home, launchctl: launchctl)
            environment.secretKeychain = store.writer
            environment.mcpOAuthInKeychain = true

            let outcome = SetupRun.uninstall(environment)

            #expect(outcome.exitCode == 0, "\(outcome.stderr)")
            #expect(store.deleted.withLock { $0 }.isEmpty)
            #expect(outcome.stderr.contains("1 MCP server's OAuth tokens"), "\(outcome.stderr)")
            #expect(outcome.stderr.contains("security delete-generic-password -s rv.mcp.oauth -a github"), "\(outcome.stderr)")
        }
    }

    /// A config dir purge cannot list is left whole: the command must not
    /// report a clean purge.
    @Test(.enabled(if: geteuid() != 0, "root ignores directory modes"))
    func purgeFailsWhenTheConfigDirCannotBeListed() throws {
        try withTempHome { home, layout, launchctl in
            try touch(layout.configDirectory + "/mcp.json", "{}")
            try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: layout.configDirectory)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: layout.configDirectory)
            }
            var environment = env(home: home, launchctl: launchctl)
            environment.secretKeychain = RecordingSecretStore().writer

            let outcome = SetupRun.uninstall(environment, purge: true)

            #expect(outcome.exitCode != 0, "\(outcome.stderr)")
            #expect(outcome.stderr.contains(layout.configDirectory), "\(outcome.stderr)")
        }
    }

    /// The config dir's own removal failing (its parent is read-only) is
    /// reported, not taken for a clean purge.
    @Test(.enabled(if: geteuid() != 0, "root ignores directory modes"))
    func purgeFailsWhenTheConfigDirItselfCannotBeRemoved() throws {
        try withTempHome { home, layout, launchctl in
            try touch(layout.configDirectory + "/mcp.json", "{}")
            let parent = (layout.configDirectory as NSString).deletingLastPathComponent
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent) }
            var environment = env(home: home, launchctl: launchctl)
            environment.secretKeychain = RecordingSecretStore().writer

            let outcome = SetupRun.uninstall(environment, purge: true)

            #expect(outcome.exitCode != 0, "\(outcome.stderr)")
            #expect(exists(layout.configDirectory + "/mcp.json") == false)
            #expect(outcome.stderr.contains(layout.configDirectory), "\(outcome.stderr)")
        }
    }

    @Test func uninstallWithNothingKeptPrintsNoKeptNote() throws {
        try withTempHome { home, layout, launchctl in
            try touch(layout.localRv)
            let outcome = SetupRun.uninstall(env(home: home, launchctl: launchctl))
            #expect(outcome.exitCode == 0, "\(outcome.stderr)")
            #expect(outcome.stderr.isEmpty, "\(outcome.stderr)")
        }
    }
}

/// rvd's log directory and the MCP scratch cache, under HOME.
#if os(macOS)
private let platformLogDirectory = "Library/Logs/rv"
private let platformMCPCacheDirectory = "Library/Caches/rv-mcp"
#else
private let platformLogDirectory = ".local/state/rv"
private let platformMCPCacheDirectory = ".cache/rv-mcp"
#endif

/// HOME as an ordinary path spelled with an extra slash.
enum HomeSpelling: Sendable, CustomTestStringConvertible {
    case trailingSlash
    case doubledSlash

    func spell(_ home: URL) -> String {
        switch self {
        case .trailingSlash:
            return home.path + "/"
        case .doubledSlash:
            return home.deletingLastPathComponent().path + "//" + home.lastPathComponent
        }
    }

    var testDescription: String {
        switch self {
        case .trailingSlash: "trailing slash"
        case .doubledSlash: "doubled slash"
        }
    }
}

/// `realpath(3)`, for expectations on resolved paths.
private func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// Records every delete; fails those for the named accounts.
private final class RecordingSecretStore: Sendable {
    let deleted = Mutex<[String]>([])
    let failing: Set<String>

    init(failing: Set<String> = []) {
        self.failing = failing
    }

    var writer: SecretKeychainWriter {
        SecretKeychainWriter(
            store: { _, _, _ in true },
            delete: { service, account in
                self.deleted.withLock { $0.append("\(service)/\(account)") }
                return self.failing.contains(account) == false
            })
    }
}

/// The lock file `rv mcp connect` holds while it saves each server's tokens.
private func writeOAuthLocks(_ layout: OwnedPaths, servers: [String]) throws {
    for server in servers {
        try touch(layout.configDirectory + "/mcp-oauth/.\(server).lock", "")
    }
}

/// secrets.json with two values rv stored (`rv.secrets`) and one item rv
/// did not store, plus an mcp.json and an audit log.
private func writeUserData(_ layout: OwnedPaths) throws {
    try writeUserData(configDirectory: layout.configDirectory)
}

private func writeUserData(configDirectory: String) throws {
    let config = URL(fileURLWithPath: configDirectory, isDirectory: true)
    let secrets = SecretsConfiguration(secrets: [
        SecretDefinition(
            name: "GH_TOKEN", source: .keychain(service: SecretKeychain.service, account: "GH_TOKEN"),
            delivery: .environment),
        SecretDefinition(
            name: "NPM_TOKEN", source: .keychain(service: SecretKeychain.service, account: "NPM_TOKEN"),
            delivery: .environment),
        SecretDefinition(
            name: "EXT_TOKEN", source: .keychain(service: "corp.tokens", account: "EXT_TOKEN"),
            delivery: .environment),
    ])
    try secrets.write(configDirectory: config).get()
    try touch(configDirectory + "/mcp.json", "{}")
    let audit = configDirectory + "/audit.jsonl"
    if exists(audit) == false {
        try touch(audit, "")
    }
}

/// install.sh is the source of truth for what lands in the bin dir; the
/// manifest must name every file it installs, so uninstall cannot drift.
@Suite struct InstallManifestDriftTests {
    private func installScript() throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent("install.sh"), encoding: .utf8)
    }

    /// Names install.sh writes as `"$bin/<name>"` plus `for helper in a b`
    /// loops that install into `$bin/$helper`.
    private func installedBinNames(_ script: String) throws -> Set<String> {
        var names: Set<String> = []
        let literal = try Regex(#"\$bin/([A-Za-z0-9_.+-]+)"#)
        for match in script.matches(of: literal) {
            guard let name = match.output[1].substring.map(String.init) else { continue }
            // `"$bin/.$helper.installing"` stops at `$`: staging names only.
            if name == "." || name.hasSuffix(".installing") { continue }
            names.insert(name)
        }
        let helpers = try Regex(#"for helper in ([A-Za-z0-9 _.-]+); do"#)
        for match in script.matches(of: helpers) {
            guard let list = match.output[1].substring else { continue }
            names.formUnion(list.split(separator: " ").map(String.init))
        }
        return names
    }

    @Test func manifestNamesEveryFileInstallShPutsInTheBinDir() throws {
        let installed = try installedBinNames(try installScript())
        #expect(installed.contains("rv"), "parser found install.sh's bin writes")
        let owned = Set(InstallManifest.binFiles + InstallManifest.binDirectories + [InstallManifest.swiftLibsListName])
        let missing = installed.subtracting(owned)
        #expect(missing.isEmpty, "install.sh installs \(missing.sorted()) but InstallManifest omits it")
    }

    @Test func installShRecordsTheSwiftLibrariesItCopies() throws {
        let script = try installScript()
        #expect(script.contains(InstallManifest.swiftLibsListName))
    }

    @Test func installShAppsAndBundlesAreOwned() throws {
        let script = try installScript()
        #expect(script.contains("RVApprovals.app"))
        #expect(script.contains("_RVPacks.bundle"))
        #expect(script.contains("$HOME/.config/rv/models"))
    }
}
