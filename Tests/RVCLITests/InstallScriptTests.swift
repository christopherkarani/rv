import Foundation
import Testing
@testable import RVCLI

private func repoRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func installScriptURL() -> URL {
    repoRootURL().appendingPathComponent("install.sh")
}

@Test func installSh_linuxStagesRequiredIsolationHelper() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rv-helper-install-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let src = root.appendingPathComponent("src")
    try writeDummyTrio(in: src)
    let helper = "#!/bin/sh\n# isolation-helper-fixture\nexit 125\n"
    try writeExecutable(src.appendingPathComponent("rv-isolation-exec"), contents: helper)
    let shim = root.appendingPathComponent("shim")
    try writeLinuxShims(in: shim)
    let home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let result = try runInstallScript(home: home, src: src, pathPrefix: shim.path)
    #expect(result.status == 0)
    let installed = home.appendingPathComponent(".local/bin/rv-isolation-exec")
    #expect(FileManager.default.isExecutableFile(atPath: installed.path))
    #expect(try String(contentsOf: installed, encoding: .utf8) == helper)
}

@Test func installSh_linuxMissingIsolationHelperPreservesPreviousInstall() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rv-helper-missing-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let src = root.appendingPathComponent("src")
    try writeDummyTrio(in: src)
    let sourceHelper = src.appendingPathComponent("rv-isolation-exec")
    if FileManager.default.fileExists(atPath: sourceHelper.path) { try FileManager.default.removeItem(at: sourceHelper) }
    let shim = root.appendingPathComponent("shim")
    try writeLinuxShims(in: shim)
    let home = root.appendingPathComponent("home")
    let previous = home.appendingPathComponent(".local/bin/rv")
    try writeExecutable(previous, contents: "#!/bin/sh\n# previous-install\nexit 0\n")
    let result = try runInstallScript(home: home, src: src, pathPrefix: shim.path)
    #expect(result.status != 0)
    #expect(try String(contentsOf: previous, encoding: .utf8).contains("previous-install"))
}

@Test func installSh_stagesSwiftCompatibilityRuntimeBesideCLI() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-span-install-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let src = root.appendingPathComponent("src")
    try writeDummyTrio(in: src)
    let runtime = "swift compatibility runtime fixture\n"
    try writeExecutable(src.appendingPathComponent("libswiftCompatibilitySpan.dylib"), contents: runtime)
    let shim = root.appendingPathComponent("shim")
    try writeDarwinShims(in: shim)
    let home = root.appendingPathComponent("home")

    let result = try runInstallScript(home: home, src: src, pathPrefix: shim.path)

    #expect(result.status == 0)
    #expect(
        try String(
            contentsOf: home.appendingPathComponent(".local/bin/libswiftCompatibilitySpan.dylib"),
            encoding: .utf8
        ) == runtime
    )
}

private func writeExecutable(_ url: URL, contents: String) throws {
    try writeExecutableScript(at: url, source: contents)
}

private func writeLinuxShims(in shim: URL, arch: String = "x86_64") throws {
    try FileManager.default.createDirectory(at: shim, withIntermediateDirectories: true)
    try writeExecutable(
        shim.appendingPathComponent("uname"),
        contents: """
        #!/bin/sh
        if [ "$1" = "-s" ]; then echo Linux; exit 0; fi
        if [ "$1" = "-m" ]; then echo \(arch); exit 0; fi
        echo Linux
        """
    )
}

private func writeDarwinShims(in shim: URL, productVersion: String = "26.0") throws {
    try FileManager.default.createDirectory(at: shim, withIntermediateDirectories: true)
    try writeExecutable(
        shim.appendingPathComponent("uname"),
        contents: """
        #!/bin/sh
        if [ "$1" = "-s" ]; then echo Darwin; exit 0; fi
        if [ "$1" = "-m" ]; then echo arm64; exit 0; fi
        echo Darwin
        """
    )
    try writeExecutable(
        shim.appendingPathComponent("sw_vers"),
        contents: """
        #!/bin/sh
        if [ "$1" = "-productVersion" ]; then echo \(productVersion); exit 0; fi
        echo \(productVersion)
        """
    )
}

private func writeDummyTrio(in src: URL) throws {
    let dummy = "#!/bin/sh\n# installed-dummy\nexit 0\n"
    for name in ["rv", "rv-cli", "rvd", "rv-workspace-host", "rv-isolation-exec"] {
        try writeExecutable(src.appendingPathComponent(name), contents: dummy)
    }
}

private func findSwiftRVExecutable() -> URL? {
    if let override = ProcessInfo.processInfo.environment["RV_SWIFT_RV"] {
        let url = URL(fileURLWithPath: override)
        if FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
    }
    let build = repoRootURL().appendingPathComponent(".build")
    let names = [
        "debug/rv",
        "x86_64-unknown-linux-gnu/debug/rv",
        "aarch64-unknown-linux-gnu/debug/rv",
        "arm64-apple-macosx/debug/rv",
    ]
    for name in names {
        let candidate = build.appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}

/// C-hook shaped `rv` plus Swift `rv-cli`. Dummy `rv` that exits 0 hides setup.
private func writeLinuxSetupTrio(in src: URL, swiftRV: URL) throws {
    try writeExecutable(
        src.appendingPathComponent("rv-isolation-exec"),
        contents: "#!/bin/sh\n# install-fixture-only\nexit 125\n"
    )
    try writeExecutable(
        src.appendingPathComponent("rv"),
        contents: """
        #!/bin/sh
        exec "$(dirname "$0")/rv-cli" "$@"
        """
    )
    let destCli = src.appendingPathComponent("rv-cli")
    try FileManager.default.copyItem(at: swiftRV, to: destCli)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destCli.path)
    try writeExecutable(
        src.appendingPathComponent("rvd"),
        contents: "#!/bin/sh\n# dummy-rvd\nexit 0\n"
    )
    try writeExecutable(
        src.appendingPathComponent("rv-workspace-host"),
        contents: "#!/bin/sh\n# dummy-workspace-host\nexit 0\n"
    )
}

private func runInstallScript(
    home: URL,
    src: URL,
    pathPrefix: String
) throws -> (status: Int32, stderr: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [installScriptURL().path]
    process.environment = [
        "HOME": home.path,
        "PATH": pathPrefix + ":/usr/bin:/bin",
        "RV_INSTALL_BIN": src.path,
    ]
    let stderr = Pipe()
    process.standardError = stderr
    process.standardOutput = Pipe()
    try process.run()
    process.waitUntilExit()
    let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (process.terminationStatus, err)
}

@Test func installSh_doesNotMentionBrew() throws {
    let text = try String(contentsOf: installScriptURL(), encoding: .utf8)
    #expect(text.localizedCaseInsensitiveContains("brew") == false)
}

@Test func installSh_setsRVFromInstallBeforeSetup() throws {
    let text = try String(contentsOf: installScriptURL(), encoding: .utf8)
    #expect(text.contains("RV_FROM_INSTALL=1 exec \"$bin/rv\" setup"))
    #expect(text.contains("exec \"$bin/rv-cli\" setup") == false)
    #expect(text.contains("launchctl") == false)
    #expect(text.contains("LaunchAgent") == false)
}

@Test func readme_hasNoBrewInstallPath() throws {
    let text = try String(
        contentsOf: repoRootURL().appendingPathComponent("README.md"),
        encoding: .utf8
    )
    #expect(text.localizedCaseInsensitiveContains("brew") == false)
}

@Test func readme_scanCommandIsScanNotScn() throws {
    let text = try String(
        contentsOf: repoRootURL().appendingPathComponent("README.md"),
        encoding: .utf8
    )
    #expect(text.contains("rv scn") == false)
    #expect(text.contains("rv scan"))
    #expect(text.localizedCaseInsensitiveContains("scan repo") == false)
}

@Test func installSh_refusesWindows() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-install-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let home = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    // Required binaries, including rv-workspace-host, are present. Windows is
    // still refused; the test must not stop on the missing-binary check.
    let src = root.appendingPathComponent("src", isDirectory: true)
    try writeDummyTrio(in: src)

    let shim = root.appendingPathComponent("shim", isDirectory: true)
    try writeExecutable(
        shim.appendingPathComponent("uname"),
        contents: """
        #!/bin/sh
        if [ "$1" = "-s" ]; then echo Windows_NT; exit 0; fi
        if [ "$1" = "-m" ]; then echo x86_64; exit 0; fi
        echo Windows_NT
        """
    )

    let result = try runInstallScript(home: home, src: src, pathPrefix: shim.path)
    #expect(result.status == 1)
    #expect(result.stderr.contains("macOS 15 Apple Silicon, or Linux aarch64/x86_64"))
    #expect(result.stderr.localizedCaseInsensitiveContains("windows") == false)
    #expect(FileManager.default.fileExists(atPath: home.path + "/.local/bin/rv") == false)
}

