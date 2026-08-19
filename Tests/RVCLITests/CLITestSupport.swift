import Foundation
import RVDomain
import RVTheme
@testable import RVCLI

func isolatedAllowOnceDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-cli-allow-once-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

func isolatedClient(
    transport: (any ServiceTransport)? = nil,
    allowOnceDirectory: URL? = nil
) throws -> ServiceClient {
    ServiceClient(
        transport: transport,
        allowOnceDirectory: try allowOnceDirectory ?? isolatedAllowOnceDirectory()
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
        allowOnceDirectory: try allowOnceDirectory ?? isolatedAllowOnceDirectory()
    )
}

func cliEvaluate(
    _ command: String,
    allowOnceDirectory: URL? = nil
) async throws -> EvaluationResult {
    await CommandRun.evaluateCommand(
        command,
        cwd: "/tmp/ws",
        allowOnceDirectory: try allowOnceDirectory ?? isolatedAllowOnceDirectory()
    )
}
