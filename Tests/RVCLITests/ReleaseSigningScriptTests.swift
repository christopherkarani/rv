import Foundation
import Testing

private func signScriptURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Scripts/sign-macos.sh")
}

private let secretEnvironment = [
    "DEVELOPER_ID_APP": "Developer ID Application: Secret Person (SECRETTEAM)",
    "MACOS_CERT_P12": "c2VjcmV0LXAxMi1ieXRlcw==",
    "MACOS_CERT_PASSWORD": "secret-cert-password",
    "NOTARY_KEY_ID": "SECRETKEYID",
    "NOTARY_ISSUER_ID": "secret-issuer-uuid",
    "NOTARY_KEY_P8": "c2VjcmV0LXA4LWJ5dGVz",
]

private struct SignRun {
    let status: Int32
    let stdout: String
    let stderr: String
    var output: String { stdout + stderr }
}

private func runSignScript(_ arguments: [String], environment: [String: String] = [:]) throws -> SignRun {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [signScriptURL().path] + arguments
    process.environment = ["PATH": "/usr/bin:/bin"].merging(environment) { $1 }
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let stdout = out.fileHandleForReading.readDataToEndOfFile()
    let stderr = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return SignRun(
        status: process.terminationStatus,
        stdout: String(decoding: stdout, as: UTF8.self),
        stderr: String(decoding: stderr, as: UTF8.self)
    )
}