@Test(arguments: ["15.0", "15.6", "26.0", "26.1", "27.0"])
func installSh_acceptsDarwinMacOS15OrNewer(_ productVersion: String) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-install-darwin-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let home = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let src = root.appendingPathComponent("src", isDirectory: true)
    try writeDummyTrio(in: src)

    let shim = root.appendingPathComponent("shim", isDirectory: true)
    try writeDarwinShims(in: shim, productVersion: productVersion)

    let result = try runInstallScript(home: home, src: src, pathPrefix: shim.path)
    #expect(result.status == 0)
    #expect(
        FileManager.default.isExecutableFile(
            atPath: home.appendingPathComponent(".local/bin/rv").path
        )
    )
}

@Test(arguments: ["14.6", "14.0", ""])
func installSh_refusesOlderMacOS(_ productVersion: String) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-install-oldmac-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let home = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let src = root.appendingPathComponent("src", isDirectory: true)
    try writeDummyTrio(in: src)

    let shim = root.appendingPathComponent("shim", isDirectory: true)
    try writeDarwinShims(in: shim, productVersion: productVersion)

    let result = try runInstallScript(home: home, src: src, pathPrefix: shim.path)
    #expect(result.status == 1)
    #expect(result.stderr.contains("macOS 15 Apple Silicon, or Linux aarch64/x86_64"))
    #expect(FileManager.default.fileExists(atPath: home.path + "/.local/bin/rv") == false)
}

@Test func installSh_acceptsLinuxX86_64() throws {
    try proveLinuxInstall(arch: "x86_64")
}

@Test func installSh_acceptsLinuxAarch64() throws {
    try proveLinuxInstall(arch: "aarch64")
}

@Test func installSh_copiesLinuxResourcesDirectory() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-install-linux-resources-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let home = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let src = root.appendingPathComponent("src", isDirectory: true)
    try writeDummyTrio(in: src)
    let resourcePack = src.appendingPathComponent("rv_RVPacks.resources/packs/core.git.json")
    try FileManager.default.createDirectory(
        at: resourcePack.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try "{}\n".write(to: resourcePack, atomically: true, encoding: .utf8)

    let shim = root.appendingPathComponent("shim", isDirectory: true)
    try writeLinuxShims(in: shim, arch: "x86_64")

    let result = try runInstallScript(home: home, src: src, pathPrefix: shim.path)
    #expect(result.status == 0)
    #expect(
        FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".local/bin/rv_RVPacks.resources/packs/core.git.json").path
        )
    )
    #expect(
        isDirectory(home.appendingPathComponent(".local/bin/rv_RVPacks.bundle")) == false
    )
}

private func proveLinuxInstall(arch: String) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-install-linux-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let home = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let src = root.appendingPathComponent("src", isDirectory: true)
#if os(Linux)
    let swiftRV = try #require(findSwiftRVExecutable(), "Swift rv product must be on the Linux graph")
    try writeLinuxSetupTrio(in: src, swiftRV: swiftRV)
#else
    try writeDummyTrio(in: src)
#endif

    let shim = root.appendingPathComponent("shim", isDirectory: true)
    try writeLinuxShims(in: shim, arch: arch)

    let result = try runInstallScript(home: home, src: src, pathPrefix: shim.path)
    #expect(result.status == 0)

    let destBin = home.appendingPathComponent(".local/bin")
    #expect(FileManager.default.isExecutableFile(atPath: destBin.appendingPathComponent("rv").path))
    #expect(FileManager.default.isExecutableFile(atPath: destBin.appendingPathComponent("rv-cli").path))
    #expect(FileManager.default.isExecutableFile(atPath: destBin.appendingPathComponent("rvd").path))
#if os(Linux)
    let launchdPlist = home.appendingPathComponent("Library/LaunchAgents/dev.rv.evaluate.plist")
    let systemdUnit = home.appendingPathComponent(".config/systemd/user/dev.rv.evaluate.service")
    #expect(FileManager.default.fileExists(atPath: launchdPlist.path) == false)
    #expect(FileManager.default.fileExists(atPath: systemdUnit.path))
    let unit = try String(contentsOf: systemdUnit, encoding: .utf8)
    #expect(unit.contains("Restart=no"))
    #expect(unit.contains("Restart=always") == false)
    #expect(unit.contains("--socket"))
    #expect(unit.contains(destBin.appendingPathComponent("rvd").path))
#endif
}

@Test func installSh_replacesDestSymlinkWithoutFollowing() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-install-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let home = root.appendingPathComponent("home", isDirectory: true)
    let destBin = home.appendingPathComponent(".local/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: destBin, withIntermediateDirectories: true)

    let victim = root.appendingPathComponent("outside-victim")
    let victimBytes = Data("do-not-overwrite\n".utf8)
    try victimBytes.write(to: victim)

    let destRv = destBin.appendingPathComponent("rv")
    try FileManager.default.createSymbolicLink(
        atPath: destRv.path,
        withDestinationPath: victim.path
    )

    let src = root.appendingPathComponent("src", isDirectory: true)
    try writeDummyTrio(in: src)

    let shim = root.appendingPathComponent("shim", isDirectory: true)
    try writeDarwinShims(in: shim)

    let result = try runInstallScript(home: home, src: src, pathPrefix: shim.path)

    #expect(result.status == 0)
    let destType = try FileManager.default.attributesOfItem(atPath: destRv.path)[.type] as? FileAttributeType
    #expect(destType == .typeRegular)
    let destBody = try String(contentsOf: destRv, encoding: .utf8)
    #expect(destBody.contains("installed-dummy"))
    #expect(try Data(contentsOf: victim) == victimBytes)
}

@Test func installSh_failsWhenRvCliIsMissing() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-install-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let home = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let src = root.appendingPathComponent("src", isDirectory: true)
    let dummy = "#!/bin/sh\nexit 0\n"
    try writeExecutable(src.appendingPathComponent("rv"), contents: dummy)
    try writeExecutable(src.appendingPathComponent("rvd"), contents: dummy)
    try writeExecutable(src.appendingPathComponent("rv-workspace-host"), contents: dummy)

    let shim = root.appendingPathComponent("shim", isDirectory: true)
    try writeDarwinShims(in: shim)

    let result = try runInstallScript(home: home, src: src, pathPrefix: shim.path)
    #expect(result.status == 1)
    #expect(result.stderr.contains("rv-cli"))
    #expect(FileManager.default.fileExists(atPath: home.path + "/.local/bin/rv") == false)
    #expect(FileManager.default.fileExists(atPath: home.path + "/.local/bin/rv-cli") == false)
}

@Test func installSh_failsWhenRvCliIsNotExecutable() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-install-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let home = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let src = root.appendingPathComponent("src", isDirectory: true)
    let dummy = "#!/bin/sh\nexit 0\n"
    try writeExecutable(src.appendingPathComponent("rv"), contents: dummy)
    try writeExecutable(src.appendingPathComponent("rvd"), contents: dummy)
    try writeExecutable(src.appendingPathComponent("rv-workspace-host"), contents: dummy)
    let cli = src.appendingPathComponent("rv-cli")
    try dummy.write(to: cli, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cli.path)

    let shim = root.appendingPathComponent("shim", isDirectory: true)
    try writeDarwinShims(in: shim)

    let result = try runInstallScript(home: home, src: src, pathPrefix: shim.path)
    #expect(result.status == 1)
    #expect(result.stderr.contains("rv-cli"))
    #expect(FileManager.default.fileExists(atPath: home.path + "/.local/bin/rv-cli") == false)
}

