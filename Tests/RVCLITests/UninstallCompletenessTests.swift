import Foundation
import Testing
import RVDomain
import RVIsolation
import RVPolicy
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
            #expect(note.contains("secret-tool clear service rv.secrets"), "\(note)")
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
            environment.runtimeSocketDirectory = runtime

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

/// secrets.json with two values rv stored (`rv.secrets`) and one item rv
/// did not store, plus an mcp.json and an audit log.
private func writeUserData(_ layout: OwnedPaths) throws {
    let config = URL(fileURLWithPath: layout.configDirectory, isDirectory: true)
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
    try touch(layout.configDirectory + "/mcp.json", "{}")
    let audit = layout.configDirectory + "/audit.jsonl"
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
