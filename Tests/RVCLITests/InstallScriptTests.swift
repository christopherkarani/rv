import Foundation
import Testing

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

    let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("install.sh")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [script.path]
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