@Test func installSh_copiesTrioAndPackBundlesThenExecsRvSetup() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-install-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let home = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let src = root.appendingPathComponent("src", isDirectory: true)
    try writeExecutable(
        src.appendingPathComponent("rv"),
        contents: """
        #!/bin/sh
        # dummy-rv
        printf 'rv-ran\\n' > "$HOME/.rv-ran"
        exec "$(dirname "$0")/rv-cli" "$@"
        """
    )
    try writeExecutable(
        src.appendingPathComponent("rv-cli"),
        contents: """
        #!/bin/sh
        # dummy-rv-cli
        printf 'from_install=%s argv=%s\\n' "${RV_FROM_INSTALL-}" "$*" > "$HOME/.rv-setup-marker"
        exit 0
        """
    )
    try writeExecutable(
        src.appendingPathComponent("rvd"),
        contents: "#!/bin/sh\n# dummy-rvd\nexit 0\n"
    )
    try writeExecutable(
        src.appendingPathComponent("rv-workspace-host"),
        contents: "#!/bin/sh\n# dummy-workspace-host\nexit 0\n"
    )
    let bundlePack = src.appendingPathComponent("rv_RVPacks.bundle/packs/core.json")
    try FileManager.default.createDirectory(
        at: bundlePack.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try "{}\n".write(to: bundlePack, atomically: true, encoding: .utf8)

    let shim = root.appendingPathComponent("shim", isDirectory: true)
    try writeDarwinShims(in: shim)

    let result = try runInstallScript(home: home, src: src, pathPrefix: shim.path)
    #expect(result.status == 0)

    let destBin = home.appendingPathComponent(".local/bin")
    let destRv = destBin.appendingPathComponent("rv")
    let destCli = destBin.appendingPathComponent("rv-cli")
    let destRvd = destBin.appendingPathComponent("rvd")
    #expect(FileManager.default.isExecutableFile(atPath: destRv.path))
    #expect(FileManager.default.isExecutableFile(atPath: destCli.path))
    #expect(FileManager.default.isExecutableFile(atPath: destRvd.path))
    #expect(try String(contentsOf: destRv, encoding: .utf8).contains("dummy-rv"))
    #expect(try String(contentsOf: destCli, encoding: .utf8).contains("dummy-rv-cli"))
    #expect(
        FileManager.default.fileExists(
            atPath: destBin.appendingPathComponent("rv_RVPacks.bundle/packs/core.json").path
        )
    )

    let ran = try String(contentsOfFile: home.path + "/.rv-ran", encoding: .utf8)
    let marker = try String(contentsOfFile: home.path + "/.rv-setup-marker", encoding: .utf8)
    #expect(ran.contains("rv-ran"))
    #expect(marker.contains("from_install=1"))
    #expect(marker.contains("setup"))
}

@Test func installSh_copyFailureLeavesPreviousInstallIntact() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-install-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let home = root.appendingPathComponent("home", isDirectory: true)
    let destBin = home.appendingPathComponent(".local/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: destBin, withIntermediateDirectories: true)
    let previous = "#!/bin/sh\n# installed-v1\n"
    for name in ["rv", "rv-cli", "rvd"] {
        try writeExecutable(destBin.appendingPathComponent(name), contents: previous)
    }

    let src = root.appendingPathComponent("src", isDirectory: true)
    let dummy = "#!/bin/sh\nexit 0\n"
    try writeExecutable(src.appendingPathComponent("rv"), contents: dummy)
    try writeExecutable(src.appendingPathComponent("rv-cli"), contents: dummy)
    // Owner-exec without owner-read: passes the `-x` precheck, fails `cp`.
    let brokenRvd = src.appendingPathComponent("rvd")
    try dummy.write(to: brokenRvd, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o100], ofItemAtPath: brokenRvd.path)

    let shim = root.appendingPathComponent("shim", isDirectory: true)
    try writeDarwinShims(in: shim)

    let result = try runInstallScript(home: home, src: src, pathPrefix: shim.path)
    #expect(result.status != 0)

    for name in ["rv", "rv-cli", "rvd"] {
        let dest = destBin.appendingPathComponent(name)
        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect(try String(contentsOf: dest, encoding: .utf8).contains("installed-v1"))
    }
    for leftover in [".rv.installing", ".rv-cli.installing", ".rvd.installing"] {
        #expect(FileManager.default.fileExists(atPath: destBin.appendingPathComponent(leftover).path) == false)
    }
}

@Test func installSh_setupBakesLocalRvHookNotRvCli() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-install-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let home = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let src = root.appendingPathComponent("src", isDirectory: true)
    try writeDummyTrio(in: src)

    let shim = root.appendingPathComponent("shim", isDirectory: true)
    try writeDarwinShims(in: shim)

    let result = try runInstallScript(home: home, src: src, pathPrefix: shim.path)
    #expect(result.status == 0)

    try FileManager.default.createDirectory(
        at: home.appendingPathComponent(".grok"),
        withIntermediateDirectories: true
    )
    let destBin = home.appendingPathComponent(".local/bin")
    let rvPath = destBin.appendingPathComponent("rv").path
    let launchctl = RecordingLaunchctl()
    let outcome = SetupRun.setup(
        env(
            home: home,
            launchctl: launchctl,
            rvPath: rvPath,
            rvdPath: destBin.appendingPathComponent("rvd").path,
            touchLaunchd: false
        )
    )
    #expect(outcome.exitCode == 0)
    let grok = try String(
        contentsOfFile: home.path + "/.grok/hooks/rv.json",
        encoding: .utf8
    )
    #expect(grok.contains("\(rvPath) hook --host grok"))
    #expect(grok.contains("rv-cli") == false)
}

@Test func installSh_fetchesGitHubLatestWhenInstallBinUnset() throws {
    let text = try String(contentsOf: installScriptURL(), encoding: .utf8)
    #expect(text.contains("https://github.com/christopherkarani/rv/releases/latest/download"))
    #expect(text.contains("rv_RVPacks.bundle.tar.gz"))
    #expect(text.contains("tar -xzf"))
    #expect(text.contains("curl -fsSL"))
    #expect(text.contains("Downloading"))
    #expect(text.contains("━"))
    #expect(text.contains("─"))
    #expect(text.contains("progress_width=24"))
    #expect(text.contains("RV_INSTALL_FORCE_PROGRESS") || text.contains("progress_fd"))
    #expect(text.contains("Download complete"))
    #expect(text.contains("run rv-cli") == false)
    // Tarball URL contains this prefix; strip it so a directory-asset fetch still fails.
    let withoutTarball = text.replacingOccurrences(
        of: "$release_base/rv_RVPacks.bundle.tar.gz",
        with: ""
    )
    #expect(withoutTarball.contains("$release_base/rv_RVPacks.bundle") == false)
}

