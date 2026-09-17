import Foundation
import Testing
import RVDomain
import RVService
import RVTheme
import RVPolicy
@testable import RVCLI

func denyPayload(from decision: Decision) -> Deny? {
    if case .deny(let deny) = decision { return deny }
    return nil
}

func indeterminateReason(from decision: Decision) -> IndeterminateReason? {
    if case .indeterminate(let reason) = decision { return reason }
    return nil
}

func isolatedAllowOnceDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-cli-allow-once-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

func isolatedHome() throws -> HomeDirectory {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-cli-home-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return try #require(HomeDirectory(validating: root.path))
}

func isolatedClient(
    transport: (any ServiceTransport)? = nil,
    allowOnceDirectory: URL? = nil
) throws -> ServiceClient {
    ServiceClient(
        transport: transport,
        allowOnceDirectory: try allowOnceDirectory ?? isolatedAllowOnceDirectory(),
        home: try isolatedHome()
    )
}

func isolatedClient(
    transport: (any ServiceTransport)?,
    lazySession: @escaping @Sendable () -> EvaluateSession,
    allowOnceDirectory: URL? = nil
) throws -> ServiceClient {
    ServiceClient(
        transport: transport,
        lazySession: lazySession,
        allowOnceDirectory: try allowOnceDirectory ?? isolatedAllowOnceDirectory(),
        home: try isolatedHome()
    )
}

func cliRun(
    kind: CLIKind,
    command: String,
    probe: ThemeProbe,
    requested: RequestedMode,
    allowOnceDirectory: URL? = nil
) async throws -> CLIResult {
    await CommandRun.run(
        kind: kind,
        command: command,
        probe: probe,
        requested: requested,
        cwd: "/tmp/ws",
        allowOnceDirectory: try allowOnceDirectory ?? isolatedAllowOnceDirectory(),
        home: try isolatedHome()
    )
}

func cliEvaluate(
    _ command: String,
    allowOnceDirectory: URL? = nil
) async throws -> EvaluationResult {
    await CommandRun.evaluateCommand(
        command,
        cwd: "/tmp/ws",
        allowOnceDirectory: try allowOnceDirectory ?? isolatedAllowOnceDirectory(),
        home: try isolatedHome()
    )
}

func wd(_ raw: String) -> WorkingDirectory {
    WorkingDirectory(validating: raw)!
}

@discardableResult
func withCLIProcess<T>(
    home: HomeDirectory? = nil,
    environment: [String: String] = [:],
    stdinIsTTY: Bool? = false,
    stdoutIsTTY: Bool? = false,
    workspacePath: String? = nil,
    stdoutFileDescriptor: Int32? = nil,
    stdinText: String? = nil,
    _ body: () throws -> T
) throws -> T {
    let context = CLIProcess.Context(
        home: home,
        environment: environment,
        stdinIsTTY: stdinIsTTY,
        stdoutIsTTY: stdoutIsTTY,
        stdoutFileDescriptor: stdoutFileDescriptor,
        workspacePath: workspacePath,
        stdinText: stdinText
    )
    return try CLIProcess.$context.withValue(context, operation: body)
}

@discardableResult
func withCLIProcess<T>(
    home: HomeDirectory? = nil,
    environment: [String: String] = [:],
    stdinIsTTY: Bool? = false,
    stdoutIsTTY: Bool? = false,
    workspacePath: String? = nil,
    stdoutFileDescriptor: Int32? = nil,
    stdinText: String? = nil,
    _ body: () async throws -> T
) async throws -> T {
    let context = CLIProcess.Context(
        home: home,
        environment: environment,
        stdinIsTTY: stdinIsTTY,
        stdoutIsTTY: stdoutIsTTY,
        stdoutFileDescriptor: stdoutFileDescriptor,
        workspacePath: workspacePath,
        stdinText: stdinText
    )
    return try await CLIProcess.$context.withValue(context, operation: body)
}

func writeExecutableScript(at url: URL, source: String) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try source.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

func fakeProcessTool(exit status: Int32) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-fake-tool-\(UUID().uuidString)", isDirectory: false)
    try writeExecutableScript(
        at: url,
        source: "#!/bin/sh\nexit \(status)\n"
    )
    return url
}

func allowlistLockURL(home: HomeDirectory) -> URL {
    RVPolicyPaths.allowlistLockFile(inConfigDir: RVPolicyPaths.configDirectory(home: home))
}

func allowOnceLockURL(home: HomeDirectory) -> URL {
    RVPolicyPaths.allowOnceLockFile(inConfigDir: RVPolicyPaths.configDirectory(home: home))
}

func replacePathWithFile(_ url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
    } else {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
    try Data().write(to: url)
}

func replacePathWithDirectory(_ url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
    }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}

func seedAllowlist(
    home: HomeDirectory,
    rule: String = "core.git:reset-hard",
    reason: String = "reviewed"
) throws {
    let store = AllowlistCLI.store(home: home)
    let ruleID = try #require(parseAllowlistRuleID(rule))
    try store.add(
        AllowlistEntry(selector: .rule(ruleID), reason: reason, addedAt: Date()),
        tty: TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
    )
}