private func makeStage(withSpanRuntime: Bool = true, omitting: String? = nil) throws -> URL {
    let stage = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-sign-stage-\(UUID().uuidString)", isDirectory: true)
    let manager = FileManager.default
    try manager.createDirectory(at: stage, withIntermediateDirectories: true)
    var names = ["rv", "rv-cli", "rvd", "rv-workspace-host", "rv-pty-claim"]
    if withSpanRuntime { names.append("libswiftCompatibilitySpan.dylib") }
    for name in names where name != omitting {
        let file = stage.appendingPathComponent(name)
        try Data("fixture \(name)\n".utf8).write(to: file)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    let agentBin = stage.appendingPathComponent("rv-agent-bin", isDirectory: true)
    try manager.createDirectory(at: agentBin, withIntermediateDirectories: true)
    try manager.createSymbolicLink(atPath: agentBin.appendingPathComponent("node").path, withDestinationPath: "/bin/sh")
    let packs = stage.appendingPathComponent("rv_RVPacks.bundle/packs", isDirectory: true)
    try manager.createDirectory(at: packs, withIntermediateDirectories: true)
    try Data("{}\n".utf8).write(to: packs.appendingPathComponent("core.json"))
    return stage
}

private func lines(_ text: String, containing needle: String) -> [String] {
    text.split(separator: "\n").map(String.init).filter { $0.contains(needle) }
}

@Test func signDryRunSignsEveryStagedBinaryWithHardenedRuntime() throws {
    let stage = try makeStage()
    defer { try? FileManager.default.removeItem(at: stage) }

    let run = try runSignScript(["--dry-run", stage.path])

    #expect(run.status == 0, "\(run.output)")
    let signs = lines(run.stdout, containing: "codesign --force")
    #expect(signs.count == 6)
    #expect(signs.first?.hasSuffix("/libswiftCompatibilitySpan.dylib") == true)
    for name in ["rv", "rv-cli", "rvd", "rv-workspace-host", "rv-pty-claim"] {
        let line = try #require(signs.first { $0.hasSuffix("/\(name)") }, "no codesign line for \(name)")
        #expect(line.contains("--options runtime"))
        #expect(line.contains("--timestamp"))
        #expect(line.contains("--identifier dev.rv.\(name) "))
        #expect(line.contains("--sign <DEVELOPER_ID_APP>"))
        #expect(line.contains("--entitlements") == false)
    }
    #expect(lines(run.stdout, containing: "codesign --verify --strict").count == 6)
    #expect(run.stdout.contains("rv-agent-bin") == false)
    #expect(run.stdout.contains("RVPacks") == false)
}

@Test func signDryRunNotarizesWithTheAPIKeyAndExplainsStapling() throws {
    let stage = try makeStage()
    defer { try? FileManager.default.removeItem(at: stage) }

    let run = try runSignScript(["--dry-run", stage.path])

    #expect(run.status == 0, "\(run.output)")
    let submit = try #require(lines(run.stdout, containing: "xcrun notarytool submit").first)
    #expect(submit.contains("--key <NOTARY_KEY_P8 file>"))
    #expect(submit.contains("--key-id <NOTARY_KEY_ID>"))
    #expect(submit.contains("--issuer <NOTARY_ISSUER_ID>"))
    #expect(submit.contains("--wait"))
    #expect(run.stdout.contains("spctl -a -t open --context context:primary-signature"))
    #expect(run.stdout.contains("cannot be stapled"))
    let signIndex = try #require(run.stdout.range(of: "codesign --force")).lowerBound
    let submitIndex = try #require(run.stdout.range(of: "xcrun notarytool submit")).lowerBound
    #expect(signIndex < submitIndex)
}

@Test func signDryRunWithKeychainImportUsesATemporaryKeychain() throws {
    let stage = try makeStage()
    defer { try? FileManager.default.removeItem(at: stage) }

    let run = try runSignScript(["--dry-run", "--keychain-from-env", stage.path])

    #expect(run.status == 0, "\(run.output)")
    #expect(run.stdout.contains("security create-keychain"))
    #expect(run.stdout.contains("security import <MACOS_CERT_P12 file>"))
    #expect(run.stdout.contains("security delete-keychain"))
    for line in lines(run.stdout, containing: "codesign --force") {
        #expect(line.contains("--keychain <temporary keychain>"))
    }
}

@Test func signNeverPrintsSecretValues() throws {
    let stage = try makeStage()
    defer { try? FileManager.default.removeItem(at: stage) }

    let dryRun = try runSignScript(["--dry-run", "--keychain-from-env", stage.path], environment: secretEnvironment)
    let partial = secretEnvironment.filter { $0.key != "NOTARY_KEY_P8" }
    let missing = try runSignScript(["--keychain-from-env", stage.path], environment: partial)

    #expect(dryRun.status == 0, "\(dryRun.output)")
    #expect(missing.status != 0)
    #expect(missing.stderr.contains("NOTARY_KEY_P8"))
    for run in [dryRun, missing] {
        for value in secretEnvironment.values {
            #expect(run.output.contains(value) == false)
        }
        #expect(run.output.contains("SECRETTEAM") == false)
    }
}

@Test func signRealRunNamesEveryMissingVariableBeforeTouchingFiles() throws {
    let stage = try makeStage()
    defer { try? FileManager.default.removeItem(at: stage) }

    let run = try runSignScript(["--keychain-from-env", stage.path])

    #expect(run.status == 2)
    for name in secretEnvironment.keys {
        #expect(run.stderr.contains(name), "missing \(name) in: \(run.stderr)")
    }
    #expect(run.stdout.isEmpty)
}

@Test func signRealRunWithoutKeychainImportNeedsNoCertificateVariables() throws {
    let stage = try makeStage()
    defer { try? FileManager.default.removeItem(at: stage) }

    let run = try runSignScript([stage.path])

    #expect(run.status == 2)
    #expect(run.stderr.contains("DEVELOPER_ID_APP"))
    #expect(run.stderr.contains("MACOS_CERT_P12") == false)
    #expect(run.stderr.contains("MACOS_CERT_PASSWORD") == false)
}

@Test func signRefusesAStageMissingARequiredBinary() throws {
    let stage = try makeStage(omitting: "rv-pty-claim")
    defer { try? FileManager.default.removeItem(at: stage) }

    let run = try runSignScript(["--dry-run", stage.path])

    #expect(run.status != 0)
    #expect(run.stderr.contains("rv-pty-claim"))
}

@Test func signRefusesASymlinkedBinary() throws {
    let stage = try makeStage(omitting: "rvd")
    defer { try? FileManager.default.removeItem(at: stage) }
    try FileManager.default.createSymbolicLink(
        atPath: stage.appendingPathComponent("rvd").path,
        withDestinationPath: "/bin/sh"
    )

    let run = try runSignScript(["--dry-run", stage.path])

    #expect(run.status != 0)
    #expect(run.stderr.contains("rvd"))
}

@Test func signWithoutTheSpanRuntimeSignsOnlyTheFiveBinaries() throws {
    let stage = try makeStage(withSpanRuntime: false)
    defer { try? FileManager.default.removeItem(at: stage) }

    let run = try runSignScript(["--dry-run", stage.path])

    #expect(run.status == 0, "\(run.output)")
    #expect(lines(run.stdout, containing: "codesign --force").count == 5)
    #expect(run.stdout.contains("libswiftCompatibilitySpan") == false)
}

@Test func signRejectsUnknownOptionsAndAMissingStage() throws {
    let unknown = try runSignScript(["--sign-everything", "/tmp"])
    let noStage = try runSignScript(["--dry-run"])

    #expect(unknown.status == 2)
    #expect(noStage.status == 2)
}

@Test func releaseScriptRejectsAnUnknownSignModeBeforeBuilding() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [signScriptURL().deletingLastPathComponent().appendingPathComponent("release.sh").path]
    process.environment = [
        "PATH": "/usr/bin:/bin",
        "RV_RELEASE_SIGN": "yes",
        "RV_RELEASE_STAGE": "/nonexistent/rv-release-stage-must-not-be-created",
    ]
    let err = Pipe()
    process.standardError = err
    process.standardOutput = Pipe()
    try process.run()
    let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()

    #expect(process.terminationStatus == 2)
    #expect(stderr.contains("RV_RELEASE_SIGN must be 1 or dry-run"))
}