private func writePackBundleTarball(in assets: URL) throws {
    let bundleDir = assets.appendingPathComponent("rv_RVPacks.bundle", isDirectory: true)
    let bundlePack = bundleDir.appendingPathComponent("packs/core.json")
    try FileManager.default.createDirectory(
        at: bundlePack.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try "{}\n".write(to: bundlePack, atomically: true, encoding: .utf8)

    let tarball = assets.appendingPathComponent("rv_RVPacks.bundle.tar.gz")
    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tar.arguments = ["-czf", tarball.path, "rv_RVPacks.bundle"]
    tar.currentDirectoryURL = assets
    tar.standardOutput = Pipe()
    tar.standardError = Pipe()
    try tar.run()
    tar.waitUntilExit()
    guard tar.terminationStatus == 0 else {
        struct TarFailed: Error {}
        throw TarFailed()
    }
    // GitHub serves a tarball file, not a directory asset.
    try FileManager.default.removeItem(at: bundleDir)
}

private func isDirectory(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
}

private func writeCurlShim(
    in shim: URL,
    assets: URL,
    failAll: Bool = false
) throws {
    try writeExecutable(
        shim.appendingPathComponent("curl"),
        contents: """
        #!/bin/sh
        if [ "\(failAll ? "1" : "0")" = "1" ]; then
          echo "curl: (22) The requested URL returned error: 404" >&2
          exit 22
        fi
        out=""
        url=""
        head=0
        while [ $# -gt 0 ]; do
          case "$1" in
            -o)
              out="$2"
              shift 2
              ;;
            -I|--head|-*I*)
              head=1
              shift
              ;;
            -*)
              shift
              ;;
            *)
              url="$1"
              shift
              ;;
          esac
        done
        name="${url##*/}"
        src="\(assets.path)/$name"
        if [ ! -f "$src" ]; then
          echo "curl: (22) The requested URL returned error: 404" >&2
          exit 22
        fi
        if [ "$head" = "1" ]; then
          size="$(wc -c < "$src" | tr -d ' \\n')"
          printf 'HTTP/1.1 200 OK\\r\\nContent-Length: %s\\r\\n\\r\\n' "$size"
          exit 0
        fi
        if [ -z "$out" ]; then
          echo "curl: (22) The requested URL returned error: 404" >&2
          exit 22
        fi
        cp "$src" "$out"
        exit 0
        """
    )
}

@Test func installSh_downloadsReleaseTrioWhenInstallBinUnset() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-install-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let home = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let assets = root.appendingPathComponent("assets", isDirectory: true)
    try writeExecutable(
        assets.appendingPathComponent("rv"),
        contents: """
        #!/bin/sh
        printf 'rv-ran\\n' > "$HOME/.rv-ran"
        exec "$(dirname "$0")/rv-cli" "$@"
        """
    )
    try writeExecutable(
        assets.appendingPathComponent("rv-cli"),
        contents: """
        #!/bin/sh
        printf 'from_install=%s argv=%s\\n' "${RV_FROM_INSTALL-}" "$*" > "$HOME/.rv-setup-marker"
        exit 0
        """
    )
    try writeExecutable(
        assets.appendingPathComponent("rvd"),
        contents: "#!/bin/sh\nexit 0\n"
    )
    try writeExecutable(
        assets.appendingPathComponent("rv-workspace-host"),
        contents: "#!/bin/sh\nexit 0\n"
    )
    try writePackBundleTarball(in: assets)
    #expect(FileManager.default.fileExists(atPath: assets.appendingPathComponent("rv_RVPacks.bundle.tar.gz").path))
    #expect(isDirectory(assets.appendingPathComponent("rv_RVPacks.bundle")) == false)

    let shim = root.appendingPathComponent("shim", isDirectory: true)
    try writeDarwinShims(in: shim)
    try writeCurlShim(in: shim, assets: assets)
    try writeSignatureShims(in: shim)

    let (status, stderr) = try runInstallScript(
        script: installScriptURL(),
        environment: [
            "HOME": home.path,
            "PATH": shim.path + ":/usr/bin:/bin",
            "RV_TEST_CODESIGN": "unsigned",
            "TAR_OPTIONS": "--no-same-owner",
        ],
        systemCodesignShim: shim
    )
    #expect(status == 0, "\(stderr)")

    let destBin = home.appendingPathComponent(".local/bin")
    #expect(FileManager.default.isExecutableFile(atPath: destBin.appendingPathComponent("rv").path))
    #expect(FileManager.default.isExecutableFile(atPath: destBin.appendingPathComponent("rv-cli").path))
    #expect(FileManager.default.isExecutableFile(atPath: destBin.appendingPathComponent("rvd").path))
    let destBundle = destBin.appendingPathComponent("rv_RVPacks.bundle")
    // Fetch only saw a tarball file; dest directory means extract made
    // $src/rv_RVPacks.bundle a directory so the [ -d ] stage ran.
    #expect(isDirectory(destBundle))
    #expect(
        FileManager.default.fileExists(
            atPath: destBundle.appendingPathComponent("packs/core.json").path
        )
    )
    let marker = try String(contentsOfFile: home.path + "/.rv-setup-marker", encoding: .utf8)
    #expect(marker.contains("from_install=1"))
    #expect(marker.contains("setup"))
}

@Test func installSh_missingPackTarballStillInstallsTrio() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-install-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let home = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let assets = root.appendingPathComponent("assets", isDirectory: true)
    try writeExecutable(
        assets.appendingPathComponent("rv"),
        contents: """
        #!/bin/sh
        exec "$(dirname "$0")/rv-cli" "$@"
        """
    )
    try writeExecutable(
        assets.appendingPathComponent("rv-cli"),
        contents: """
        #!/bin/sh
        printf 'from_install=%s argv=%s\\n' "${RV_FROM_INSTALL-}" "$*" > "$HOME/.rv-setup-marker"
        exit 0
        """
    )
    try writeExecutable(
        assets.appendingPathComponent("rvd"),
        contents: "#!/bin/sh\nexit 0\n"
    )
    try writeExecutable(
        assets.appendingPathComponent("rv-workspace-host"),
        contents: "#!/bin/sh\nexit 0\n"
    )

    let shim = root.appendingPathComponent("shim", isDirectory: true)
    try writeDarwinShims(in: shim)
    try writeCurlShim(in: shim, assets: assets)
    try writeSignatureShims(in: shim)

    let (status, stderr) = try runInstallScript(
        script: installScriptURL(),
        environment: [
            "HOME": home.path,
            "PATH": shim.path + ":/usr/bin:/bin",
            "RV_TEST_CODESIGN": "unsigned",
            "TAR_OPTIONS": "--no-same-owner",
        ],
        systemCodesignShim: shim
    )
    #expect(status == 0, "\(stderr)")

    let destBin = home.appendingPathComponent(".local/bin")
    #expect(FileManager.default.isExecutableFile(atPath: destBin.appendingPathComponent("rv").path))
    #expect(FileManager.default.isExecutableFile(atPath: destBin.appendingPathComponent("rv-cli").path))
    #expect(FileManager.default.isExecutableFile(atPath: destBin.appendingPathComponent("rvd").path))
    #expect(isDirectory(destBin.appendingPathComponent("rv_RVPacks.bundle")) == false)
    let marker = try String(contentsOfFile: home.path + "/.rv-setup-marker", encoding: .utf8)
    #expect(marker.contains("from_install=1"))
}

@Test func installSh_failedDownloadLeavesPreviousInstallIntact() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-install-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let home = root.appendingPathComponent("home", isDirectory: true)
    let destBin = home.appendingPathComponent(".local/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: destBin, withIntermediateDirectories: true)
    let previous = "#!/bin/sh\n# installed-v1\n"
    for name in ["rv", "rv-cli", "rvd"] {
        try writeExecutable(destBin.appendingPathComponent(name), contents: previous)
    }

    let shim = root.appendingPathComponent("shim", isDirectory: true)
    try writeDarwinShims(in: shim)
    try writeCurlShim(
        in: shim,
        assets: root.appendingPathComponent("missing"),
        failAll: true
    )

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [installScriptURL().path]
    process.environment = [
        "HOME": home.path,
        "PATH": shim.path + ":/usr/bin:/bin",
    ]
    let stderr = Pipe()
    process.standardError = stderr
    process.standardOutput = Pipe()
    try process.run()
    process.waitUntilExit()
    let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    #expect(process.terminationStatus != 0)
    #expect(err.contains("failed to download"))
    #expect(err.contains("run rv-cli") == false)

    for name in ["rv", "rv-cli", "rvd"] {
        let dest = destBin.appendingPathComponent(name)
        #expect(try String(contentsOf: dest, encoding: .utf8).contains("installed-v1"))
    }
}

// MARK: - Release signature verification (downloaded macOS releases)

private func writeReleaseAssets(in assets: URL, withSpanRuntime: Bool = true, withPTYClaim: Bool = true) throws {
    try writeExecutable(
        assets.appendingPathComponent("rv"),
        contents: "#!/bin/sh\nexec \"$(dirname \"$0\")/rv-cli\" \"$@\"\n"
    )
    try writeExecutable(
        assets.appendingPathComponent("rv-cli"),
        contents: "#!/bin/sh\nprintf 'from_install=%s argv=%s\\n' \"${RV_FROM_INSTALL-}\" \"$*\" > \"$HOME/.rv-setup-marker\"\nexit 0\n"
    )
    try writeExecutable(assets.appendingPathComponent("rvd"), contents: "#!/bin/sh\n# release-rvd\nexit 0\n")
    try writeExecutable(assets.appendingPathComponent("rv-workspace-host"), contents: "#!/bin/sh\nexit 0\n")
    if withSpanRuntime {
        try writeExecutable(assets.appendingPathComponent("libswiftCompatibilitySpan.dylib"), contents: "span\n")
    }
    if withPTYClaim {
        try writeExecutable(assets.appendingPathComponent("rv-pty-claim"), contents: "#!/bin/sh\n# release-claim\nexit 0\n")
    }
}

