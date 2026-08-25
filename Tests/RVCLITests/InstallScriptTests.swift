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
}

@Test func readme_hasNoBrewInstallPath() throws {
    let text = try String(
        contentsOf: repoRootURL().appendingPathComponent("README.md"),
        encoding: .utf8
    )
    #expect(text.localizedCaseInsensitiveContains("brew") == false)
}

@Test func installSh_refusesNonDarwin() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-install-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let shim = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: shim, withIntermediateDirectories: true)
    let uname = shim.appendingPathComponent("uname")
    try """
    #!/bin/sh
    if [ "$1" = "-s" ]; then echo Linux; exit 0; fi
    if [ "$1" = "-m" ]; then echo x86_64; exit 0; fi
    echo Linux
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
    #expect(err.contains("macOS 26 on Apple Silicon only"))
    #expect(FileManager.default.fileExists(atPath: root.path + "/.local/bin/rv") == false)
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
    #expect(text.contains("curl -fSL"))
    #expect(text.contains("run rv-cli") == false)
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
        while [ $# -gt 0 ]; do
          case "$1" in
            -o)
              out="$2"
              shift 2
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
        case "$url" in
          *api.github.com*/releases/latest)
            printf '%s\\n' '{"assets":[{"name":"rv_RVPacks.bundle"}]}'
            exit 0
            ;;
        esac
        src="\(assets.path)/$name"
        if [ -z "$out" ] || [ ! -e "$src" ]; then
          echo "curl: (22) The requested URL returned error: 404" >&2
          exit 22
        fi
        cp -R "$src" "$out"
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
    let bundlePack = assets.appendingPathComponent("rv_RVPacks.bundle/packs/core.json")
    try FileManager.default.createDirectory(
        at: bundlePack.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try "{}\n".write(to: bundlePack, atomically: true, encoding: .utf8)

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
    #expect(
        FileManager.default.fileExists(
            atPath: destBin.appendingPathComponent("rv_RVPacks.bundle/packs/core.json").path
        )
    )
    let marker = try String(contentsOfFile: home.path + "/.rv-setup-marker", encoding: .utf8)
    #expect(marker.contains("from_install=1"))
    #expect(marker.contains("setup"))
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
