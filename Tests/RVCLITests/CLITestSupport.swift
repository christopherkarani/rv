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