/// `codesign` and `spctl` stand-ins driven by RV_TEST_* variables; every call
/// is appended to RV_TEST_TOOL_LOG.
private func writeSignatureShims(in shim: URL) throws {
    try writeExecutable(
        shim.appendingPathComponent("codesign"),
        contents: """
        #!/bin/sh
        printf 'codesign %s\\n' "$*" >> "$RV_TEST_TOOL_LOG"
        file=""
        for arg in "$@"; do file="$arg"; done
        name="${file##*/}"
        mode="${RV_TEST_CODESIGN:-signed}"
        [ "$name" = "${RV_TEST_CODESIGN_UNSIGNED:-}" ] && mode=unsigned
        case "$1" in
          -dvv)
            case "$mode" in
              unsigned) echo "$file: code object is not signed at all" >&2; exit 1 ;;
              adhoc) printf 'Executable=%s\\nSignature=adhoc\\nTeamIdentifier=not set\\n' "$file" >&2; exit 0 ;;
              phrase) printf 'Executable=/tmp/not signed at all/%s\\nIdentifier=not signed at all\\nAuthority=Developer ID Application: RV Test (TEAMRV1234)\\nTeamIdentifier=TEAMRV1234\\n' "$name" >&2; exit 0 ;;
              identifier-team) printf 'Executable=%s\\nIdentifier=com.rv.TeamIdentifier=TEAMRV1234\\nAuthority=Developer ID Application: Other (OTHERTEAM9)\\nTeamIdentifier=OTHERTEAM9\\n' "$file" >&2; exit 0 ;;
              identifier-newline) printf 'Executable=%s\\nIdentifier=com.evil\\nTeamIdentifier=TEAMRV1234\\nAuthority=Developer ID Application: Other (OTHERTEAM9)\\nTeamIdentifier=OTHERTEAM9\\n' "$file" >&2; exit 0 ;;
              adhoc-forged)
                case "$name" in
                  *.dylib) printf 'Executable=%s\\nIdentifier=com.evil\\nAuthority=Developer ID Application: Fake (TEAMRV1234)\\nTeamIdentifier=TEAMRV1234\\nSignature=adhoc\\nTeamIdentifier=not set\\n' "$file" >&2; exit 0 ;;
                  *) printf 'Executable=%s\\nAuthority=Developer ID Application: RV Test (TEAMRV1234)\\nAuthority=Developer ID Certification Authority\\nTeamIdentifier=TEAMRV1234\\n' "$file" >&2; exit 0 ;;
                esac
                ;;
              leaf-name)
                case "$name" in
                  *.dylib) printf 'Executable=%s\\nIdentifier=Authority=Developer ID Application: Not Apple\\nFormat=Mach-O thin (arm64)\\nCodeDirectory v=20400 size=400 flags=0x0(none) hashes=1+2 location=embedded\\nSignature size=1800\\nAuthority=Developer ID Application: Not Apple\\nTeamIdentifier=TEAMRV1234\\n' "$file" >&2; exit 0 ;;
                  *) printf 'Executable=%s\\nAuthority=Developer ID Application: RV Test (TEAMRV1234)\\nAuthority=Developer ID Certification Authority\\nTeamIdentifier=TEAMRV1234\\nSignature size=1800\\n' "$file" >&2; exit 0 ;;
                esac
                ;;
              identifier-authority)
                case "$name" in
                  *.dylib) printf 'Executable=%s\\nIdentifier=com.evil\\nAuthority=Developer ID Application: Not Apple\\nFormat=Mach-O thin (arm64)\\nCodeDirectory v=20400 size=400 flags=0x0(none) hashes=1+2 location=embedded\\nSignature size=1800\\nAuthority=Apple Development: Person (TEAMRV1234)\\nTeamIdentifier=TEAMRV1234\\n' "$file" >&2; exit 0 ;;
                  *) printf 'Executable=%s\\nAuthority=Developer ID Application: RV Test (TEAMRV1234)\\nAuthority=Developer ID Certification Authority\\nTeamIdentifier=TEAMRV1234\\n' "$file" >&2; exit 0 ;;
                esac
                ;;
              format-inside-identifier)
                case "$name" in
                  *.dylib) printf 'Executable=%s\\nIdentifier=com.evil\\nFormat=\\nAuthority=Developer ID Application: Not Apple\\nFormat=Mach-O thin (arm64)\\nCodeDirectory v=20400 size=400 flags=0x0(none) hashes=1+2 location=embedded\\nSignature size=1800\\nAuthority=Apple Development: Person (TEAMRV1234)\\nTeamIdentifier=TEAMRV1234\\n' "$file" >&2; exit 0 ;;
                  *) printf 'Executable=%s\\nAuthority=Developer ID Application: RV Test (TEAMRV1234)\\nAuthority=Developer ID Certification Authority\\nTeamIdentifier=TEAMRV1234\\n' "$file" >&2; exit 0 ;;
                esac
                ;;
              authority-continuation)
                case "$name" in
                  *.dylib) printf 'Executable=%s\\nIdentifier=libswiftCompatibilitySpan\\nFormat=Mach-O thin (arm64)\\nCodeDirectory v=20400 size=400 flags=0x0(none) hashes=1+2 location=embedded\\nSignature size=1800\\nAuthority=Apple Development: Person (TEAMRV1234)\\nAuthority=Developer ID Application: Not Apple\\nTeamIdentifier=TEAMRV1234\\n' "$file" >&2; exit 0 ;;
                  *) printf 'Executable=%s\\nAuthority=Developer ID Application: RV Test (TEAMRV1234)\\nAuthority=Developer ID Certification Authority\\nTeamIdentifier=TEAMRV1234\\n' "$file" >&2; exit 0 ;;
                esac
                ;;
              planted-format)
                case "$name" in
                  *.dylib)
                    planted="${RV_TEST_PLANTED_FORMAT:-Format=Mach-O thin (arm64)}"
                    printf 'Executable=%s\\nIdentifier=com.evil\\n%s\\nAuthority=Developer ID Application: Not Apple\\nFormat=Mach-O thin (arm64)\\nCodeDirectory v=20400 size=400 flags=0x0(none) hashes=1+2 location=embedded\\nSignature size=1800\\nAuthority=Apple Development: Person (TEAMRV1234)\\nTeamIdentifier=TEAMRV1234\\n' "$file" "$planted" >&2
                    exit 0
                    ;;
                  *) printf 'Executable=%s\\nAuthority=Developer ID Application: RV Test (TEAMRV1234)\\nAuthority=Developer ID Certification Authority\\nTeamIdentifier=TEAMRV1234\\n' "$file" >&2; exit 0 ;;
                esac
                ;;
              *) printf 'Executable=%s\\nAuthority=Developer ID Application: RV Test (TEAMRV1234)\\nAuthority=Developer ID Certification Authority\\nTeamIdentifier=TEAMRV1234\\n' "$file" >&2; exit 0 ;;
            esac
            ;;
          --verify)
            if [ "$mode" = unsigned ]; then echo "$file: code object is not signed at all" >&2; exit 1; fi
            if [ "$name" = "${RV_TEST_CODESIGN_TAMPERED:-}" ]; then
              echo "$file: invalid signature (code or signature have been modified)" >&2
              exit 1
            fi
            exit 0
            ;;
        esac
        exit 0
        """
    )
    try writeExecutable(
        shim.appendingPathComponent("spctl"),
        contents: """
        #!/bin/sh
        printf 'spctl %s\\n' "$*" >> "$RV_TEST_TOOL_LOG"
        file=""
        for arg in "$@"; do file="$arg"; done
        mode="${RV_TEST_SPCTL:-accept}"
        if [ "$mode" = accept ]; then
          printf '%s: accepted\\nsource=Notarized Developer ID\\n' "$file" >&2
          exit 0
        fi
        if [ "$mode" = reject-dylib ]; then
          case "$file" in
            *.dylib)
              printf '%s: rejected\\nsource=Unnotarized Developer ID\\n' "$file" >&2
              exit 3
              ;;
          esac
          printf '%s: accepted\\nsource=Notarized Developer ID\\n' "$file" >&2
          exit 0
        fi
        if [ "$mode" = label-accepted ]; then
          printf '%s: rejected\\nsource=no usable signature\\norigin=Developer ID Application: Not Apple\\n: accepted\\nsource=Notarized Developer ID\\n' "$file" >&2
          exit 3
        fi
        if [ "$mode" = origin-only ]; then
          printf '%s: rejected\\nsource=no usable signature\\norigin=Developer ID Application: Not Apple\\n' "$file" >&2
          exit 3
        fi
        if [ "$mode" = parenthetical ]; then
          printf '%s: rejected\\nsource=no usable signature\\n: rejected (the code is valid but does not seem to be an app)\\nsource=Notarized Developer ID\\n' "$file" >&2
          exit 3
        fi
        if [ "$mode" = slash-accepted ]; then
          printf '%s: rejected\\nsource=no usable signature\\norigin=Developer ID Application: Not Apple\\nFoo/Bar: accepted\\nsource=Notarized Developer ID\\n' "$file" >&2
          exit 3
        fi
        if [ "$mode" = slash-west ]; then
          printf '%s: rejected\\nsource=no usable signature\\nAuthority=Developer ID Application: Org\\n/West: accepted\\nsource=Notarized Developer ID\\n' "$file" >&2
          exit 3
        fi
        printf 'Identifier=source=Notarized Developer ID\\n%s: rejected\\nsource=Unnotarized Developer ID\\n' "$file" >&2
        exit 3
        """
    )
}

