import Foundation
import Testing
@testable import RVIsolation

// Smoke coverage for the live `AgentBin` locator. Pure path math plus the
// empty case of `resolve`, which must grant nothing when the install has
// no agent bin.
@Test func agentBinDirectoryDerivesFromExecutablePath() {
    #expect(AgentBin.directory(executablePath: "/opt/rv/bin/rv") == "/opt/rv/bin/rv-agent-bin")
    #expect(AgentBin.directoryName == "rv-agent-bin")
}

@Test func agentBinResolveWithMissingBinDirGrantsNothing() {
    let resolution = AgentBin.resolve(
        binDirectory: "/nonexistent-rv-agent-bin", home: "/nonexistent-rv-home"
    )
    #expect(resolution.directory == "/nonexistent-rv-agent-bin")
    #expect(resolution.executables.isEmpty)
    #expect(resolution.trees.isEmpty)
    #expect(resolution.credentials.isEmpty)
    #expect(resolution.writableTrees.isEmpty)
}