@Test func releaseScriptOffersTheSigningHook() throws {
    let release = signScriptURL().deletingLastPathComponent().appendingPathComponent("release.sh")
    let text = try String(contentsOf: release, encoding: .utf8)
    #expect(text.contains("RV_RELEASE_SIGN"))
    #expect(text.contains("sign-macos.sh"))
    #expect(text.contains("Does not codesign") == false)
}

private func makeCustodianBundle(in stage: URL) throws {
    let macOS = stage.appendingPathComponent("RVApprovals.app/Contents/MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let binary = macOS.appendingPathComponent("rv-mcp-custodian")
    try Data("fixture custodian\n".utf8).write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    try Data("fixture plist\n".utf8).write(
        to: stage.appendingPathComponent("RVApprovals.app/Contents/Info.plist"))
}

@Test func signDryRunPrintsCustodianPlanWithoutAProfile() throws {
    let stage = try makeStage()
    defer { try? FileManager.default.removeItem(at: stage) }
    try makeCustodianBundle(in: stage)

    let run = try runSignScript(["--dry-run", stage.path])

    #expect(run.status == 0, "\(run.output)")
    #expect(run.stdout.contains("RVApprovals.app/Contents/embedded.provisionprofile"))
    let custodianSign = try #require(
        lines(run.stdout, containing: "codesign --force").first { $0.contains("rv-mcp-custodian") })
    #expect(custodianSign.contains("--entitlements"))
    #expect(custodianSign.contains("RVApprovals.entitlements"))
    #expect(custodianSign.contains("--identifier dev.rv.mcp-custodian"))
    for name in ["rv", "rv-cli", "rvd", "rv-workspace-host", "rv-pty-claim"] {
        let line = try #require(
            lines(run.stdout, containing: "codesign --force").first { $0.hasSuffix("/\(name)") })
        #expect(line.contains("--entitlements") == false)
    }
    #expect(run.stdout.contains("codesign --verify --deep --strict"))
    #expect(run.stdout.contains("stapler staple"))
    #expect(run.stdout.contains("RV_CUSTODIAN_PROVISIONING_PROFILE"))
}

@Test func signDryRunUsesTheSuppliedCustodianProfile() throws {
    let stage = try makeStage()
    defer { try? FileManager.default.removeItem(at: stage) }
    try makeCustodianBundle(in: stage)

    let run = try runSignScript(
        ["--dry-run", stage.path],
        environment: ["RV_CUSTODIAN_PROVISIONING_PROFILE": "/profiles/rv-custodian.provisionprofile"])

    #expect(run.status == 0, "\(run.output)")
    #expect(run.stdout.contains("/profiles/rv-custodian.provisionprofile"))
    #expect(run.stdout.contains("RVApprovals.app/Contents/embedded.provisionprofile"))
}

@Test func signDryRunWithoutACustodianBundlePrintsNoCustodianLines() throws {
    let stage = try makeStage()
    defer { try? FileManager.default.removeItem(at: stage) }

    let run = try runSignScript(["--dry-run", stage.path])

    #expect(run.status == 0, "\(run.output)")
    #expect(run.stdout.contains("RVApprovals") == false)
    #expect(lines(run.stdout, containing: "--entitlements").isEmpty)
}

@Test func releaseScriptAssemblesTheCustodianBundle() throws {
    let scripts = signScriptURL().deletingLastPathComponent()
    let release = try String(contentsOf: scripts.appendingPathComponent("release.sh"), encoding: .utf8)
    #expect(release.contains("RVApprovals.app"))
    #expect(release.contains("custodian/Info.plist"))
    let assets = try String(contentsOf: scripts.appendingPathComponent("release-assets.sh"), encoding: .utf8)
    #expect(assets.contains("rv-approvals-darwin-arm64.zip"))
}