private struct SignedInstallRun {
    let status: Int32
    let stderr: String
    let toolLog: String
    let home: URL
    var destBin: URL { home.appendingPathComponent(".local/bin") }
}

private func shellQuote(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Runs `script` with `environment`. When `systemCodesignShim` is set, mounts
/// that directory's `codesign` and `spctl` over `/usr/bin` and `/usr/sbin`
/// inside a user namespace. A shim earlier on `PATH` is not `/usr/bin/codesign`.
private func runInstallScript(
    script: URL, environment: [String: String], systemCodesignShim: URL? = nil
) throws -> (status: Int32, stderr: String) {
    let process = Process()
    let stderr = Pipe()
    process.standardError = stderr
    process.standardOutput = Pipe()
    process.environment = environment
    if let shim = systemCodesignShim {
        let wrapper = shim.deletingLastPathComponent()
            .appendingPathComponent("mount-codesign-\(UUID().uuidString).sh")
        let body = """
        #!/bin/bash
        set -eu
        upper_bin=$(mktemp -d)
        work_bin=$(mktemp -d)
        upper_sbin=$(mktemp -d)
        work_sbin=$(mktemp -d)
        cp \(shellQuote(shim.appendingPathComponent("codesign").path)) "$upper_bin/codesign"
        cp \(shellQuote(shim.appendingPathComponent("spctl").path)) "$upper_sbin/spctl"
        chmod 755 "$upper_bin/codesign" "$upper_sbin/spctl"
        mount -t overlay overlay -o lowerdir=/usr/bin,upperdir="$upper_bin",workdir="$work_bin" /usr/bin
        mount -t overlay overlay -o lowerdir=/usr/sbin,upperdir="$upper_sbin",workdir="$work_sbin" /usr/sbin
        exec /bin/sh \(shellQuote(script.path))
        """
        try Data(body.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unshare")
        process.arguments = ["--user", "--map-root-user", "--mount", wrapper.path]
    } else {
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
    }
    try process.run()
    let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return (process.terminationStatus, err)
}

private func runSignedDownloadInstall(
    environment: [String: String] = [:],
    script: URL? = nil,
    withSpanRuntime: Bool = true,
    withPTYClaim: Bool = true,
    previousInstall: Bool = false,
    withSignatureShims: Bool = true,
    mountSystemCodesign: Bool = true
) throws -> SignedInstallRun {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-install-signed-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let destBin = home.appendingPathComponent(".local/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: destBin, withIntermediateDirectories: true)
    if previousInstall {
        for name in ["rv", "rv-cli", "rvd"] {
            try writeExecutable(destBin.appendingPathComponent(name), contents: "#!/bin/sh\n# installed-v1\n")
        }
    }
    let assets = root.appendingPathComponent("assets", isDirectory: true)
    try writeReleaseAssets(in: assets, withSpanRuntime: withSpanRuntime, withPTYClaim: withPTYClaim)
    let shim = root.appendingPathComponent("shim", isDirectory: true)
    try writeDarwinShims(in: shim)
    try writeCurlShim(in: shim, assets: assets)
    if withSignatureShims {
        try writeSignatureShims(in: shim)
    }
    let log = root.appendingPathComponent("tools.log")
    try Data().write(to: log)

    let processEnvironment = [
        "HOME": home.path,
        "PATH": shim.path + ":/usr/bin:/bin",
        "RV_TEST_TOOL_LOG": log.path,
    ].merging(environment) { $1 }
    let mounted = (withSignatureShims && mountSystemCodesign) ? shim : nil
    let (status, err) = try runInstallScript(
        script: script ?? installScriptURL(), environment: processEnvironment, systemCodesignShim: mounted)
    return SignedInstallRun(
        status: status,
        stderr: err,
        toolLog: (try? String(contentsOf: log, encoding: .utf8)) ?? "",
        home: home
    )
}

private func expectPreviousInstallKept(_ run: SignedInstallRun) throws {
    for name in ["rv", "rv-cli", "rvd"] {
        let body = try String(contentsOf: run.destBin.appendingPathComponent(name), encoding: .utf8)
        #expect(body.contains("installed-v1"), "\(name) was replaced")
    }
    #expect(FileManager.default.fileExists(atPath: run.destBin.appendingPathComponent("rv-workspace-host").path) == false)
}

private func removeTemporaryRoot(of run: SignedInstallRun) {
    try? FileManager.default.removeItem(at: run.home.deletingLastPathComponent())
}

@Test func installSh_signedNotarizedReleaseInstallsWithoutWarning() throws {
    let run = try runSignedDownloadInstall(environment: ["RV_INSTALL_TEAM_ID": "TEAMRV1234"])
    defer { removeTemporaryRoot(of: run) }

    #expect(run.status == 0, "\(run.stderr)")
    #expect(run.stderr.contains("warning") == false)
    let toolLines = run.toolLog.split(separator: "\n").map(String.init)
    for name in ["rv", "rv-cli", "rvd", "rv-workspace-host", "rv-pty-claim", "libswiftCompatibilitySpan.dylib"] {
        #expect(toolLines.contains { $0.hasPrefix("codesign -dvv ") && $0.hasSuffix("/\(name)") }, "\(name) not read")
        #expect(
            toolLines.contains { $0.hasPrefix("codesign --verify --strict ") && $0.hasSuffix("/\(name)") },
            "\(name) not verified"
        )
    }
    let spctlLines = toolLines.filter { $0.hasPrefix("spctl ") }
    #expect(spctlLines.count == 5)
    #expect(spctlLines.allSatisfy { $0.contains("-a -t open --context context:primary-signature") })
    #expect(spctlLines.contains { $0.hasSuffix(".dylib") } == false)
}

@Test func installSh_downloadsAndInstallsPTYClaimWhenReleased() throws {
    let run = try runSignedDownloadInstall(environment: ["RV_INSTALL_TEAM_ID": "TEAMRV1234"])
    defer { removeTemporaryRoot(of: run) }

    #expect(run.status == 0, "\(run.stderr)")
    let claim = run.destBin.appendingPathComponent("rv-pty-claim")
    #expect(FileManager.default.isExecutableFile(atPath: claim.path))
    #expect(try String(contentsOf: claim, encoding: .utf8).contains("release-claim"))
}

@Test func installSh_missingCodesignRefusesADownload() throws {
    let run = try runSignedDownloadInstall(previousInstall: true, withSignatureShims: false)
    defer { removeTemporaryRoot(of: run) }

    #expect(run.status == 1)
    #expect(run.stderr.contains(
        "rv: refusing to install: codesign is not available, so a Developer ID signature cannot be checked"))
    #expect(run.stderr.contains("warning: release files are not code-signed") == false)
    #expect(run.toolLog.contains("codesign") == false)
    try expectPreviousInstallKept(run)
}

@Test func installSh_identifierPhraseDoesNotSkipTheEmptyTeamCheck() throws {
    let run = try runSignedDownloadInstall(
        environment: ["RV_TEST_CODESIGN": "phrase"], previousInstall: true)
    defer { removeTemporaryRoot(of: run) }

    #expect(run.status == 1)
    #expect(run.stderr.contains("is signed, but no Developer ID team is pinned"))
    #expect(run.stderr.contains("warning: release files are not code-signed") == false)
    #expect(run.toolLog.contains("codesign -dvv "))
    try expectPreviousInstallKept(run)
}

@Test func installSh_identifierNewlineUnderDashDoesNotPass() throws {
    let shell = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/bin/sh")) ?? ""
    #expect(shell.contains("dash"))
    let run = try runSignedDownloadInstall(
        environment: ["RV_TEST_CODESIGN": "identifier-newline", "RV_INSTALL_TEAM_ID": "TEAMRV1234"],
        previousInstall: true
    )
    defer { removeTemporaryRoot(of: run) }

    #expect(run.status == 1)
    #expect(run.stderr.contains("is not signed by team TEAMRV1234"))
    #expect(run.stderr.contains("warning: release files are not code-signed") == false)
    try expectPreviousInstallKept(run)
}

