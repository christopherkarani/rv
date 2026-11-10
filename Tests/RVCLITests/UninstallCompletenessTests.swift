import Foundation
import Testing
import RVDomain
import RVPolicy
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
