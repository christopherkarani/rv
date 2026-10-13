#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
import RVDomain
import RVIPC
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
    try await CommandRun.run(
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
    ownerAuthOutcome: UIAuthenticationOutcome? = nil,
    _ body: () throws -> T
) throws -> T {
    let context = CLIProcess.Context(
        home: home,
        environment: environment,
        stdinIsTTY: stdinIsTTY,
        stdoutIsTTY: stdoutIsTTY,
        stdoutFileDescriptor: stdoutFileDescriptor,
        workspacePath: workspacePath,
        stdinText: stdinText,
        ownerAuthOutcome: ownerAuthOutcome
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
    ownerAuthOutcome: UIAuthenticationOutcome? = nil,
    _ body: () async throws -> T
) async throws -> T {
    let context = CLIProcess.Context(
        home: home,
        environment: environment,
        stdinIsTTY: stdinIsTTY,
        stdoutIsTTY: stdoutIsTTY,
        stdoutFileDescriptor: stdoutFileDescriptor,
        workspacePath: workspacePath,
        stdinText: stdinText,
        ownerAuthOutcome: ownerAuthOutcome
    )
    return try await CLIProcess.$context.withValue(context, operation: body)
}

func writeExecutableScript(at url: URL, source: String) throws {
    let files = FileManager.default
    let directory = url.deletingLastPathComponent()
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    // Publish a closed inode. Writing the destination in place, or renaming a
    // file that is still open for write, makes the following exec return ETXTBSY.
    let staged = directory.appendingPathComponent(".\(url.lastPathComponent)-\(UUID().uuidString).new")
    let fd = staged.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644) }
    guard fd >= 0 else { throw posixError(errno, path: staged.path) }
    var closed = false
    defer {
        if !closed { close(fd) }
        if files.fileExists(atPath: staged.path) {
            try? files.removeItem(at: staged)
        }
    }
    let bytes = Array(source.utf8)
    var offset = 0
    while offset < bytes.count {
        let count = bytes.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return write(fd, base.advanced(by: offset), raw.count - offset)
        }
        if count < 0 {
            if errno == EINTR { continue }
            throw posixError(errno, path: staged.path)
        }
        offset += count
    }
    if fchmod(fd, 0o755) != 0 || fsync(fd) != 0 {
        throw posixError(errno, path: staged.path)
    }
    if close(fd) != 0 {
        throw posixError(errno, path: staged.path)
    }
    closed = true
    if files.fileExists(atPath: url.path) {
        try files.removeItem(at: url)
    }
    try files.moveItem(at: staged, to: url)
}

private func posixError(_ code: Int32, path: String) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
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