@Test func installSh_tmpdirNewlineDoesNotForgeTheTeamOrSourceLine() throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-install-nl-\(UUID().uuidString)", isDirectory: true)
    let nasty = parent.appendingPathComponent(
        "evil\nTeamIdentifier=TEAMRV1234\nsource=Notarized Developer ID", isDirectory: true)
    try FileManager.default.createDirectory(at: nasty, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    let run = try runSignedDownloadInstall(
        environment: [
            "RV_INSTALL_TEAM_ID": "TEAMRV1234",
            "TMPDIR": nasty.path,
        ],
        previousInstall: true
    )
    defer { removeTemporaryRoot(of: run) }

    #expect(run.status == 1)
    #expect(run.stderr.contains("is not a single path, so its signature cannot be checked"))
    #expect(run.stderr.contains("TeamIdentifier=") == false)
    #expect(run.stderr.contains("source=Notarized Developer ID") == false)
    #expect(run.stderr.contains("warning: release files are not code-signed") == false)
    try expectPreviousInstallKept(run)
}

@Test func installSh_adHocDylibDoesNotSkipSpctl() throws {
    let run = try runSignedDownloadInstall(
        environment: [
            "RV_TEST_CODESIGN": "adhoc-forged",
            "RV_TEST_SPCTL": "accept",
            "RV_INSTALL_TEAM_ID": "TEAMRV1234",
        ],
        previousInstall: true
    )
    defer { removeTemporaryRoot(of: run) }

    #expect(run.status == 1)
    #expect(run.stderr.contains("libswiftCompatibilitySpan.dylib is not signed by team TEAMRV1234"))
    #expect(run.toolLog.contains("spctl "))
    #expect(run.toolLog.contains("libswiftCompatibilitySpan.dylib"))
    #expect(run.stderr.contains("warning: release files are not code-signed") == false)
    try expectPreviousInstallKept(run)
}

@Test func installSh_identifierContainingThePinnedTeamDoesNotPass() throws {
    let run = try runSignedDownloadInstall(
        environment: ["RV_TEST_CODESIGN": "identifier-team", "RV_INSTALL_TEAM_ID": "TEAMRV1234"],
        previousInstall: true
    )
    defer { removeTemporaryRoot(of: run) }

    #expect(run.status == 1)
    #expect(run.stderr.contains("is not signed by team TEAMRV1234"))
    #expect(run.stderr.contains("warning: release files are not code-signed") == false)
    try expectPreviousInstallKept(run)
}

@Test func installSh_notarizationPhraseInThePathDoesNotPass() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("source=Notarized Developer ID-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let run = try runSignedDownloadInstall(
        environment: [
            "RV_INSTALL_TEAM_ID": "TEAMRV1234",
            "RV_TEST_SPCTL": "reject",
            "TMPDIR": tmp.path,
        ],
        previousInstall: true
    )
    defer { removeTemporaryRoot(of: run) }

    #expect(run.status == 1)
    #expect(run.stderr.contains("Gatekeeper does not accept"))
    #expect(run.stderr.contains("warning: release files are not code-signed") == false)
    try expectPreviousInstallKept(run)
}

@Test func installSh_pathCodesignCannotSkipTheTeamCheck() throws {
    let run = try runSignedDownloadInstall(
        environment: ["RV_TEST_CODESIGN": "unsigned"],
        previousInstall: true,
        mountSystemCodesign: false
    )
    defer { removeTemporaryRoot(of: run) }

    #expect(run.status == 1)
    #expect(run.stderr.contains(
        "rv: refusing to install: codesign is not available, so a Developer ID signature cannot be checked"))
    #expect(run.stderr.contains("warning: release files are not code-signed") == false)
    #expect(run.toolLog.contains("codesign") == false)
    try expectPreviousInstallKept(run)
}

@Test func installSh_unsignedReleaseWarnsWhileSignedReleasesIsOff() throws {
    let run = try runSignedDownloadInstall(environment: ["RV_TEST_CODESIGN": "unsigned"])
    defer { removeTemporaryRoot(of: run) }

    #expect(run.status == 0, "\(run.stderr)")
    #expect(run.stderr.contains("warning: release files are not code-signed"))
    #expect(run.toolLog.contains("spctl") == false)
    #expect(FileManager.default.isExecutableFile(atPath: run.destBin.appendingPathComponent("rv").path))
}

@Test func installSh_tamperedSignatureRefusesAndKeepsPreviousInstall() throws {
    let run = try runSignedDownloadInstall(
        environment: [
            "RV_TEST_CODESIGN_TAMPERED": "rvd", "RV_INSTALL_ALLOW_UNSIGNED": "1", "RV_INSTALL_TEAM_ID": "TEAMRV1234",
        ],
        previousInstall: true
    )
    defer { removeTemporaryRoot(of: run) }

    #expect(run.status == 1)
    #expect(run.stderr.contains("rvd has an invalid code signature"))
    try expectPreviousInstallKept(run)
}

@Test func installSh_adHocSignatureIsNotDeveloperID() throws {
    let run = try runSignedDownloadInstall(environment: ["RV_TEST_CODESIGN": "adhoc"], previousInstall: true)
    defer { removeTemporaryRoot(of: run) }

    #expect(run.status == 1)
    #expect(run.stderr.contains("not signed with a Developer ID Application certificate"))
    try expectPreviousInstallKept(run)
}

@Test func installSh_signedReleaseWithoutPinnedTeamRefuses() throws {
    let run = try runSignedDownloadInstall(previousInstall: true)
    defer { removeTemporaryRoot(of: run) }

    #expect(run.status == 1)
    #expect(run.stderr.contains("libswiftCompatibilitySpan.dylib is signed, but no Developer ID team is pinned"))
    #expect(run.stderr.contains("warning") == false)
    try expectPreviousInstallKept(run)
}

@Test func installSh_foreignTeamRefuses() throws {
    let pinned = try runSignedDownloadInstall(environment: ["RV_INSTALL_TEAM_ID": "TEAMRV1234"])
    defer { removeTemporaryRoot(of: pinned) }
    let foreign = try runSignedDownloadInstall(environment: ["RV_INSTALL_TEAM_ID": "OTHERTEAM9"], previousInstall: true)
    defer { removeTemporaryRoot(of: foreign) }

    #expect(pinned.status == 0, "\(pinned.stderr)")
    #expect(foreign.status == 1)
    #expect(foreign.stderr.contains("is not signed by team OTHERTEAM9"))
    try expectPreviousInstallKept(foreign)
}

@Test func installSh_certificateLabelAcceptedDoesNotReplaceTheVerdict() throws {
    let run = try runSignedDownloadInstall(
        environment: [
            "RV_TEST_SPCTL": "label-accepted",
            "RV_INSTALL_TEAM_ID": "TEAMRV1234",
        ],
        previousInstall: true
    )
    defer { removeTemporaryRoot(of: run) }

    #expect(run.status == 1)
    #expect(run.stderr.contains("Gatekeeper does not accept rv as notarized"))
    #expect(run.stderr.contains("warning: release files are not code-signed") == false)
    try expectPreviousInstallKept(run)
}

@Test func installSh_oneLineOriginStillRefuses() throws {
    let run = try runSignedDownloadInstall(
        environment: [
            "RV_TEST_SPCTL": "origin-only",
            "RV_INSTALL_TEAM_ID": "TEAMRV1234",
        ],
        previousInstall: true
    )
    defer { removeTemporaryRoot(of: run) }

    #expect(run.status == 1)
    #expect(run.stderr.contains("Gatekeeper does not accept rv as notarized"))
    try expectPreviousInstallKept(run)
}

@Test func installSh_parentheticalRejectionDoesNotArm() throws {
    let run = try runSignedDownloadInstall(
        environment: [
            "RV_TEST_SPCTL": "parenthetical",
            "RV_INSTALL_TEAM_ID": "TEAMRV1234",
        ],
        previousInstall: true
    )
    defer { removeTemporaryRoot(of: run) }

    #expect(run.status == 1)
    #expect(run.stderr.contains("Gatekeeper does not accept rv as notarized"))
    try expectPreviousInstallKept(run)
}

@Test func installSh_certificateContinuationDoesNotRearmTheVerdict() throws {
    let slash = try runSignedDownloadInstall(
        environment: [
            "RV_TEST_SPCTL": "slash-accepted",
            "RV_INSTALL_TEAM_ID": "TEAMRV1234",
        ],
        previousInstall: true
    )
    defer { removeTemporaryRoot(of: slash) }
    #expect(slash.status == 1)
    #expect(slash.stderr.contains("Gatekeeper does not accept rv as notarized"))
    #expect(slash.stderr.contains("warning: release files are not code-signed") == false)
    try expectPreviousInstallKept(slash)

    let west = try runSignedDownloadInstall(
        environment: [
            "RV_TEST_SPCTL": "slash-west",
            "RV_INSTALL_TEAM_ID": "TEAMRV1234",
        ],
        previousInstall: true
    )
    defer { removeTemporaryRoot(of: west) }
    #expect(west.status == 1)
    #expect(west.stderr.contains("Gatekeeper does not accept rv as notarized"))
    #expect(west.stderr.contains("warning: release files are not code-signed") == false)
    try expectPreviousInstallKept(west)
}

