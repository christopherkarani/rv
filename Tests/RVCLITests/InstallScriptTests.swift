import Foundation
import Testing

private func repoRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func installScriptURL() -> URL {
    repoRootURL().appendingPathComponent("install.sh")
}

@Test func installSh_doesNotMentionBrew() throws {
    let text = try String(contentsOf: installScriptURL(), encoding: .utf8)
    #expect(text.localizedCaseInsensitiveContains("brew") == false)
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
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    let dummy = "#!/bin/sh\n# installed-dummy\nexit 0\n"
    for name in ["rv", "rvd"] {
        let url = src.appendingPathComponent(name)
        try dummy.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    let shim = root.appendingPathComponent("shim", isDirectory: true)
    try FileManager.default.createDirectory(at: shim, withIntermediateDirectories: true)
    let uname = shim.appendingPathComponent("uname")
    try """
    #!/bin/sh
    if [ "$1" = "-s" ]; then echo Darwin; exit 0; fi
    if [ "$1" = "-m" ]; then echo arm64; exit 0; fi
    echo Darwin
    """.write(to: uname, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uname.path)
    let swVers = shim.appendingPathComponent("sw_vers")
    try """
    #!/bin/sh
    if [ "$1" = "-productVersion" ]; then echo 26.0; exit 0; fi
    echo 26.0
    """.write(to: swVers, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swVers.path)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [installScriptURL().path]
    process.environment = [
        "HOME": home.path,
        "PATH": shim.path + ":/usr/bin:/bin",
        "RV_INSTALL_BIN": src.path,
    ]
    process.standardError = Pipe()
    process.standardOutput = Pipe()
    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    let destType = try FileManager.default.attributesOfItem(atPath: destRv.path)[.type] as? FileAttributeType
    #expect(destType == .typeRegular)
    let destBody = try String(contentsOf: destRv, encoding: .utf8)
    #expect(destBody.contains("installed-dummy"))
    #expect(try Data(contentsOf: victim) == victimBytes)
}
