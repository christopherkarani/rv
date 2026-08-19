import Foundation
import RVDomain
import RVPolicy
import RVTheme
@testable import RVCLI

func isolatedAllowOnceStore() throws -> AllowOnceStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-cli-allow-once-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return AllowOnceStore(baseDirectory: root)
}

func isolatedClient(transport: (any ServiceTransport)? = nil) throws -> ServiceClient {
    ServiceClient(transport: transport, store: try isolatedAllowOnceStore())
}

func cliRun(
    kind: CLIKind,
    command: String,
    probe: ThemeProbe,
    requested: RequestedMode
) async throws -> CLIResult {
    await CommandRun.run(
        kind: kind,
        command: command,
        probe: probe,
        requested: requested,
        cwd: "/tmp/ws",
        store: try isolatedAllowOnceStore()
    )
}

func cliEvaluate(_ command: String) async throws -> EvaluationResult {
    await CommandRun.evaluateCommand(
        command,
        cwd: "/tmp/ws",
        store: try isolatedAllowOnceStore()
    )
}
