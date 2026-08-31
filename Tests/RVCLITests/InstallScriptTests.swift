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

private func writeExecutable(_ url: URL, contents: String) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
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

private func writeDarwinShims(in shim: URL) throws {
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
        if [ "$1" = "-productVersion" ]; then echo 26.0; exit 0; fi
        echo 26.0
        """
    )
}

private func writeDummyTrio(in src: URL) throws {
    let dummy = "#!/bin/sh\n# installed-dummy\nexit 0\n"
    for name in ["rv", "rv-cli", "rvd"] {
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

@Test func installSh_refusesWindows() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-install-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let shim = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: shim, withIntermediateDirectories: true)
    let uname = shim.appendingPathComponent("uname")
    try """
    #!/bin/sh
    if [ "$1" = "-s" ]; then echo Windows_NT; exit 0; fi
    if [ "$1" = "-m" ]; then echo x86_64; exit 0; fi
    echo Windows_NT
    """.write(to: uname, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uname.path)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [installScriptURL().path]
    process.environment = [
        "HOME": root.path,
        "PATH": shim.path + ":/usr/bin:/bin",
        "RV_INSTALL_BIN": root.path,
    ]
    let stderr = Pipe()
    process.standardError = stderr
    process.standardOutput = Pipe()
    try process.run()
    process.waitUntilExit()
    let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    #expect(process.terminationStatus == 1)
    #expect(err.contains("macOS 26 Apple Silicon, or Linux aarch64/x86_64"))
    #expect(err.localizedCaseInsensitiveContains("windows") == false)
    #expect(FileManager.default.fileExists(atPath: root.path + "/.local/bin/rv") == false)
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
    #expect(text.contains("$release_base/rv_RVPacks.bundle") == false)
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
            -I|--head)
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
    try writePackBundleTarball(in: assets)
    #expect(FileManager.default.fileExists(atPath: assets.appendingPathComponent("rv_RVPacks.bundle.tar.gz").path))
    #expect(isDirectory(assets.appendingPathComponent("rv_RVPacks.bundle")) == false)

    let shim = root.appendingPathComponent("shim", isDirectory: true)
    try writeDarwinShims(in: shim)
    try writeCurlShim(in: shim, assets: assets)

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
    #expect(process.terminationStatus == 0)

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

    let shim = root.appendingPathComponent("shim", isDirectory: true)
    try writeDarwinShims(in: shim)
    try writeCurlShim(in: shim, assets: assets)

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
    #expect(process.terminationStatus == 0)

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