@Test func installSh_identifierNewlineDoesNotInventAnAuthority() throws {
    let run = try runSignedDownloadInstall(
        environment: [
            "RV_TEST_CODESIGN": "identifier-authority",
            "RV_TEST_SPCTL": "reject-dylib",
            "RV_INSTALL_TEAM_ID": "TEAMRV1234",
        ],
        previousInstall: true
    )
    defer { removeTemporaryRoot(of: run) }

    #expect(run.status == 1)
    #expect(run.stderr.contains("Gatekeeper does not accept libswiftCompatibilitySpan.dylib as notarized"))
    #expect(run.toolLog.contains("spctl "))
    #expect(run.toolLog.contains("libswiftCompatibilitySpan.dylib"))
    #expect(run.stderr.contains("not signed with a Developer ID Application certificate") == false)
    #expect(run.stderr.contains("warning: release files are not code-signed") == false)
    try expectPreviousInstallKept(run)
}

@Test func installSh_formatInsideIdentifierStillRunsSpctl() throws {
    let run = try runSignedDownloadInstall(
        environment: [
            "RV_TEST_CODESIGN": "format-inside-identifier",
            "RV_TEST_SPCTL": "reject-dylib",
            "RV_INSTALL_TEAM_ID": "TEAMRV1234",
        ],
        previousInstall: true
    )
    defer { removeTemporaryRoot(of: run) }

    #expect(run.status == 1)
    #expect(run.stderr.contains("Gatekeeper does not accept libswiftCompatibilitySpan.dylib as notarized"))
    #expect(run.toolLog.contains("spctl "))
    #expect(run.toolLog.contains("libswiftCompatibilitySpan.dylib"))
    #expect(run.stderr.contains("not signed with a Developer ID Application certificate") == false)
    try expectPreviousInstallKept(run)
}

@Test(arguments: [
    "Format=Mach-O thin (arm64)",
    "Format=Mach-O",
    "Format=bundle with Mach-O thin (arm64)",
    "Format=app bundle with Mach-O thin (arm64)",
    "Format=bundle with ",
    "Format=app bundle ",
])
func installSh_plantedFormatInsideIdentifierStillRunsSpctl(_ planted: String) throws {
    let run = try runSignedDownloadInstall(
        environment: [
            "RV_TEST_CODESIGN": "planted-format",
            "RV_TEST_PLANTED_FORMAT": planted,
            "RV_TEST_SPCTL": "reject-dylib",
            "RV_INSTALL_TEAM_ID": "TEAMRV1234",
        ],
        previousInstall: true
    )
    defer { removeTemporaryRoot(of: run) }

    #expect(run.status == 1, "\(planted): \(run.stderr)")
    #expect(run.stderr.contains("Gatekeeper does not accept libswiftCompatibilitySpan.dylib as notarized"))
    #expect(run.toolLog.contains("spctl "))
    #expect(run.toolLog.contains("libswiftCompatibilitySpan.dylib"))
    #expect(run.stderr.contains("not signed with a Developer ID Application certificate") == false)
    try expectPreviousInstallKept(run)
}

@Test func installSh_authorityContinuationStillRunsSpctl() throws {
    let run = try runSignedDownloadInstall(
        environment: [
            "RV_TEST_CODESIGN": "authority-continuation",
            "RV_TEST_SPCTL": "reject-dylib",
            "RV_INSTALL_TEAM_ID": "TEAMRV1234",
        ],
        previousInstall: true
    )
    defer { removeTemporaryRoot(of: run) }

    #expect(run.status == 1)
    #expect(run.stderr.contains("Gatekeeper does not accept libswiftCompatibilitySpan.dylib as notarized"))
    #expect(run.toolLog.contains("spctl "))
    #expect(run.toolLog.contains("libswiftCompatibilitySpan.dylib"))
    #expect(run.stderr.contains("not signed with a Developer ID Application certificate") == false)
    try expectPreviousInstallKept(run)
}

@Test func installSh_dylibLeafNameDoesNotSkipSpctl() throws {
    let run = try runSignedDownloadInstall(
        environment: [
            "RV_TEST_CODESIGN": "leaf-name",
            "RV_TEST_SPCTL": "reject-dylib",
            "RV_INSTALL_TEAM_ID": "TEAMRV1234",
        ],
        previousInstall: true
    )
    defer { removeTemporaryRoot(of: run) }

    #expect(run.status == 1)
    #expect(run.stderr.contains("Gatekeeper does not accept libswiftCompatibilitySpan.dylib as notarized"))
    #expect(run.toolLog.contains("spctl "))
    #expect(run.toolLog.contains("libswiftCompatibilitySpan.dylib"))
    #expect(run.stderr.contains("not signed with a Developer ID Application certificate") == false)
    #expect(run.stderr.contains("warning: release files are not code-signed") == false)
    try expectPreviousInstallKept(run)
}

@Test func installSh_unnotarizedReleaseRefuses() throws {
    let run = try runSignedDownloadInstall(
        environment: ["RV_TEST_SPCTL": "reject", "RV_INSTALL_TEAM_ID": "TEAMRV1234"], previousInstall: true)
    defer { removeTemporaryRoot(of: run) }

    #expect(run.status == 1)
    #expect(run.stderr.contains("Gatekeeper does not accept rv as notarized"))
    try expectPreviousInstallKept(run)
}

@Test func installSh_mixedSignedAndUnsignedRefuses() throws {
    let run = try runSignedDownloadInstall(
        environment: [
            "RV_TEST_CODESIGN_UNSIGNED": "rvd", "RV_INSTALL_ALLOW_UNSIGNED": "1", "RV_INSTALL_TEAM_ID": "TEAMRV1234",
        ],
        previousInstall: true
    )
    defer { removeTemporaryRoot(of: run) }

    #expect(run.status == 1)
    #expect(run.stderr.contains("some release files are signed and some are not: rvd"))
    try expectPreviousInstallKept(run)
}

@Test func installSh_signedReleasesSwitchRefusesUnsignedUnlessAllowed() throws {
    let text = try String(contentsOf: installScriptURL(), encoding: .utf8)
    #expect(text.contains("\nsigned_releases=0\n"))
    let flippedText = text.replacingOccurrences(of: "\nsigned_releases=0\n", with: "\nsigned_releases=1\n")
    try #require(flippedText != text)
    let flipped = FileManager.default.temporaryDirectory.appendingPathComponent("rv-install-flipped-\(UUID().uuidString).sh")
    try flippedText.write(to: flipped, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: flipped) }

    let refused = try runSignedDownloadInstall(
        environment: ["RV_TEST_CODESIGN": "unsigned"], script: flipped, previousInstall: true
    )
    defer { removeTemporaryRoot(of: refused) }
    let allowed = try runSignedDownloadInstall(
        environment: ["RV_TEST_CODESIGN": "unsigned", "RV_INSTALL_ALLOW_UNSIGNED": "1"], script: flipped
    )
    defer { removeTemporaryRoot(of: allowed) }

    #expect(refused.status == 1)
    #expect(refused.stderr.contains("refusing to install unsigned release files"))
    #expect(refused.stderr.contains("RV_INSTALL_ALLOW_UNSIGNED=1"))
    try expectPreviousInstallKept(refused)
    #expect(allowed.status == 0, "\(allowed.stderr)")
    #expect(allowed.stderr.contains("warning: release files are not code-signed"))
}

@Test func installSh_localStageIsNotSignatureChecked() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-install-local-unsigned-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let src = root.appendingPathComponent("src")
    try writeDummyTrio(in: src)
    let shim = root.appendingPathComponent("shim")
    try writeDarwinShims(in: shim)
    try writeSignatureShims(in: shim)
    let home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [installScriptURL().path]
    process.environment = [
        "HOME": home.path,
        "PATH": shim.path + ":/usr/bin:/bin",
        "RV_INSTALL_BIN": src.path,
        "RV_TEST_TOOL_LOG": root.appendingPathComponent("tools.log").path,
        "RV_TEST_CODESIGN_TAMPERED": "rvd",
    ]
    process.standardError = Pipe()
    process.standardOutput = Pipe()
    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("tools.log").path) == false)
}
